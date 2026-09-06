#!/usr/bin/env bash
# bin/fm-proof-run.sh - bounded proof runner for a registered task proof spec.
#
# Reads a task's registered proof spec (state/<id>.proof.spec, pinned at
# registration into state/<id>.proof.trust v2), executes read-only evaluators
# over subjects that canonically resolve inside the registered workspace, and
# emits machine-verifiable verdicts:
#   PASS    every registered proof passed (exit 0)
#   FAIL    at least one proof contradicted reality (exit 1)
#   UNKNOWN any proof could not be safely established (exit 2)
#
# Verdict precedence: PASS requires ALL proofs passed; FAIL beats UNKNOWN.
# Deferred proof types (command_exit, registered_check, unknown types) are
# never executed and never produce PASS.
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
fm_pr_task_id_valid "$TASK_ID" || { printf 'refused: invalid task id\n' >&2; exit 1; }

META="$STATE/$TASK_ID.meta"
SPEC="$STATE/$TASK_ID.proof.spec"
TRUST="$STATE/$TASK_ID.proof.trust"
LOG="$STATE/$TASK_ID.proof.log"

# ---- fail-closed file preconditions -----------------------------------------
[ -f "$META" ] && [ ! -L "$META" ] || { printf 'unknown: task metadata absent or unsafe: %s\n' "$META" >&2; exit 1; }
[ -f "$SPEC" ] && [ ! -L "$SPEC" ] || { printf 'unknown: proof spec absent or unsafe: %s\n' "$SPEC" >&2; exit 1; }
[ -f "$TRUST" ] && [ ! -L "$TRUST" ] || { printf 'refused: proof trust record absent or unsafe: %s\n' "$TRUST" >&2; exit 1; }
if [ -L "$LOG" ]; then
  printf 'refused: proof log may not be a symlink: %s\n' "$LOG" >&2
  exit 1
fi
if [ -e "$LOG" ] && [ ! -f "$LOG" ]; then
  printf 'refused: proof log destination is not a regular file: %s\n' "$LOG" >&2
  exit 1
fi

# ---- trust latch -------------------------------------------------------------
TRUST_VERSION=$(sed -n '1p' "$TRUST")
TRUST_SPEC_HASH=$(sed -n '2p' "$TRUST")
TRUST_WORKSPACE=$(sed -n '3p' "$TRUST")
[ "$TRUST_VERSION" = "fm-proof-trust v2" ] || { printf 'refused: unknown trust version: %s\n' "$TRUST_VERSION" >&2; exit 1; }
[ -n "$TRUST_SPEC_HASH" ] && [ -n "$TRUST_WORKSPACE" ] || { printf 'refused: incomplete trust record\n' >&2; exit 1; }

# The workspace captured at registration must still be the task's workspace;
# both sides are canonicalized before comparison so no aliased path can pass.
CURRENT_WORKSPACE=$(sed -n 's/^workspace=//p' "$META" | head -1)
[ -n "$CURRENT_WORKSPACE" ] || { printf 'unknown: missing workspace field in meta\n' >&2; exit 1; }
CURRENT_CANON=$(realpath -m -- "$CURRENT_WORKSPACE" 2>/dev/null)
[ -n "$CURRENT_CANON" ] || { printf 'unknown: workspace uncanonicalizable: %s\n' "$CURRENT_WORKSPACE" >&2; exit 1; }
TRUST_CANON=$(realpath -m -- "$TRUST_WORKSPACE" 2>/dev/null)
[ -n "$TRUST_CANON" ] || { printf 'unknown: registered workspace uncanonicalizable\n' >&2; exit 1; }
[ "$CURRENT_CANON" = "$TRUST_CANON" ] || {
  printf 'refused: workspace moved since registration (was %s, now %s)\n' "$TRUST_CANON" "$CURRENT_CANON" >&2
  exit 1
}
[ -d "$TRUST_CANON" ] || { printf 'unknown: registered workspace is gone: %s\n' "$TRUST_CANON" >&2; exit 1; }

# Proof bytes must be exactly what registration pinned.
SPEC_HASH=$(sha256sum -- "$SPEC" 2>/dev/null | awk '{print $1}')
[ -n "$SPEC_HASH" ] && [ "$SPEC_HASH" = "$TRUST_SPEC_HASH" ] || {
  printf 'refused: proof spec drifted (hash mismatch)\n' >&2
  exit 1
}

# ---- evaluation loop ----------------------------------------------------------
pass=0 fail=0 unknown=0 total=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  total=$((total + 1))
  IFS=$'\t' read -r proof_id type subject expected <<< "$line"
  if [ -z "$proof_id" ] || [ -z "$type" ] || [ -z "$subject" ]; then
    printf 'UNKNOWN\tmalformed proof line\n'
    fm_proof_write_row "$STATE" "$TASK_ID" UNKNOWN "${proof_id:--}" "${type:--}" "malformed proof line"
    unknown=$((unknown + 1))
    continue
  fi
  if ! canon=$(fm_proof_canon "$subject" "$TRUST_CANON"); then
    printf 'UNKNOWN\tpath escape refused: %s\n' "$subject"
    fm_proof_write_row "$STATE" "$TASK_ID" UNKNOWN "$proof_id" "$type" "escape refused: $subject"
    unknown=$((unknown + 1))
    continue
  fi
  rc=2
  case "$type" in
    file_exists)  fm_proof_eval_file_exists "$canon" >/dev/null; rc=$? ;;
    file_absent)  fm_proof_eval_file_absent "$canon" >/dev/null; rc=$? ;;
    exact_text)   fm_proof_eval_exact_text "$canon" "$expected" >/dev/null; rc=$? ;;
    regex_match)  fm_proof_eval_regex_match "$canon" "$expected" >/dev/null; rc=$? ;;
    command_exit|registered_check)
      rc=2 ;;   # deferred proof classes: never executed, never PASS
    *)
      rc=2 ;;   # unknown types: UNKNOWN, never PASS
  esac
  case "$rc" in
    0) verdict=PASS;    pass=$((pass + 1)) ;;
    1) verdict=FAIL;    fail=$((fail + 1)) ;;
    *) verdict=UNKNOWN; unknown=$((unknown + 1)) ;;
  esac
  printf '%s\t%s\n' "$verdict" "$proof_id"
  fm_proof_write_row "$STATE" "$TASK_ID" "$verdict" "$proof_id" "$type" "$subject"
done < "$SPEC"

printf 'TOTAL=%d PASS=%d FAIL=%d UNKNOWN=%d\n' "$total" "$pass" "$fail" "$unknown"
if [ "$total" -gt 0 ] && [ "$pass" -eq "$total" ]; then
  printf 'VERDICT=PASS\n'
  exit 0
fi
if [ "$fail" -gt 0 ]; then
  printf 'VERDICT=FAIL\n'
  exit 1
fi
printf 'VERDICT=UNKNOWN\n'
exit 2
