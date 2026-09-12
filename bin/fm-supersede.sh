#!/usr/bin/env bash
# Close a task as SUPERSEDED while preserving all of its evidence: the
# sanctioned non-destructive terminal lifecycle for work that must stop
# without being torn down (a finished task whose product already landed
# elsewhere, a duplicated effort, a superseded plan).
#
# What it does, in order:
#   1. Moves this home's backlog row for <id> to Done (keeping the row and its
#      links) via bin/fm-backlog-transition-lib.sh, so the row can never
#      dispatch again. With no explicit link flag the close carries
#      --note "SUPERSEDED: <reason>"; an explicit --pr/--report/--note is
#      passed through instead. A manual-backend home or a home that keeps no
#      backlog skips this step with a printed note, exactly like teardown.
#   2. Writes state/<id>.superseded (reason/at/tool lines, published
#      atomically), the ONE marker the fleet reads as terminal.
# It never touches state/<id>.meta, the status log, the steering inbox, the
# worktree, or any branch - and it appends no status line, so closing emits no
# new signal wake and the preserved log stays byte-stable.
#
# What the marker means to the fleet (recognition owned by
# bin/fm-classify-lib.sh's fm_task_is_superseded; this script owns the
# transition mechanics that create it):
#   - bin/fm-crew-state.sh reports a done-like terminal without consulting the
#     run-step, pane, or log, so supervisors read the closure and not a stale
#     pre-closure event.
#   - bin/fm-watch.sh emits no further stale wakes for the task and never
#     resurfaces it through the declared-pause cadence.
#   - bin/fm-teardown.sh refuses worktree/meta/inbox/branch removal while the
#     marker exists. There is no --force escape: un-supersede by hand (remove
#     the marker, reopen the row) only on an explicit captain decision.
# Serialized against teardown through the task's control lock; refuses while
# another lifecycle action holds it. Refuses kind=secondmate (mates are never
# backlog items) and refuses before mutation when the backlog gate reports an
# unresolvable data directory or an incompatible tasks-axi. Re-running on an
# already-superseded task finishes a pending backlog move when one is still
# owed, else reports already-superseded and exits 0.
# Usage: fm-supersede.sh <task-id> --reason "<text>" [--pr <url>|--report <path>|--note "<text>"]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  echo "usage: fm-supersede.sh <task-id> --reason \"<text>\" [--pr <url>|--report <path>|--note \"<text>\"]" >&2
}

REASON=
REASON_SET=0
DONE_ARGS=()
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; usage; exit 2 ;;
    esac
    case "$want_value" in
      reason) REASON=$a; REASON_SET=1 ;;
      pr|report|note) DONE_ARGS+=("--$want_value" "$a") ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --help|-h) echo "usage: fm-supersede.sh <task-id> --reason \"<text>\" [--pr <url>|--report <path>|--note \"<text>\"]"; exit 0 ;;
    --reason) want_value=reason ;;
    --reason=*) REASON=${a#--reason=}; REASON_SET=1 ;;
    --pr|--report|--note) want_value=${a#--} ;;
    --pr=*|--report=*|--note=*) DONE_ARGS+=("${a%%=*}" "${a#*=}") ;;
    --*) echo "error: unknown option: $a" >&2; usage; exit 2 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; usage; exit 2; }
[ "${#POS[@]}" -eq 1 ] || { usage; exit 2; }
[ "$REASON_SET" -eq 1 ] || { echo "error: supersede requires --reason \"<text>\"" >&2; usage; exit 2; }
case "$REASON" in
  ''|*$'\n'*) echo "error: --reason must be a single non-empty line" >&2; exit 2 ;;
esac
if ! REASON_BYTES=$(fm_backlog_bytes_of_string "$REASON") \
  || ! fm_backlog_control_bytes_valid 0 "$REASON_BYTES"; then
  echo "error: --reason contains an invalid control byte" >&2
  exit 2
fi

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
fm_refuse_if_gate_agent

CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
supersede_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap supersede_cleanup EXIT
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: supersede refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
META="$STATE/$ID.meta"
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
if ! fm_backlog_record_present "$META" "task record" "$STATE"; then
  echo "error: supersede refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
KIND=$(grep '^kind=' "$META" 2>/dev/null | cut -d= -f2- || true)
[ -n "$KIND" ] || KIND=ship
if [ "$KIND" = secondmate ]; then
  echo "error: supersede refused: secondmates are persistent agents, never backlog items" >&2
  exit 1
fi

MARKER=$(fm_superseded_marker_path "$STATE" "$ID")
BACKLOG_NOTE=
if [ "${#DONE_ARGS[@]}" -eq 0 ]; then
  BACKLOG_NOTE="SUPERSEDED: $REASON"
fi
if fm_backlog_transition_applies "$CONFIG" "$DATA" "$KIND"; then
  BACKLOG_APPLIES=1
else
  BACKLOG_GATE_STATUS=$?
  if [ "$BACKLOG_GATE_STATUS" -eq 2 ]; then
    echo "error: task $ID cannot be superseded because its backlog data directory is inaccessible: $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  fi
  BACKLOG_APPLIES=0
  BACKLOG_SKIP_REASON=$FM_BACKLOG_TRANSITION_SKIP
fi
if [ "$BACKLOG_APPLIES" = 1 ]; then
  if [ -n "$BACKLOG_NOTE" ]; then
    fm_backlog_done "$DATA" "$ID" --note "$BACKLOG_NOTE" || {
      echo "error: task $ID's backlog row could not be closed ($FM_BACKLOG_TRANSITION_ERROR); nothing was changed" >&2
      exit 1
    }
  else
    fm_backlog_done "$DATA" "$ID" "${DONE_ARGS[@]}" || {
      echo "error: task $ID's backlog row could not be closed ($FM_BACKLOG_TRANSITION_ERROR); nothing was changed" >&2
      exit 1
    }
  fi
fi

if fm_task_is_superseded "$STATE" "$ID"; then
  MARKER_ALREADY=1
else
  MARKER_ALREADY=0
  TMP="$STATE/.$ID.superseded.${BASHPID:-$$}"
  {
    printf 'reason=%s\n' "$REASON"
    printf 'at=%s\n' "$(date +%s)"
    printf 'tool=fm-supersede\n'
  } > "$TMP" || { echo "error: superseded marker could not be staged" >&2; exit 1; }
  fm_backlog_atomic_transition publish "$TMP" "$MARKER" "superseded marker" "$STATE" || {
    echo "error: superseded marker could not be published ($FM_BACKLOG_TRANSITION_ERROR)" >&2
    exit 1
  }
  TMP=
fi

if [ "$BACKLOG_APPLIES" = 1 ]; then
  printf 'superseded %s (backlog row closed%s; evidence preserved at %s)\n' \
    "$ID" "${MARKER_ALREADY:+; marker already present}" "$MARKER"
else
  printf 'superseded %s (backlog skipped: %s; evidence preserved at %s)\n' \
    "$ID" "$BACKLOG_SKIP_REASON" "$MARKER"
fi
