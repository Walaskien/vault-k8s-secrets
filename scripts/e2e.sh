#!/usr/bin/env bash
# End-to-end checks against the current kubectl context, after scripts/deploy.sh.
# Uses the dev mode root token to read and change values in Vault, like an admin would.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

export VAULT_TOKEN=${VAULT_TOKEN:-root}
ROTATE_TIMEOUT=${ROTATE_TIMEOUT:-240}

cleanup() {
  kubectl -n "$APP_NS" delete externalsecret/forbidden --ignore-not-found >/dev/null 2>&1 || true
  kubectl -n "$APP_NS" delete pod/allowed pod/intruder --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl -n "$APP_NS" delete serviceaccount/intruder --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete namespace other --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

secret_field() { kubectl -n "$APP_NS" get secret app-secret -o "jsonpath={.data.$1}" | base64 -d; }
vault_password() { vault kv get -mount=secret -field=password demo/app; }

echo "== 1. the secret reaches the cluster"
kubectl -n "$APP_NS" wait externalsecret/app-secret --for=condition=Ready --timeout=120s
pw=$(vault_password)
eq "Kubernetes Secret has the value that is in Vault" "$pw" "$(secret_field password)"
eq "Secret is owned by the ExternalSecret" ExternalSecret \
  "$(kubectl -n "$APP_NS" get secret app-secret -o jsonpath='{.metadata.ownerReferences[0].kind}')"
if git grep -qF -e "$pw" -- . 2>/dev/null; then
  nope "the password is in a tracked file"
else
  ok "the password is in no tracked file of this repository"
fi
want=$(printf %s "$pw" | sha12)
eq "app reports the fingerprint of that value" "$want" "$(app_answer | json_field password_sha256_12)"

echo "== 2. rotation: new value in Vault, no pod restart"
pod_before=$(kubectl -n "$APP_NS" get pod -l app.kubernetes.io/name=app -o jsonpath='{.items[0].metadata.uid}')
new="rotated-$(random_hex)"
vault kv patch -mount=secret demo/app "password=$new" >/dev/null
start=$SECONDS
secret_seen=""
app_seen=""
while [ $((SECONDS - start)) -lt "$ROTATE_TIMEOUT" ]; do
  if [ -z "$secret_seen" ] && [ "$(secret_field password)" = "$new" ]; then
    secret_seen=$((SECONDS - start))
  fi
  if [ -n "$secret_seen" ] && [ "$(app_answer | json_field password_sha256_12)" = "$(printf %s "$new" | sha12)" ]; then
    app_seen=$((SECONDS - start))
    break
  fi
  sleep 3
done
if [ -n "$secret_seen" ]; then ok "Kubernetes Secret updated after ${secret_seen} s (refreshInterval 15s)"; else nope "Kubernetes Secret not updated in ${ROTATE_TIMEOUT} s"; fi
if [ -n "$app_seen" ]; then ok "app serves the new value after ${app_seen} s (kubelet syncs the volume)"; else nope "app still serves the old value after ${ROTATE_TIMEOUT} s"; fi
eq "same pod, no restart" "$pod_before" \
  "$(kubectl -n "$APP_NS" get pod -l app.kubernetes.io/name=app -o jsonpath='{.items[0].metadata.uid}')"
eq "restart count is 0" 0 \
  "$(kubectl -n "$APP_NS" get pod -l app.kubernetes.io/name=app -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')"

echo "== 3. bootstrap is idempotent"
scripts/bootstrap-vault.sh 2>/dev/null
eq "second bootstrap run did not reset the rotated value" "$new" "$(vault_password)"

echo "== 4. least privilege"
vault kv put -mount=secret demo/other token=not-for-the-demo-app >/dev/null
kubectl -n "$APP_NS" apply -f - >/dev/null <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: forbidden
spec:
  refreshInterval: 15s
  secretStoreRef:
    kind: SecretStore
    name: vault
  target:
    name: forbidden
  data:
    - secretKey: token
      remoteRef:
        key: demo/other
        property: token
YAML
check "ExternalSecret for a path outside the policy turns NotReady" \
  kubectl -n "$APP_NS" wait externalsecret/forbidden --for=condition=Ready=False --timeout=90s
msg=$(kubectl -n "$APP_NS" get externalsecret/forbidden -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}')
if echo "$msg" | grep -Eiq 'permission denied|403'; then ok "reason is a Vault permission error"; else nope "unexpected reason: $msg"; fi
if kubectl -n "$APP_NS" get secret forbidden >/dev/null 2>&1; then nope "Secret 'forbidden' was created"; else ok "no Secret was created for it"; fi

kubectl -n "$APP_NS" create serviceaccount intruder >/dev/null
kubectl create namespace other >/dev/null
kubectl -n other create serviceaccount eso-demo >/dev/null
echo "-- pod with the right ServiceAccount (demo/eso-demo)"
check "allowed pod: login works, one read allowed, the rest refused" access_pod "$APP_NS" allowed eso-demo allow
echo "-- pod with another ServiceAccount in the same namespace (demo/intruder)"
check "intruder pod: login refused" access_pod "$APP_NS" intruder intruder deny
echo "-- pod with the same ServiceAccount name in another namespace (other/eso-demo)"
check "pod in another namespace: login refused" access_pod other intruder eso-demo deny

echo
if [ "$failed" -gt 0 ]; then
  echo "$failed check(s) failed"
  exit 1
fi
echo "all checks passed"
