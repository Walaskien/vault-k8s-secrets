# vault-k8s-secrets

[![ci](https://github.com/Walaskien/vault-k8s-secrets/actions/workflows/ci.yml/badge.svg)](https://github.com/Walaskien/vault-k8s-secrets/actions/workflows/ci.yml)

A Secret manifest in Git is base64, not encryption. Anyone with a clone has the password, and after a rotation the old one is still in the history. This repo keeps the value out of Git altogether: HashiCorp Vault holds it, External Secrets Operator copies it into an ordinary Kubernetes Secret, and a small HTTP service reads that Secret. Change the value in Vault and the cluster follows within the refresh interval, with no commit and no pod restart.

> **Vault runs in dev mode here, for the demo only.** In-memory storage, no TLS, auto-unsealed, and a root token that is written in `helm/vault-dev-values.yaml` (`root`). Everything is gone when the pod restarts. [docs/real-mode.md](docs/real-mode.md) lists what a real install changes: storage, unseal, TLS, the root token, audit.

## How the pieces fit

```mermaid
flowchart LR
  admin["admin or CI<br/>vault kv put"] --> vault[("Vault<br/>kv v2<br/>secret/demo/app")]
  subgraph cluster["Kubernetes"]
    eso["External Secrets<br/>controller"] -- "login: ServiceAccount token<br/>demo/eso-demo" --> vault
    vault -- "TokenReview" --> api["API server"]
    vault -- "token with policy<br/>demo-app-read" --> eso
    eso -- "read, every 15s" --> vault
    eso --> sec["Secret app-secret"]
    sec -- "volume" --> pod["app pod<br/>re-reads the file"]
  end
```

The login is the interesting part. External Secrets asks the API server for a short-lived token of the ServiceAccount `demo/eso-demo` (audience `vault`) and sends it to Vault's Kubernetes auth method. Vault hands the token to the API server's TokenReview, and if the answer is "this is `eso-demo` in `demo`" it checks that against the role `demo-app`. The role is bound to exactly that name and namespace and carries one policy, `demo-app-read`:

```hcl
path "secret/data/demo/app" {
  capabilities = ["read"]
}
```

That is the whole policy: one path, read only. kv v2 stores the payload under `secret/data/...`, which is why the path says `data`. No list, no write, no `secret/metadata`. The token lives 15 minutes.

What is in the repo:

- `helm/`: values for the Vault chart (dev mode) and for External Secrets, plus a sketch of a real Raft/TLS install that only renders.
- `vault/policies/`: the two policies as files, so a change is a reviewable diff.
- `manifests/base/`: kustomize. Namespace, two ServiceAccounts, `SecretStore`, `ExternalSecret`, the app (a short Python HTTP server mounted from a ConfigMap) and its Service.
- `scripts/bootstrap-vault.sh`: kv v2, Kubernetes auth, policy, role, first value. Safe to run twice.
- `manifests/dynamic-db/` and `scripts/bootstrap-db.sh`: the extension, below.
- `scripts/e2e.sh`, `scripts/e2e-db.sh`, `tests/`: the checks that CI runs on kind, and a Docker-only test of the Vault side.

The app returns a fingerprint of the password (first 12 hex characters of sha256) and its length, never the value, so the answer is safe to print in a CI log.

## Rotation

```console
vault kv patch -mount=secret demo/app password=new-value
```

1. Vault writes kv v2 version 2.
2. The `ExternalSecret` has `refreshInterval: 15s`, so within that time External Secrets reads the new value and updates the Secret. 15 seconds is for the demo; the default is one hour, which is a fine number when an hour of delay is acceptable.
3. The Secret is mounted as a directory, and the app opens the file on every request. The kubelet refreshes the mounted files on its own sync period, so the pod sees the new value without a restart. The e2e script compares the pod UID and restart count before and after. In the two CI runs the Secret changed after 10 and 12 seconds and the app served the new value after 92 and 85 seconds, so the kubelet sync is the slower half.

I chose the file-and-re-read way because it needs nothing else in the cluster. Two things it does not cover. A `subPath` mount never gets updated. And an app that reads an environment variable (`secretKeyRef`) at startup keeps the old value until it restarts. For that the usual answer is Reloader (a controller that restarts a Deployment when its Secret changes, annotation `reloader.stakater.com/auto: "true"`), or `kubectl rollout restart`. I did not add or test Reloader here.

## Extension: dynamic Postgres credentials

Instead of a stored password, Vault's database engine creates a Postgres user on request and drops it when the lease ends.

- `scripts/bootstrap-db.sh` gives Vault an admin connection, a role `app-ro` (the issued user is a member of a `SELECT`-only group, valid 15 minutes, one hour at most) and a policy that reads only `database/creds/app-ro`.
- A second ServiceAccount, `eso-db`, and a second Vault role, `app-db`, so the account that can read the static secret cannot mint database users, and the other way round.
- The External Secrets `VaultDynamicSecret` generator reads the credentials and an `ExternalSecret` puts them in the Secret `app-db-creds`. `refreshInterval: 5m` is shorter than the 15-minute TTL on purpose, otherwise the Secret would hold a dead password.

Two things to know before using it. Every refresh asks Vault for a new user. The generator's `Cleanup` in the External Secrets source is empty, so the previous users are not revoked early, they disappear when their TTL runs out. And the Postgres admin password that Vault uses is created by `scripts/deploy-db.sh`, kept in a cluster Secret and in Vault's connection config; `vault write -f database/rotate-root/postgres` would take it out of human hands, but I did not do that.

## Quick start

Needs docker, kubectl, helm, python3 and, for the cluster part, kind. The cluster commands install Vault in dev mode into whatever the current kubectl context is, so use a throwaway cluster.

```console
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt
make check            # yamllint, kubeconform, shellcheck, actionlint
make docker-test      # Vault and Postgres in plain Docker, no Kubernetes

kind create cluster --name vault-demo --config kind/kind-config.yaml
make deploy           # Vault (dev mode), External Secrets, bootstrap, demo app
make e2e
make deploy-db && make e2e-db
```

Poking at it by hand:

```console
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=root vault kv patch -mount=secret demo/app password=changed
kubectl -n demo get secret app-secret -o jsonpath='{.data.password}' | base64 -d
kubectl get --raw /api/v1/namespaces/demo/services/app:http/proxy/
```

## What the e2e job checks

On a fresh kind cluster in GitHub Actions, in this order:

1. The ExternalSecret becomes Ready, the Secret holds the value that is in Vault, the Secret is owned by the ExternalSecret, the value appears in no tracked file, and the app reports the matching fingerprint.
2. Rotation: a new value in Vault reaches the Secret and then the app, with the same pod and restart count 0. The job prints how many seconds each step took.
3. A second `bootstrap-vault.sh` run does not reset the rotated value.
4. Least privilege. An ExternalSecret that asks for `secret/demo/other` (which exists) turns NotReady and creates no Secret; the condition message is generic, so the job looks in the controller log for Vault's 403 on that path. Three pods log in with their own projected token: the right ServiceAccount gets a token, can read one path and is refused on another path, on a write, on a list and on metadata; another ServiceAccount in the same namespace is refused; the same ServiceAccount name in another namespace is refused. The tokens all have audience `vault`, so a refusal can only come from the role binding.
5. Extension: the issued user can `SELECT` and cannot create a table; a wrong password is rejected (control); revoking the lease removes the user; a forced refresh produces a different user; the kv reader's ServiceAccount is refused by the `app-db` role.

## Verified

**On GitHub Actions** ([run 43005994410](https://github.com/Walaskien/vault-k8s-secrets/actions/runs/43005994410), `ubuntu-24.04` image 20261101.360.1, kind v0.33.0 with node 1.34.11): all three jobs green on commit `a54c079`.

| Job | Time | What it covered |
|---|---|---|
| `lint` | 18 s | `make check`: yamllint, kubeconform (External Secrets schemas from the datree catalog) on the rendered kustomize and Helm output, shellcheck, actionlint |
| `vault-docker` | 21 s | `make docker-test`: dev Vault 2.0.4 and Postgres 17.11 in Docker. Bootstrap twice, the policy allows one read and refuses the rest, rotation, `bootstrap-db.sh` twice, an issued Postgres user can `SELECT` and cannot `CREATE TABLE`, a wrong password is rejected, lease revoke removes the role |
| `e2e` | 3 m 46 s | Vault (dev mode) and External Secrets on kind, then `scripts/e2e.sh` and `scripts/e2e-db.sh`, every check passed (list below) |

What the e2e checks showed on a real cluster:

- The Secret holds the Vault value, is owned by the ExternalSecret, the value is in no tracked file, and the app reports the matching fingerprint.
- Rotation: the Secret changed after 10 s, the app served the new value after 92 s, same pod, restart count 0. The other run gave 12 s and 85 s. A second `bootstrap-vault.sh` run kept the rotated value.
- An ExternalSecret for `secret/demo/other` went NotReady and made no Secret; the controller log shows Vault's `403 permission denied` for that path.
- The pod with `demo/eso-demo` logged in, read `secret/demo/app` and was refused on another path, a write, a list and metadata. The pod with another ServiceAccount, and the pod with the same name in another namespace, were refused with `Code: 403 ... service account name not authorized`.
- Extension: the user issued through the ExternalSecret generator (`v-kubernet-app-ro-...`) could `SELECT`, was not a superuser and could not create a table; a wrong password was rejected; revoking a lease removed the user; a forced refresh gave a different user; the kv reader's ServiceAccount was refused by the `app-db` role.

The first run (`baa38a5`) failed on one assertion: I had assumed the ExternalSecret condition message would carry Vault's error, and it only says "could not get secret data from provider". The fix is in `a54c079`; everything else in that run had already passed.

**On the laptop before publishing**, without a cluster: the same linters as release binaries or pip packages, kubeconform controls (a misspelled field in a copy of the ExternalSecret and the SecretStore is reported invalid), the bootstrap scripts and policies against a native dev Vault 2.0.4 and Postgres 16.2, and the demo app run on its own with Python 3.9. The cluster work was never run locally, on purpose.

Not verified:

- **Anything beyond this setup.** One kind node, one replica of everything, kind's default CNI. Two e2e runs, one of them with the failed assertion above, so the rotation timing is two samples and not a measurement.
- **A real Vault.** Dev mode only. The Raft and TLS sketch in `helm/vault-raft-example-values.yaml` renders and passes kubeconform but has not been deployed; unseal, auto-unseal, TLS and snapshots in [docs/real-mode.md](docs/real-mode.md) are from the documentation, not from a run.
- **Reloader**, `rotate-root` for the Postgres admin password, and early revocation of old dynamic leases. The last one is read from the External Secrets source (the generator's `Cleanup` is empty), not observed in a cluster.
- **Docker Hub rate limits.** The images pulled fine in both runs; whether they always will is not something two runs can say.

## Limitations

- Dev mode, plain HTTP and a public root token. That is the demo, not a setup to copy; see [docs/real-mode.md](docs/real-mode.md).
- The Secret ends up as a normal Kubernetes Secret: base64 in etcd, readable by anyone who can `get` secrets in the namespace. Encryption at rest of etcd is a cluster setting and not covered. A CSI driver or the Vault agent injector avoid the Kubernetes Secret, at the price of more moving parts in every pod.
- The `SecretStore` is namespaced, but every ExternalSecret in `demo` can use it. Whoever may create ExternalSecrets there can read `secret/demo/app`, so the boundary is namespace RBAC plus the policy.
- Tested versions only: Vault chart 0.34.1 (Vault 2.0.4), External Secrets chart 2.15.0 (API `external-secrets.io/v1`), kubernetes 1.34.11 in kind, Postgres 17.11. A Vault role without `audience` only produces a warning, but with it set a token minted for another audience cannot log in, which is why both sides use `vault`.
- The CRD schemas for kubeconform come from a public catalog on GitHub (datreeio/CRDs-catalog). If it goes away the lint job fails until the location is changed.
- One replica of everything, no network policies, no resource tuning. The demo Postgres has no volume.
- The images come from Docker Hub and ghcr.io. If Docker Hub rate-limits the runner the e2e job can fail on image pull and needs a re-run.

## Layout

```
helm/                 Vault dev values, External Secrets values, a Raft/TLS sketch (renders, not deployed)
vault/policies/       demo-app-read.hcl, app-db-creds.hcl
manifests/base/       kustomize: namespace, ServiceAccounts, SecretStore, ExternalSecret, app, Service
manifests/dynamic-db/ extension: Postgres, init.sql, ServiceAccount, VaultDynamicSecret, ExternalSecret
scripts/              bootstrap-vault.sh, bootstrap-db.sh, deploy*.sh, e2e*.sh, lib.sh
tests/                access-check.sh (runs in a pod), docker-vault.sh (Vault and Postgres in Docker)
kind/                 single-node cluster config
docs/real-mode.md     dev mode against a real install
Makefile              lint and test targets, linters from pinned images
.github/workflows/    ci.yml
```

## Related

- [k8s-security-baseline](https://github.com/Walaskien/k8s-security-baseline): RBAC, Pod Security and admission policies for the namespace this kind of app lives in.
- [gitops-argocd](https://github.com/Walaskien/gitops-argocd): with GitOps the ExternalSecret manifest belongs in Git and the value does not, which is the split this repo shows.
- [cicd-k8s-delivery](https://github.com/Walaskien/cicd-k8s-delivery): a small app delivered to a kind cluster from CI.
