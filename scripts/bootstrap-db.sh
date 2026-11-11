#!/usr/bin/env bash
# Extension: Vault database secrets engine for the demo Postgres. Vault gets one
# admin connection, a role that describes what a generated user may do, a policy
# for reading that role and a Kubernetes auth role for the ServiceAccount that
# may ask. Safe to run again. Run bootstrap-vault.sh first (it enables the auth method).
#
# Needs VAULT_TOKEN and PG_ADMIN_PASSWORD.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

PG_HOST=${PG_HOST:-postgres.${APP_NS}.svc}
PG_PORT=${PG_PORT:-5432}
PG_DB=${PG_DB:-demo}
PG_ADMIN_USER=${PG_ADMIN_USER:-postgres}
: "${PG_ADMIN_PASSWORD:?PG_ADMIN_PASSWORD is not set}"
DB_SA=${DB_SA:-eso-db}

wait_for_vault
vault auth list | grep -q '^kubernetes/' || die "run scripts/bootstrap-vault.sh first, the kubernetes auth method is missing"

if vault secrets list | grep -q '^database/'; then
  log "secrets engine database/: already enabled"
else
  vault secrets enable database
  log "secrets engine database/: enabled"
fi

# JSON on stdin keeps the admin password out of the process arguments.
# The password is hex, so no quoting is needed here.
printf '{"plugin_name":"postgresql-database-plugin","allowed_roles":"app-ro","connection_url":"postgresql://{{username}}:{{password}}@%s:%s/%s?sslmode=disable","username":"%s","password":"%s"}' \
  "$PG_HOST" "$PG_PORT" "$PG_DB" "$PG_ADMIN_USER" "$PG_ADMIN_PASSWORD" |
  vault_stdin write database/config/postgres - >/dev/null
log "database/config/postgres: written (Vault checked the connection)"

# What a generated user is: a login role that is a member of app_readonly (created
# by manifests/dynamic-db/init.sql), valid for 15 minutes, up to an hour with renewals.
vault write database/roles/app-ro \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_readonly;" \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl=15m \
  max_ttl=1h >/dev/null
log "database/roles/app-ro: written"

vault_stdin policy write app-db-creds - <vault/policies/app-db-creds.hcl >/dev/null
vault write auth/kubernetes/role/app-db \
  bound_service_account_names="$DB_SA" \
  bound_service_account_namespaces="$APP_NS" \
  audience=vault \
  token_policies=app-db-creds \
  token_ttl=15m \
  token_max_ttl=1h >/dev/null
log "role app-db: ${APP_NS}/${DB_SA} -> app-db-creds"
