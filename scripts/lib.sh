# shellcheck shell=bash
# Shared by the bootstrap, deploy and e2e scripts. Source it, do not run it.

VAULT_NS=${VAULT_NS:-vault}
VAULT_POD=${VAULT_POD:-vault-0}
APP_NS=${APP_NS:-demo}

# How to run a command inside the Vault container. Pointing it at a plain
# Docker container also works: VAULT_EXEC="docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 vault-dev"
VAULT_EXEC=${VAULT_EXEC:-"kubectl -n $VAULT_NS exec -i $VAULT_POD -c vault --"}

log() { printf '%s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

run_in_vault() {
  local cmd
  [ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN is not set"
  read -r -a cmd <<<"$VAULT_EXEC"
  "${cmd[@]}" env "VAULT_TOKEN=$VAULT_TOKEN" vault "$@"
}

# No stdin, so a kubectl exec in a terminal never waits for input.
vault() { run_in_vault "$@" </dev/null; }
# Keeps stdin: for "vault policy write name -" and JSON on stdin.
vault_stdin() { run_in_vault "$@"; }

wait_for_vault() {
  for _ in $(seq 1 60); do
    if vault status >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  die "Vault is not ready after 120 s"
}

random_hex() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# First 12 hex characters of sha256 of stdin, the same fingerprint the demo app returns.
sha12() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-12
  else
    shasum -a 256 | cut -c1-12
  fi
}

# --- helpers for the e2e scripts ---------------------------------------------
failed=0
ok() { printf 'ok    %s\n' "$*"; }
nope() { printf 'FAIL  %s\n' "$*"; failed=$((failed + 1)); }

# check "<description>" <command...>
check() {
  local what=$1
  shift
  if "$@"; then ok "$what"; else nope "$what"; fi
}

# eq "<description>" <expected> <actual>
eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else nope "$1 (wanted '$2', got '$3')"; fi
}

# Asks the demo app through the API server's service proxy, so no port-forward is needed.
app_answer() {
  kubectl get --raw "/api/v1/namespaces/${APP_NS}/services/app:http/proxy/"
}

json_field() {
  python3 -c 'import json, sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"
}

# Runs scripts/../tests/access-check.sh in a short-lived pod and prints its log.
# access_pod <namespace> <name> <serviceaccount> <allow|deny> [vault role]
# The token is projected with audience "vault", the same as External Secrets requests,
# so a refusal can only come from the role binding.
access_pod() {
  local ns=$1 name=$2 sa=$3 expect=$4 role=${5:-demo-app} phase=""
  kubectl -n "$ns" create configmap access-check --from-file=tests/access-check.sh \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null
  kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${ns}
spec:
  serviceAccountName: ${sa}
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 100
    runAsGroup: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: check
      image: hashicorp/vault:2.0.4
      command: ["/bin/sh", "/scripts/access-check.sh"]
      env:
        - name: EXPECT
          value: "${expect}"
        - name: ROLE
          value: "${role}"
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: scripts
          mountPath: /scripts
          readOnly: true
        - name: vault-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
  volumes:
    - name: scripts
      configMap:
        name: access-check
    - name: vault-token
      projected:
        sources:
          - serviceAccountToken:
              audience: vault
              expirationSeconds: 600
              path: vault-token
YAML
  for _ in $(seq 1 90); do
    phase=$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$phase" in Succeeded | Failed) break ;; esac
    sleep 2
  done
  kubectl -n "$ns" logs "$name" 2>&1 | sed 's/^/      | /'
  [ "$phase" = Succeeded ]
}
