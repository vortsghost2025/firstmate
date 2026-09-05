#!/usr/bin/env bash
# bin/fm-proof-register.sh - register a proof spec and sha256-pin its bytes.
#
# A spec file is NOT trusted until this script explicitly records its exact
# byte-content hash. This is the gate that stops a worker from silently
# rerunning its task on a rewritten rubric.
#
# Usage: bin/fm-proof-register.sh <task-id> <spec-path>
#
# Spec lines are `proof_id <TAB> type <TAB> subject <TAB> expected`.
# The spec must be regular, on the local state device, never a symlink.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ $# -ne 2 ]; then
  printf 'usage: fm-proof-register.sh <task-id> <spec-path>\n' >&2
  exit 2
fi

TASK_ID=$1
SPEC=$2

fm_pr_task_id_valid "$TASK_ID" || { printf 'refused: invalid task id %s\n' "$TASK_ID" >&2; exit 1; }
[ -f "$SPEC" ] || { printf 'refused: proof spec absent: %s\n' "$SPEC" >&2; exit 1; }
[ ! -L "$SPEC" ] || { printf 'refused: proof spec is a symlink\n' >&2; exit 1; }

if [ ! -d "$STATE" ]; then
  printf 'refused: state directory absent: %s\n' "$STATE" >&2
  exit 1
fi

TRUST_FILE="$STATE/$TASK_ID.proof.trust"

# Hash the exact current bytes; report any write failure loudly.
HASH=$(sha256sum -- "$SPEC" | awk '{print $1}') || {
  printf 'refused: cannot hash the proof spec: %s\n' "$SPEC" >&2
  exit 1
}

if ! cat > "$TRUST_FILE" <<EOF 2>/dev/null; then
fm-proof-trust v1
$HASH
EOF
  printf 'refused: could not write trust record: %s\n' "$TRUST_FILE" >&2
  rm -f -- "$TRUST_FILE"
  exit 1
fi
chmod 0600 "$TRUST_FILE" || exit 1

# Prove the write: read back and compare. Anything less would mask corruption.
READBACK=$(awk 'NR==2' "$TRUST_FILE" 2>/dev/null)
[ "$READBACK" = "$HASH" ] || {
  printf 'refused: trust record mismatch on readback\n' >&2
  rm -f -- "$TRUST_FILE"
  exit 1
}

printf 'registered trust record %s, spec hash is regimen-pinned to state/%s.proof.spec\n' "$TRUST_FILE" "$TASK_ID"
