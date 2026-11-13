#!/usr/bin/env bash
# Used as VAULT_EXEC in tests/docker-vault.sh. Runs the command in the Vault
# container like the plain docker exec does, and can break it on purpose:
#   FAIL_ON='kv get'  fails every call whose arguments contain that text
#   ARGV_LOG=file     appends the arguments of every call to that file
set -euo pipefail
VC=${VC:-vkt-test-vault}
if [ -n "${ARGV_LOG:-}" ]; then printf '%s\n' "$*" >>"$ARGV_LOG"; fi
if [ -n "${FAIL_ON:-}" ] && [[ "$*" == *"$FAIL_ON"* ]]; then
  echo "Error: connection refused" >&2
  exit 2
fi
exec docker exec -i -e VAULT_ADDR=http://127.0.0.1:8200 "$VC" "$@"
