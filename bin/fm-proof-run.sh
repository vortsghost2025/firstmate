#!/usr/bin/env bash
# fm-proof-run.sh - execute a registered, pinned proof spec for one task.
#
# This runner never writes the project worktree. It reads the captain-authored
# proof spec (bound by sha256 to a trust record at registration time), executes
# the whitelisted read-only evaluators in bin/fm-proof-lib.sh, and appends one
# tab-separated verdict row per proof line to state/<id>.proof.log.
#
# Verdicts: PASS | FAIL | UNKNOWN. Fail-closed: ambiguity is UNKNOWN, never PASS.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

. "$SCRIPT_DIR/fm-pr-lib.sh"
. "$SCRIPT_DIR/fm-proof-lib.sh"

usage() { printf 'usage: fm-proof-run.sh <task-id>\n' >&2; exit 2; }
[ $# -eq 1 ] || usage
TASK_ID=$1
fm_pr_task_id_valid "$TASK_ID" || { printf 'refused: invalid task id %s\n' "$TASK_ID" >&2; exit 1; }

SPEC="$STATE/$TASK_ID.proof.spec"
TRUST="$STATE/$TASK_ID.proof.trust"
LOG="$STATE/$TASK_ID.proof.log"

# The spec must exist as a regular, non-symlinked file and be pinned on disk.
[ -e "$SPEC" ] && [ ! -L "$SPEC" ] || { echo "unknown: proof spec absent or unsafe: $SPEC" >&2; exit 1; }
[ -e "$TRUST" ] && [ ! -L "$TRUST" ] || { echo "unknown: proof trust record absent or unsafe: $TRUST" >&2; exit 1; }

REGISTERED_HASH=$(awk 'NR==2' "$TRUST")
[ -n "$REGISTERED_HASH" ] || { echo "unknown: proof trust record empty" >&2; exit 1; }
SPEC_HASH=$(sha256sum -- "$SPEC" 2>/dev/null | awk '{print $1}')
[ -n "$SPEC_HASH" ] || { echo "unknown: proof spec cannot be hashed" >&2; exit 1; }
[ "$REGISTERED_HASH" = "$SPEC_HASH" ] || {
  printf 'refused: proof spec hash mismatch for %s\n' "$TASK_ID" >&2
  exit 1
}

# Task worktree identity: read the recorded workspace and canonicalize once.
META="$STATE/$TASK_ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "unknown: task metadata absent or unsafe: $META" >&2; exit 1; }
RECORDED_WORKSPACE=$(sed -n 's/^workspace=//p' "$META" | head -1)
[ -n "$RECORDED_WORKSPACE" ] || { echo "unknown: task metadata has no workspace field" >&2; exit 1; }
REAL_WORKSPACE=$(readlink -f -- "$RECORDED_WORKSPACE" 2>/dev/null)
[ -n "$REAL_WORKSPACE" ] && [ -d "$REAL_WORKSPACE" ] || {
  echo "unknown: workspace cannot be canonicalized: $RECORDED_WORKSPACE" >&2; exit 1; }

total=0 passed=0 failed=0 unknown=0

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  total=$((total + 1))

  # Strict four-field shape: reject anything else before touching the filesystem.
  nf=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
  IFS=$'\t' read -r proof_id type subject expected <<< "$line"
  if [ "$nf" -ne 4 ]; then
    verdictLabel="UNKNOWN"; observed="malformed spec line (fields=$nf)"
  else
    case "$type" in
      file_exists|file_absent|exact_text|regex_match)
        if [ -z "$subject" ]; then
          verdictLabel="UNKNOWN"; observed="empty subject"
        else
          canon=$(realpath -m -- "$REAL_WORKSPACE/$subject" 2>/dev/null)
          case "$canon" in "$REAL_WORKSPACE"/*) ;; *) canon="";; esac
          if [ -z "$canon" ]; then
            verdictLabel="UNKNOWN"; observed="subject outside workspace"
          else
            case "$type" in
              file_exists)  observed=$(fm_proof_eval_file_exists "$canon"); rc=$? ;;
              file_absent)  observed=$(fm_proof_eval_file_absent "$canon"); rc=$? ;;
              exact_text)   observed=$(fm_proof_eval_exact_text "$canon" "$expected"); rc=$? ;;
              regex_match)  observed=$(fm_proof_eval_regex_match "$canon" "$expected"); rc=$? ;;
            esac
            case "$rc" in
              0) verdictLabel="PASS" ;;
              1) verdictLabel="FAIL" ;;
              *) verdictLabel="UNKNOWN" ;;
            esac
          fi
        fi
        ;;
      command_exit)
        # V1 never executes raw commands - a "command exit" proof is verified only
        # via the observed exit code on the registered check's output. Absent a
        # registered check snapshot, a command_exit proof is never a PASS.
        verdictLabel="UNKNOWN"
        observed="command_exit requires a trusted registered check; raw commands are never acceptable"
        ;;
      *)
        verdictLabel="UNKNOWN"; observed="unsupported proof type: $type"
        ;;
    esac
  fi

  case "$verdictLabel" in
    PASS) passed=$((passed + 1)) ;;
    FAIL) failed=$((failed + 1)) ;;
    *) unknown=$((unknown + 1)) ;;
  esac
  fm_proof_write_row "$LOG" "$proof_id" "$type" "$subject" "$expected" "$observed" "$verdictLabel"
done < "$SPEC"

printf 'TOTAL=%d PASS=%d FAIL=%d UNKNOWN=%d\n' "$total" "$passed" "$failed" "$unknown"
if [ "$passed" -eq "$total" ] && [ "$total" -gt 0 ]; then
  printf 'VERDICT=PASS\n'
  exit 0
elif [ "$failed" -gt 0 ]; then
  printf 'VERDICT=FAIL\n'
  exit 1
fi
printf 'VERDICT=UNKNOWN\n'
exit 2
