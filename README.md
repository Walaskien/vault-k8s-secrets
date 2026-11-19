# vault-k8s-secrets

[![ci](https://github.com/Walaskien/vault-k8s-secrets/actions/workflows/ci.yml/badge.svg)](https://github.com/Walaskien/vault-k8s-secrets/actions/workflows/ci.yml)

A Secret manifest in Git is base64, not encryption, and after a rotation the old password is still in the history. This lab keeps the value out of Git: HashiCorp Vault holds it, External Secrets Operator copies it into a normal Kubernetes Secret, and a small HTTP service reads that Secret. Change the value in Vault and the cluster follows within the refresh interval, with no commit and no pod restart.

Vault runs in dev mode here, so this is a demo lab and not a hardened Vault setup. In-memory storage, no TLS, auto-unsealed, and the root token (`root`) is written in `helm/vault-dev-values.yaml`. Everything is gone when the pod restarts. [docs/real-mode.md](docs/real-mode.md) lists what a real install would change.

## How it works

External Secrets asks the API server for a short-lived token of the ServiceAccount `demo/eso-demo` (audience `vault`) and logs in to Vault's Kubernetes auth method. Vault checks the token with the API server's TokenReview and matches it to the role `demo-app`, which is bound to that exact name and namespace and has one policy, `demo-app-read`: read on `secret/data/demo/app` and nothing else. The `ExternalSecret` then refreshes the Secret `app-secret` every 15 seconds (a demo value, the default is one hour). The app mounts the Secret as a directory and re-reads the file on every request, so the kubelet updates it under a running pod. The app returns a fingerprint of the password (first 12 hex characters of sha256) and its length, never the value.

In the repo: `helm/` (values for Vault in dev mode and External Secrets, plus a Raft/TLS sketch that only renders), `vault/policies/`, `manifests/base/` (kustomize), `scripts/` (bootstrap, deploy and e2e scripts), `tests/`, `kind/` and `docs/real-mode.md`.

## Rotation

```console
vault kv patch -mount=secret demo/app password=new-value
```

In the two CI runs the Secret changed after 10 and 12 seconds and the app served the new value after 92 and 85 seconds, so the kubelet sync is the slower half. The e2e script compares pod UID and restart count before and after.

This only works for a file mount. A `subPath` mount never gets updated, and an app that reads an environment variable at startup keeps the old value until it restarts. Reloader or `kubectl rollout restart` would handle that, but I did not add or test Reloader here.

## Extension: dynamic Postgres credentials

Vault's database engine can create a Postgres user on request and drop it when the lease ends. `scripts/bootstrap-db.sh` sets up a role `app-ro` (a `SELECT`-only user, 15 minutes, one hour at most) and a separate Vault role `app-db` for a second ServiceAccount, so the account that reads the static secret cannot mint database users. An `ExternalSecret` with the `VaultDynamicSecret` generator puts the credentials in `app-db-creds`, refreshed every 5 minutes.

Every refresh creates a new user. From reading the External Secrets source, the generator's `Cleanup` is empty, so old users are not revoked early and only disappear when their TTL runs out. I did not observe this in a cluster. The Postgres admin password is created by `scripts/deploy-db.sh` and stored in a cluster Secret and in Vault's connection config. I did not rotate it with `rotate-root`.

## Quick start

Needs docker, kubectl, helm, python3 and kind. The cluster commands install Vault in dev mode into the current kubectl context, so use a throwaway cluster.

```console
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements-dev.txt
make check            # yamllint, kubeconform, shellcheck, actionlint
make docker-test      # Vault and Postgres in plain Docker, no Kubernetes

kind create cluster --name vault-demo --config kind/kind-config.yaml
make deploy           # Vault (dev mode), External Secrets, bootstrap, demo app
make e2e
make deploy-db && make e2e-db
```

## Verified

On GitHub Actions ([run 43005994410](https://github.com/Walaskien/vault-k8s-secrets/actions/runs/43005994410), kind v0.33.0 with node 1.34.11) all three jobs were green on commit `a54c079`: lint (yamllint, kubeconform, shellcheck, actionlint), `vault-docker` (`make docker-test` with Vault 2.0.4 and Postgres 17.11) and `e2e` on kind (`scripts/e2e.sh` and `scripts/e2e-db.sh`, about 3m46s).

The e2e scripts check that the Secret matches Vault and is owned by the ExternalSecret, that rotation reaches the app with the same pod and restart count 0, and that a second bootstrap run keeps the rotated value. For least privilege, an ExternalSecret for another path goes NotReady and makes no Secret, and pods with the right, a wrong and a same-named ServiceAccount from another namespace get the expected results (read allowed on one path, 403 on everything else, 403 for the other two). For the extension, the issued Postgres user can `SELECT` but not create a table, a wrong password is rejected, revoking the lease removes the user, and a forced refresh gives a different user.

The first run (`baa38a5`) failed on one assertion: I had assumed the ExternalSecret condition message would carry Vault's error, but it only says "could not get secret data from provider". The fix is in `a54c079`.

Before publishing I also ran the linters, the bootstrap scripts against a native dev Vault 2.0.4 and Postgres 16.2, and the demo app with Python 3.9 on the laptop. The cluster part was never run locally.

Not verified: anything beyond one kind node with one replica of everything; a real Vault (the Raft/TLS sketch renders and passes kubeconform but was never deployed, and docs/real-mode.md is from the documentation, not from a run); Reloader; `rotate-root`; early revocation of dynamic leases. Rotation timing is two samples, not a measurement.

## Limitations

- Dev mode, plain HTTP and a public root token. That is the demo, not a setup to copy.
- The Secret ends up as a normal Kubernetes Secret: base64 in etcd, readable by anyone who can `get` secrets in the namespace. Encryption at rest of etcd is a cluster setting and not covered.
- Every ExternalSecret in `demo` can use the `SecretStore`, so the boundary is namespace RBAC plus the Vault policy.
- Tested versions only: Vault chart 0.34.1 (Vault 2.0.4), External Secrets chart 2.15.0, Kubernetes 1.34.11 in kind, Postgres 17.11.
- The CRD schemas for kubeconform come from a public catalog on GitHub (datreeio/CRDs-catalog). If it goes away the lint job fails until the location is changed.
- No network policies, no resource tuning, and the demo Postgres has no volume. If Docker Hub rate-limits the runner, the e2e job can fail on image pull and needs a re-run.

## Related

- [gitops-argocd](https://github.com/Walaskien/gitops-argocd): with GitOps the ExternalSecret manifest belongs in Git and the value does not, which is the split this repo shows.
- [cicd-k8s-delivery](https://github.com/Walaskien/cicd-k8s-delivery): a small app delivered to a kind cluster from CI.
