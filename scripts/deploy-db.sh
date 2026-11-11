#!/usr/bin/env bash
# Extension: demo Postgres plus dynamic credentials from the Vault database
# engine, delivered by the External Secrets VaultDynamicSecret generator.
# Run scripts/deploy.sh first.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

export VAULT_TOKEN=${VAULT_TOKEN:-root}

# The admin password lives only in the cluster and in Vault's connection config.
if ! kubectl -n "$APP_NS" get secret postgres-root >/dev/null 2>&1; then
  kubectl -n "$APP_NS" create secret generic postgres-root "--from-literal=password=$(random_hex)"
fi

kubectl apply -k manifests/dynamic-db
kubectl -n "$APP_NS" rollout status deployment/postgres --timeout=180s

PG_ADMIN_PASSWORD=$(kubectl -n "$APP_NS" get secret postgres-root -o jsonpath='{.data.password}' | base64 -d)
export PG_ADMIN_PASSWORD
scripts/bootstrap-db.sh

# The ExternalSecret was applied before Vault knew the role and may be backing
# off after an error. Touching it makes the controller look again at once.
kubectl -n "$APP_NS" annotate externalsecret/app-db-creds "force-sync=$(date +%s)" --overwrite
kubectl -n "$APP_NS" wait externalsecret/app-db-creds --for=condition=Ready --timeout=180s
