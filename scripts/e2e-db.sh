#!/usr/bin/env bash
# End-to-end checks for the dynamic database credentials extension, after
# scripts/deploy.sh and scripts/deploy-db.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

export VAULT_TOKEN=${VAULT_TOKEN:-root}

cleanup() {
  kubectl -n "$APP_NS" delete pod/db-intruder --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

# psql inside the Postgres pod. The image trusts 127.0.0.1, so connect to the pod
# IP, where the password is really checked.
psql_as() {
  local user=$1 pass=$2
  shift 2
  # shellcheck disable=SC2016  # the $1..$3 are for the inner shell on purpose
  kubectl -n "$APP_NS" exec deploy/postgres -- sh -c \
    'PGPASSWORD="$1" psql -h "$(hostname -i)" -U "$2" -d demo -tA -c "$3"' _ "$pass" "$user" "$*"
}
secret_field() { kubectl -n "$APP_NS" get secret app-db-creds -o "jsonpath={.data.$1}" | base64 -d; }

echo "== 1. credentials come from Vault, not from Git"
kubectl -n "$APP_NS" wait externalsecret/app-db-creds --for=condition=Ready --timeout=120s
user=$(secret_field username)
pass=$(secret_field password)
case "$user" in v-*) ok "username was issued by Vault ($user)" ;; *) nope "unexpected username $user" ;; esac
if git grep -qF -e "$pass" -- . 2>/dev/null; then nope "the db password is in a tracked file"; else ok "the db password is in no tracked file"; fi

echo "== 2. the issued user works, and only as far as the role says"
eq "select works" 2 "$(psql_as "$user" "$pass" 'select count(*) from items')"
eq "connected as the issued user" "$user" "$(psql_as "$user" "$pass" 'select current_user')"
eq "not a superuser" f "$(psql_as "$user" "$pass" "select rolsuper from pg_roles where rolname = current_user")"
if res=$(psql_as "$user" "$pass" 'create table should_fail (id int)' 2>&1); then
  nope "create table worked for a read-only user"
elif echo "$res" | grep -qi 'permission denied'; then
  ok "create table refused (permission denied)"
else
  nope "create table failed for another reason: $res"
fi
if psql_as "$user" "wrong-$pass" 'select 1' >/dev/null 2>&1; then
  nope "a wrong password was accepted, the checks above prove nothing"
else
  ok "control: a wrong password is rejected"
fi

echo "== 3. the lease controls the user"
creds=$(vault read -format=json database/creds/app-ro)
lease=$(printf %s "$creds" | json_field lease_id)
tmp_user=$(printf %s "$creds" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["username"])')
tmp_pass=$(printf %s "$creds" | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["password"])')
eq "fresh user can log in" 2 "$(psql_as "$tmp_user" "$tmp_pass" 'select count(*) from items')"
vault lease revoke "$lease" >/dev/null
sleep 2
if psql_as "$tmp_user" "$tmp_pass" 'select 1' >/dev/null 2>&1; then nope "user still works after the lease was revoked"; else ok "after lease revoke the user cannot log in"; fi
eq "the role is gone from Postgres" 0 \
  "$(psql_as postgres "$(kubectl -n "$APP_NS" get secret postgres-root -o jsonpath='{.data.password}' | base64 -d)" "select count(*) from pg_roles where rolname = '$tmp_user'")"

echo "== 4. a refresh issues a new user"
kubectl -n "$APP_NS" annotate externalsecret/app-db-creds "force-sync=$(date +%s)" --overwrite >/dev/null
changed=""
for _ in $(seq 1 30); do
  if [ "$(secret_field username)" != "$user" ]; then changed=yes; break; fi
  sleep 2
done
if [ -n "$changed" ]; then ok "Secret now holds a different issued user"; else nope "Secret still has the old user after a forced refresh"; fi

echo "== 5. the kv reader cannot ask for database credentials"
check "pod as demo/eso-demo: login to role app-db refused" access_pod "$APP_NS" db-intruder eso-demo deny app-db

echo
if [ "$failed" -gt 0 ]; then
  echo "$failed check(s) failed"
  exit 1
fi
echo "all checks passed"
