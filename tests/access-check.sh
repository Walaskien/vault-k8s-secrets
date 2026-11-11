#!/bin/sh
# Runs inside a pod that uses the vault image (busybox sh). The pod logs in to
# Vault with its own ServiceAccount token.
#   EXPECT=allow  the login must work and the policy must let exactly one read through
#   EXPECT=deny   the login must be refused
# Exit code 0 means the outcome was the expected one.
set -u
export VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc:8200}"
ROLE=${ROLE:-demo-app}
EXPECT=${EXPECT:-allow}
JWT=$(cat /var/run/secrets/tokens/vault-token)
fail=0

pass() { echo "ok    $*"; }
nope() { echo "FAIL  $*"; fail=1; }
oneline() { echo "$1" | tr '\n' ' ' | cut -c1-220; }

# The login can fail for boring reasons (network, wrong audience). Only a 403 from
# Vault counts as "refused by policy".
if out=$(vault write -field=token auth/kubernetes/login "role=$ROLE" "jwt=$JWT" 2>&1); then
  token=$out
  login=ok
else
  login=refused
fi

if [ "$EXPECT" = deny ]; then
  if [ "$login" = ok ]; then
    nope "login as role $ROLE worked, it should have been refused"
  elif echo "$out" | grep -Eiq '403|permission denied|not authorized'; then
    pass "login to role $ROLE refused: $(oneline "$out")"
  else
    nope "login failed, but not with a permission error: $(oneline "$out")"
  fi
  exit "$fail"
fi

if [ "$login" != ok ]; then
  nope "login to role $ROLE failed: $(oneline "$out")"
  exit 1
fi
pass "login to role $ROLE"
export VAULT_TOKEN="$token"

if vault kv get -field=username secret/demo/app >/dev/null 2>&1; then
  pass "read secret/demo/app"
else
  nope "read secret/demo/app was refused"
fi

# Each of these must fail, and fail with a permission error.
denied() {
  what=$1
  shift
  if res=$("$@" 2>&1); then
    nope "$what worked, it should not have"
  elif echo "$res" | grep -Eiq '403|permission denied'; then
    pass "$what refused"
  else
    nope "$what failed, but not with a permission error: $(oneline "$res")"
  fi
}
denied "read secret/demo/other" vault kv get secret/demo/other
denied "write secret/demo/app" vault kv put secret/demo/app password=changed
denied "list secret/demo" vault kv list secret/demo
denied "read metadata of secret/demo/app" vault kv metadata get secret/demo/app
exit "$fail"
