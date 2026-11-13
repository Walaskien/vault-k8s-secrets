#!/usr/bin/env bash
# Configures Vault for the demo: a kv v2 mount, the Kubernetes auth method, one
# policy, one role, and a first value for the secret. Safe to run again: it
# enables only what is missing, rewrites the policy and the role, and seeds the
# secret only when it does not exist yet, so a rotated value is not undone.
#
# Needs VAULT_TOKEN. For the demo Vault that is "root" (dev mode), see the Makefile.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

KV_MOUNT=${KV_MOUNT:-secret}
SECRET_PATH=${SECRET_PATH:-demo/app}
POLICY=${POLICY:-demo-app-read}
ROLE=${ROLE:-demo-app}
ESO_SA=${ESO_SA:-eso-demo}
KUBE_HOST=${KUBE_HOST:-https://kubernetes.default.svc:443}
# Vault reads the CA file of its own pod when the auth config is written. Outside a
# pod, as in tests/docker-vault.sh, there is none, and this switch skips it.
NO_LOCAL_CA=${K8S_AUTH_NO_LOCAL_CA:-false}

: "${VAULT_TOKEN:?VAULT_TOKEN is not set}"
wait_for_vault

# 1. kv v2. Dev mode already mounts it at secret/; a real Vault does not.
if vault secrets list | grep -q "^${KV_MOUNT}/"; then
  if ! vault secrets list -detailed | grep "^${KV_MOUNT}/" | grep -q "version:2"; then
    die "${KV_MOUNT}/ exists but is not kv v2, not touching it"
  fi
  log "kv v2 at ${KV_MOUNT}/: already there"
else
  vault secrets enable -path="$KV_MOUNT" -version=2 kv
  log "kv v2 at ${KV_MOUNT}/: enabled"
fi

# 2. Kubernetes auth. Vault checks ServiceAccount tokens with the TokenReview API.
# Inside the cluster it uses its own pod token and CA, and the chart binds
# system:auth-delegator to the Vault ServiceAccount, so no reviewer JWT is passed.
if vault auth list | grep -q '^kubernetes/'; then
  log "auth kubernetes/: already enabled"
else
  vault auth enable kubernetes
  log "auth kubernetes/: enabled"
fi
config_extra=()
if [ "$NO_LOCAL_CA" = true ]; then config_extra+=(disable_local_ca_jwt=true); fi
vault write auth/kubernetes/config \
  kubernetes_host="$KUBE_HOST" \
  disable_iss_validation=true \
  ${config_extra[@]+"${config_extra[@]}"} >/dev/null

# 3. Policy, from the file in the repo.
vault_stdin policy write "$POLICY" - <"vault/policies/${POLICY}.hcl" >/dev/null
log "policy ${POLICY}: written"

# 4. Role: one ServiceAccount in one namespace, nothing else gets a token.
# The audience has to match serviceAccountRef.audiences in the SecretStore.
vault write "auth/kubernetes/role/${ROLE}" \
  bound_service_account_names="$ESO_SA" \
  bound_service_account_namespaces="$APP_NS" \
  audience=vault \
  token_policies="$POLICY" \
  token_ttl=15m \
  token_max_ttl=1h >/dev/null
log "role ${ROLE}: ${APP_NS}/${ESO_SA} -> ${POLICY}"

# 5. First value, random, never printed and never in Git.
# Only "No value found" means there is none. Any other failure (Vault sealed,
# connection refused, a timeout) must not end in a new random value over a live one.
if out=$(vault kv get -mount="$KV_MOUNT" "$SECRET_PATH" 2>&1); then
  log "secret ${KV_MOUNT}/${SECRET_PATH}: exists, left as it is"
elif [[ "$out" != *"No value found"* ]]; then
  die "could not read ${KV_MOUNT}/${SECRET_PATH}: $out"
else
  vault kv put -mount="$KV_MOUNT" "$SECRET_PATH" username=demo-app "password=$(random_hex)" >/dev/null
  log "secret ${KV_MOUNT}/${SECRET_PATH}: seeded with a random password"
fi
