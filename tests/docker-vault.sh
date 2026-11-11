#!/usr/bin/env bash
# Runs the Vault side of the repo in plain Docker, no Kubernetes: a dev-mode Vault
# and a Postgres on one network. It checks that the bootstrap scripts can be run
# twice, that the policy gives exactly what it says, and that the database engine
# creates and removes users. It cannot check the Kubernetes login, that needs a
# cluster (scripts/e2e.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

VAULT_IMAGE=${VAULT_IMAGE:-hashicorp/vault:2.0.4}
PG_IMAGE=${PG_IMAGE:-postgres:17.11-alpine}
NET=vkt-test-net
VC=vkt-test-vault
PC=vkt-test-pg

cleanup() {
  docker rm -f "$VC" "$PC" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

docker network create "$NET" >/dev/null
docker run -d --name "$VC" --network "$NET" -e VAULT_DEV_ROOT_TOKEN_ID=root \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 "$VAULT_IMAGE" server -dev >/dev/null
PG_ADMIN_PASSWORD=$(random_hex)
export PG_ADMIN_PASSWORD
docker run -d --name "$PC" --network "$NET" -e POSTGRES_DB=demo -e "POSTGRES_PASSWORD=$PG_ADMIN_PASSWORD" \
  -v "$PWD/manifests/dynamic-db/init.sql:/docker-entrypoint-initdb.d/init.sql:ro" "$PG_IMAGE" >/dev/null

export VAULT_TOKEN=root
export VAULT_EXEC="docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 $VC"
export PG_HOST=$PC
# No pod here, so no CA file for the Kubernetes auth config to read.
export K8S_AUTH_NO_LOCAL_CA=true

# Vault as a given token, with a clean environment, to see what a policy allows.
vault_as() {
  local token=$1
  shift
  docker exec -e VAULT_ADDR=http://127.0.0.1:8200 -e "VAULT_TOKEN=$token" "$VC" vault "$@" </dev/null
}
# The Postgres image trusts 127.0.0.1, so connect to the container's own address.
psql_as() {
  local user=$1 pass=$2
  shift 2
  # shellcheck disable=SC2016  # the $1..$3 are for the inner shell on purpose
  docker exec "$PC" sh -c 'PGPASSWORD="$1" psql -h "$(hostname -i)" -U "$2" -d demo -tA -c "$3"' _ "$pass" "$user" "$*"
}
refused() {
  local what=$1 out
  shift
  if out=$("$@" 2>&1); then
    nope "$what worked, it should have been refused"
  elif echo "$out" | grep -qi 'permission denied'; then
    ok "$what refused (permission denied)"
  else
    nope "$what failed for another reason: $out"
  fi
}

echo "== bootstrap-vault.sh, twice"
scripts/bootstrap-vault.sh
first=$(vault kv get -mount=secret -field=password demo/app)
scripts/bootstrap-vault.sh
eq "second run left the secret alone" "$first" "$(vault kv get -mount=secret -field=password demo/app)"
eq "secret has one version" 1 "$(vault read -field=current_version secret/metadata/demo/app)"
eq "role is bound to demo/eso-demo" "[eso-demo]" "$(vault read -field=bound_service_account_names auth/kubernetes/role/demo-app)"
eq "role namespace" "[demo]" "$(vault read -field=bound_service_account_namespaces auth/kubernetes/role/demo-app)"
eq "role audience" vault "$(vault read -field=audience auth/kubernetes/role/demo-app)"

echo "== what the policy allows"
vault kv put -mount=secret demo/other token=other >/dev/null
tok=$(vault token create -policy=demo-app-read -no-default-policy -field=token)
eq "read secret/demo/app" demo-app "$(vault_as "$tok" kv get -mount=secret -field=username demo/app)"
refused "read secret/demo/other" vault_as "$tok" kv get -mount=secret demo/other
refused "write secret/demo/app" vault_as "$tok" kv put -mount=secret demo/app password=changed
refused "list secret/demo" vault_as "$tok" kv list -mount=secret demo
refused "read metadata of demo/app" vault_as "$tok" kv metadata get -mount=secret demo/app
refused "read the auth config" vault_as "$tok" read auth/kubernetes/config

echo "== rotation in Vault (kv v2 versions)"
vault kv patch -mount=secret demo/app password=rotated-1 >/dev/null
eq "reader sees the new value" rotated-1 "$(vault_as "$tok" kv get -mount=secret -field=password demo/app)"
eq "version is now 2" 2 "$(vault read -field=current_version secret/metadata/demo/app)"
scripts/bootstrap-vault.sh 2>/dev/null
eq "bootstrap after rotation keeps the rotated value" rotated-1 "$(vault kv get -mount=secret -field=password demo/app)"

echo "== bootstrap-db.sh, twice"
# Over TCP: the init scripts run on a temporary server that has no TCP listener.
for _ in $(seq 1 60); do
  docker exec "$PC" pg_isready -h 127.0.0.1 -U postgres -d demo >/dev/null 2>&1 && break
  sleep 2
done
scripts/bootstrap-db.sh
scripts/bootstrap-db.sh
db_tok=$(vault token create -policy=app-db-creds -no-default-policy -field=token)
refused "kv reader policy asking for database creds" vault_as "$tok" read database/creds/app-ro
refused "db policy reading the kv secret" vault_as "$db_tok" read secret/data/demo/app

echo "== dynamic credentials"
creds=$(vault_as "$db_tok" read -format=json database/creds/app-ro)
user=$(printf %s "$creds" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["username"])')
pass=$(printf %s "$creds" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["password"])')
lease=$(printf %s "$creds" | json_field lease_id)
case "$user" in v-*) ok "issued username: $user" ;; *) nope "unexpected username $user" ;; esac
eq "issued user can select" 2 "$(psql_as "$user" "$pass" 'select count(*) from items')"
eq "connected as that user" "$user" "$(psql_as "$user" "$pass" 'select current_user')"
if res=$(psql_as "$user" "$pass" 'create table t (id int)' 2>&1); then
  nope "issued user could create a table"
elif echo "$res" | grep -qi 'permission denied'; then
  ok "create table refused (permission denied)"
else
  nope "create table failed for another reason: $res"
fi
if psql_as "$user" "x$pass" 'select 1' >/dev/null 2>&1; then nope "wrong password accepted"; else ok "control: wrong password rejected"; fi
eq "ttl of the lease is 15 minutes" 900 "$(printf %s "$creds" | json_field lease_duration)"
vault lease revoke "$lease" >/dev/null
sleep 1
if psql_as "$user" "$pass" 'select 1' >/dev/null 2>&1; then nope "user works after lease revoke"; else ok "after lease revoke the user cannot log in"; fi
eq "role removed from Postgres" 0 "$(psql_as postgres "$PG_ADMIN_PASSWORD" "select count(*) from pg_roles where rolname = '$user'")"

echo
if [ "$failed" -gt 0 ]; then
  echo "$failed check(s) failed"
  exit 1
fi
echo "all checks passed"
