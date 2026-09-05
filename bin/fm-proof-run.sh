#!/usr/bin/env bash
# bin/fm-proof-run.sh - execute the task's registered proof spec and append one
# verdict row per proof line to the task's state log.
#
# Usage: bin/fm-proof-run.sh <task-id>
#
# The runner only ever reads from the task worktree and never writes its own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

. "$SCRIPT_DIR/fm-pr-lib.sh"
. "$SCRIPT_DIR/fm-proof-lib.sh"

TASK_ID=${1:?usage: fm-proof-run.sh <task-id>}
fm_pr_task_id_valid "$TASK_ID" || { printf 'error: invalid task id: %s\n' "$TASK_ID" >&2; exit 1; }

SPEC="$STATE/$TASK_ID.proof.spec"
TRUST="$STATE/$TASK_ID.proof.trust"

# Presence + pinning proof must hold before we interpret any line of the spec.
[ -f "$SPEC" ] || { printf 'error: proof spec absent: %s\n' "$SPEC" >&2; exit 1; }
[ ! -L "$SPEC" ] || { printf 'error: proof spec is a symlink: %s\n' "$SPEC" >&2; exit 1; }
[ -f "$TRUST" ] || { printf 'error: proof trust record absent: %s\n' "$TRUST" >&2; exit 1; }
[ ! -L "$TRUST" ] || { printf 'refused: proof trust is a symlink: %s\n' "$TRUST" >&2; exit 1; }

# Trust record shape: exactly 3 lines (version, spec_hash, workspace).
trust_version=$(sed -n '1p' "$TRUST")
trust_hash=$(sed -n '2p' "$TRUST")
trust_ws=$(sed -n '3p' "$TRUST")
[ "$trust_version" = "fm-proof-trust v2" ] \
  && [ -n "$trust_hash" ] \
  && [ -n "$trust_ws" ] \
  || { printf 'refused: trust record incomplete for %s\n' "$TASK_ID" >&2; exit 1; }

# Workspace identity: the recorded worktree must still be the same directory.
cur_ws=$(sed -n 's/^workspace=//p' "$STATE/$TASK_ID.meta" 2>/dev/null)
[ -n "$cur_ws" ] || { printf 'unknown: task record lost workspace=\n' >&2; exit 1; }
cur_ws=$(realpath -m -- "$cur_ws" 2>/dev/null)
if [ "$cur_ws" != "$trust_ws" ]; then
  printf 'refused: record workspace drift (task record moved from %s to %s)\n' \
    "$trust_ws" "$cur_ws" >&2
  exit 1
fi

# The spec bytes must exactly match the registered hash: drift means the runner
# must not read the changed bytes.
curr_hash=$(sha256sum -- "$SPEC" 2>/dev/null | awk '{print $1}')
[ "$curr_hash" = "$trust_hash" ] || {
  printf 'refused: proof spec drifted after registration\n' >&2
  exit 1
}

pass=0; fail=0; unknown=0; total=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  IFS=$'\t' read -r proof_id type subject expected <<< "$line"
  [ -n "$proof_id" ] && [ -n "$type" ] && [ -n "$subject" ] || {
    printf 'unknown\tmalformed row: %s\n' "$line"
    unknown=$((unknown + 1))
    continue
  }
  total=$((total + 1))
  # evaluator via canonical workspace path
  out=$(fm_proof_canon "$subject" "$trust_ws") || {
    printf 'unknown\tsubject escape\n'
    unknown=$((unknown + 1))
    fm_proof_write_row "$STATE" "$TASK_ID" UNKNOWN "$proof_id" "$type" "$subject"
    continue
  }
  case "$type" in
    file_exists)
      verdict=$(fm_proof_eval_file_exists "$out"); rc=$? ;;
    file_absent)
      verdict=$(fm_proof_eval_file_absent "$out"); rc=$? ;;
    exact_text)
      verdict=$(fm_proof_eval_exact_text "$out" "$expected"); rc=$? ;;
    regex_match)
      verdict=$(fm_proof_eval_regex_match "$out" "$expected"); rc=$? ;;
    test_command|command_exit)
      printf 'unknown\t%s is not supported in V1 proof execution\n' "$type"
      unknown=$((unknown + 1))
      rc=2
      ;;
    *)
      verdict="<?rx?>"  # unknown
      rc=2
      ;;
  esac
  # record evidence into the task's proof log via the lib writer
  row_ts=$(date -u +%FT%TZ)
  outcome=UNKNOWN
  case "$rc" in 0) outcome=PASS ;; 1) outcome=FAIL ;; 2) outcome=UNKNOWN ;; esac
  fm_proof_write_row "$STATE" "$TASK_ID" "$outcome" "$proof_id" "$type" "$subject"
  case "$outcome" in
    PASS) pass=$((pass + 1)) ;;
    FAIL) fail=$((fail + 1)) ;;
    UNKNOWN) unknown=$((unknown + 1)) ;;
  esac
done < "$SPEC"

printf 'TOTAL=%d PASS=%d FAIL=%d UNKNOWN=%d\n' "$total" "$pass" "$fail" "$unknown"
VERDICT=REFUSED
if [ "$pass" -eq "$total" ] && [ "$total" -gt 0 ]; then
  VERDICT=PASS
elif [ "$fail" -gt 0 ]; then
  VERDICT=FAIL
fi
printf 'VERDICT=%s\n' "$VERDICT"
[ "$VERDICT" = "PASS" ]
