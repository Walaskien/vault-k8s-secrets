# Dev mode and a real Vault

The Vault in this repo runs in dev mode (`server.dev.enabled: true` in `helm/vault-dev-values.yaml`). That is a mode for trying things out on a laptop. This page lists what changes when the data matters. I have not run Vault in production; this is what the documentation and the Helm chart say, plus the values sketch in `helm/vault-raft-example-values.yaml`, which renders but has not been deployed.

| | Dev mode (this repo) | A real install |
|---|---|---|
| Storage | In memory. A pod restart wipes everything, including the auth config and all secrets | Integrated Raft storage on persistent volumes (or Consul). Three or five replicas, snapshots for backup |
| Initialization | Done by `vault server -dev` | `vault operator init` once. It prints the unseal key shares and the first root token once, and Vault does not store the shares |
| Seal | Starts unsealed with one key | Starts sealed after every restart. Unseal with a threshold of key shares (Shamir, for example 3 of 5, held by different people), or auto-unseal through a cloud KMS, an HSM or the transit engine of another Vault |
| TLS | Plain HTTP on 8200 | TLS on the listener, certificates from a CA you run. Clients verify it |
| Root token | Fixed, `root`, written in the values file | Used for the first setup, then revoked. Daily work goes through auth methods and narrow policies. `vault operator generate-root` exists for emergencies |
| Audit | None | At least one audit device (file or socket), and someone reads it. With audit devices enabled, Vault stops answering requests when none of them can write |
| Availability | One pod | Raft leader plus standbys, a PodDisruptionBudget, anti-affinity |

## Unseal in practice

With the Helm chart a new real cluster comes up as pods that are Running but not Ready, because the readiness probe is `vault status`, which exits with 2 while Vault is sealed. The first start looks like this:

```console
kubectl -n vault exec vault-0 -- vault operator init -key-shares=5 -key-threshold=3
kubectl -n vault exec -it vault-0 -- vault operator unseal      # three times, three different keys
```

The other replicas join through `retry_join` in the Raft config and each still has to be unsealed (or use auto-unseal, which removes that step and the manual key handling after a node restart). Where the unseal keys are kept is the real question and has no answer in a repo.

## TLS

The listener needs `tls_cert_file` and `tls_key_file`, and every client needs the CA. In this repo that means two edits:

- `helm/vault-raft-example-values.yaml` shows the listener block and a `vault-tls` Secret mounted into the pod. Where the certificate comes from (cert-manager, an internal CA) is outside the repo.
- The External Secrets `SecretStore` changes to `server: https://vault.vault.svc:8200` and gets the CA, with `caProvider` (a Secret or ConfigMap) or `caBundle`.

## What else changes in the scripts

- `scripts/bootstrap-vault.sh` takes the token from `VAULT_TOKEN`. Run it with a token that has the rights to create mounts, policies and roles, not with the root token that you have already revoked.
- If Vault runs outside the cluster, the Kubernetes auth config can no longer use the pod's own token. It needs `kubernetes_host` reachable from Vault, `kubernetes_ca_cert`, and a `token_reviewer_jwt` of a ServiceAccount that has `system:auth-delegator`. The Vault Helm chart binds that role to the Vault ServiceAccount (`server.authDelegator`), which is enough only when Vault runs inside the same cluster.
- The seed step in the script (a random first value) is for the demo. A real secret gets its value from the person or system that owns it.
- A recovery path: `vault operator raft snapshot save` on a schedule, and a restore that somebody has actually practised.
