#!/usr/bin/env bash
# Installs Vault in DEV MODE and External Secrets into the current kubectl
# context, configures Vault and applies the demo app. DEMO ONLY: dev mode, root
# token "root", plain HTTP. Do not point this at a cluster you care about.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

VAULT_CHART_VERSION=${VAULT_CHART_VERSION:-0.34.1}
ESO_CHART_VERSION=${ESO_CHART_VERSION:-2.15.0}

# The ESO webhook can take a few seconds after the Deployment is Ready before it
# answers with a certificate the API server trusts, so the first apply may fail.
retry() {
  local tries=$1 i
  shift
  for i in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    log "attempt $i/$tries failed: $*"
    sleep 10
  done
  return 1
}

helm repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null
helm repo add external-secrets https://charts.external-secrets.io --force-update >/dev/null

helm upgrade --install vault hashicorp/vault --version "$VAULT_CHART_VERSION" \
  --namespace "$VAULT_NS" --create-namespace -f helm/vault-dev-values.yaml --wait --timeout 5m

helm upgrade --install external-secrets external-secrets/external-secrets --version "$ESO_CHART_VERSION" \
  --namespace external-secrets --create-namespace -f helm/eso-values.yaml --wait --timeout 5m

# Dev mode root token. A real Vault never gets this treatment.
export VAULT_TOKEN=${VAULT_TOKEN:-root}
scripts/bootstrap-vault.sh

retry 6 kubectl apply -k manifests/base
kubectl -n "$APP_NS" wait externalsecret/app-secret --for=condition=Ready --timeout=180s
kubectl -n "$APP_NS" rollout status deployment/app --timeout=180s
