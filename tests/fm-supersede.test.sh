#!/usr/bin/env bash
# Behavior tests for the evidence-preserving SUPERSEDED task lifecycle
# (bin/fm-supersede.sh, recognized by bin/fm-classify-lib.sh).
#
# A superseded task is terminally closed with all evidence kept: its backlog
# row moves to Done with links preserved, state/<id>.superseded is written,
# and meta/status/inbox/worktree/branch are never touched. These cases drive
# the real scripts against a real backlog file and the real tasks-axi CLI and
# assert record state and behavior, never source text:
#   apply      fm-supersede.sh closes the row (explicit --pr link, then the
#              automatic SUPERSEDED note), writes the marker, and leaves
#              meta/status/inbox byte-identical; crew-state reports the
#              done-like terminal; rerun is idempotent.
#   teardown   fm-teardown.sh refuses a superseded task (exit, stderr, and a
#              byte-identical evidence tree, no pending-close record), while
#              the same task without the marker sails past the guard.
#   watch      a real fm-watch.sh poll emits no stale wake for a superseded
#              task and clears its pause bookkeeping, while an identical
#              paused task without the marker still takes the bounded
#              re-surface path (the control that keeps this from passing
#              vacuously).
#   predicate  fm_task_is_superseded accepts a regular marker file and
#              rejects a missing marker, a symlink, and an unsafe id.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

SUPERSEDE="$ROOT/bin/fm-supersede.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-supersede-tests)
fm_git_identity fmtest fmtest@example.invalid

HAVE_TASKS_AXI=1
command -v tasks-axi >/dev/null 2>&1 || HAVE_TASKS_AXI=0

# --- small local helpers (mirrors of the proven watch-triage rig) -------------

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

seen_sig() {
  local reported size ident
  reported=$(status_observed_signature "$1")
  size=$(size_of "$1")
  ident=$(_fm_open_decisions_file_ident "$1")
  printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

set_mtime() {
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

# A hermetic home: state + config + data with a real (empty-sectioned) backlog.
make_home() {
  local name=$1 case_dir home
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

add_item() {
  tasks-axi add "$2" "item for $2" --kind "${3:-ship}" --file "$1/data/backlog.md" >/dev/null
}

start_item() {
  tasks-axi start "$2" --file "$1/data/backlog.md" >/dev/null
}

row_state() {
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Standard evidence tree for one task: meta + paused status + inbox + worktree.
make_evidence() {
  local home=$1 id=$2 state
  state="$home/state"
  fm_write_meta "$state/$id.meta" "window=test:fm-$id" "kind=ship" "mode=direct-PR" "yolo=off"
  printf 'working: implementation underway\npaused: awaiting external dependency (vendor window)\n' > "$state/$id.status"
  mkdir -p "$state/$id.inbox/handled"
  printf 'steer text\n' > "$state/$id.inbox/001.msg"
  mkdir -p "$home/wt-$id"
  printf 'precious work\n' > "$home/wt-$id/file.txt"
}

snapshot_evidence() {
  local home=$1 id=$2 dest=$3
  mkdir -p "$dest"
  cp "$home/state/$id.meta" "$dest/$id.meta"
  cp "$home/state/$id.status" "$dest/$id.status"
  cp -r "$home/state/$id.inbox" "$dest/inbox"
  cp -r "$home/wt-$id" "$dest/wt"
}

assert_evidence_intact() {
  local home=$1 id=$2 dest=$3
  cmp -s "$dest/$id.meta" "$home/state/$id.meta" || fail "meta changed for $id"
  cmp -s "$dest/$id.status" "$home/state/$id.status" || fail "status changed for $id"
  diff -r "$dest/inbox" "$home/state/$id.inbox" >/dev/null || fail "inbox changed for $id"
  diff -r "$dest/wt" "$home/wt-$id" >/dev/null || fail "worktree changed for $id"
}

# --- predicate units ----------------------------------------------------------

test_predicate_units() {
  local d="$TMP_ROOT/pred"
  mkdir -p "$d"
  printf 'reason=x\n' > "$d/t1.superseded"
  fm_task_is_superseded "$d" t1 || fail "regular marker not recognized"
  fm_task_is_superseded "$d" missing && fail "missing marker recognized"
  ln -s t1.superseded "$d/t2.superseded"
  fm_task_is_superseded "$d" t2 && fail "symlink marker recognized"
  fm_task_is_superseded "$d" '../evil' && fail "unsafe id recognized"
  fm_task_is_superseded "$d" '' && fail "empty id recognized"
  [ "$(fm_superseded_marker_path "$d" t1)" = "$d/t1.superseded" ] \
    || fail "marker path helper moved"
  pass "predicate accepts a regular marker and rejects missing/symlink/unsafe ids"
}

# --- apply path ----------------------------------------------------------------

test_apply_with_pr_link() {
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped (tasks-axi is not installed)"; return 0; }
  local home state id reason out crew
  home=$(make_home apply-pr); state="$home/state"; id=old-001
  reason="product landed via other task"
  mkdir -p "$home/data/$id"
  printf 'report\n' > "$home/data/$id/report.md"
  add_item "$home" "$id"
  start_item "$home" "$id"
  make_evidence "$home" "$id"
  snapshot_evidence "$home" "$id" "$TMP_ROOT/apply-pr-snap"
  out=$(FM_HOME="$home" "$SUPERSEDE" "$id" --reason "$reason" \
    --pr https://example.test/org/repo/pull/9 2>&1) || fail "supersede failed: $out"
  [ "$(row_state "$home" "$id")" = "done" ] || fail "backlog row is not Done after supersede"
  tasks-axi show "$id" --file "$home/data/backlog.md" 2>/dev/null | grep -F \
    https://example.test/org/repo/pull/9 >/dev/null \
    || fail "explicit PR link not kept on the row"
  grep -qx "reason=$reason" "$state/$id.superseded" \
    || fail "marker does not carry the reason"
  assert_evidence_intact "$home" "$id" "$TMP_ROOT/apply-pr-snap"
  crew=$(FM_STATE_OVERRIDE="$state" "$CREW_STATE" "$id") \
    || fail "crew-state failed on a superseded task"
  [ "$crew" = "state: done · source: superseded · $reason" ] \
    || fail "crew-state did not report the done-like terminal (got: $crew)"
  pass "apply closes the row with links kept, preserves evidence, reports done-like terminal"
}

test_apply_auto_note() {
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped (tasks-axi is not installed)"; return 0; }
  local home id out
  home=$(make_home apply-note); id=old-002
  add_item "$home" "$id"
  start_item "$home" "$id"
  make_evidence "$home" "$id"
  out=$(FM_HOME="$home" "$SUPERSEDE" "$id" --reason "duplicated effort" 2>&1) \
    || fail "supersede without link flag failed: $out"
  [ "$(row_state "$home" "$id")" = "done" ] || fail "backlog row is not Done after supersede"
  tasks-axi show "$id" --file "$home/data/backlog.md" 2>/dev/null | grep -F \
    "SUPERSEDED" >/dev/null \
    || fail "automatic SUPERSEDED note missing on the row"
  [ -f "$home/state/$id.superseded" ] || fail "marker missing"
  pass "apply without a link flag closes the row with an automatic SUPERSEDED note"
}

test_apply_idempotent() {
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped (tasks-axi is not installed)"; return 0; }
  local home id before out
  home=$(make_home apply-idem); id=old-003
  add_item "$home" "$id"
  start_item "$home" "$id"
  make_evidence "$home" "$id"
  FM_HOME="$home" "$SUPERSEDE" "$id" --reason "first close" >/dev/null \
    || fail "initial supersede failed"
  before=$(cat "$home/state/$id.superseded")
  out=$(FM_HOME="$home" "$SUPERSEDE" "$id" --reason "first close" 2>&1) \
    || fail "rerun on a superseded task failed: $out"
  [ "$(cat "$home/state/$id.superseded")" = "$before" ] \
    || fail "rerun rewrote the marker"
  [ "$(row_state "$home" "$id")" = "done" ] || fail "row left Done state after rerun"
  pass "rerun on a superseded task succeeds without changing the marker or row"
}

test_apply_refusals() {
  [ "$HAVE_TASKS_AXI" -eq 1 ] || { pass "skipped (tasks-axi is not installed)"; return 0; }
  local home
  home=$(make_home apply-refuse)
  FM_HOME="$home" "$SUPERSEDE" "no-such-task" --reason "x" 2> "$TMP_ROOT/refuse.err" \
    && fail "supersede of a missing task succeeded"
  grep -Fi "refused" "$TMP_ROOT/refuse.err" >/dev/null \
    || fail "missing-task refusal is not loud"
  fm_write_meta "$home/state/mate.meta" "kind=secondmate"
  FM_HOME="$home" "$SUPERSEDE" mate --reason "x" 2> "$TMP_ROOT/refuse2.err" \
    && fail "supersede of a secondmate succeeded"
  [ ! -e "$home/state/mate.superseded" ] || fail "marker written for a secondmate"
  add_item "$home" badreason
  start_item "$home" badreason
  fm_write_meta "$home/state/badreason.meta" "kind=ship"
  FM_HOME="$home" "$SUPERSEDE" badreason --reason "$(printf 'one\ntwo')" 2> "$TMP_ROOT/refuse3.err" \
    && fail "multiline reason accepted"
  [ ! -e "$home/state/badreason.superseded" ] || fail "marker written for a bad reason"
  [ "$(row_state "$home" badreason)" != "done" ] || fail "row closed despite refusal"
  pass "missing task, secondmate kind, and multiline reason are all refused before mutation"
}

# --- teardown guard -------------------------------------------------------------

test_teardown_refuses_superseded() {
  local home state id rc
  home=$(make_home teardown-refuse); state="$home/state"; id=old-010
  if [ "$HAVE_TASKS_AXI" -eq 1 ]; then
    add_item "$home" "$id"
    start_item "$home" "$id"
  fi
  make_evidence "$home" "$id"
  printf 'reason=product landed elsewhere\nat=1788992000\ntool=fm-supersede\n' > "$state/$id.superseded"
  snapshot_evidence "$home" "$id" "$TMP_ROOT/teardown-snap"
  FM_HOME="$home" "$TEARDOWN" "$id" 2> "$TMP_ROOT/teardown.err"; rc=$?
  [ "$rc" -ne 0 ] || fail "teardown of a superseded task succeeded"
  grep -Fi "superseded" "$TMP_ROOT/teardown.err" >/dev/null \
    || fail "teardown refusal does not name the superseded state"
  assert_evidence_intact "$home" "$id" "$TMP_ROOT/teardown-snap"
  [ -f "$state/$id.superseded" ] || fail "marker removed by refused teardown"
  [ ! -e "$state/$id.backlog-close" ] || fail "pending-close record staged by refused teardown"
  if [ "$HAVE_TASKS_AXI" -eq 1 ]; then
    [ "$(row_state "$home" "$id")" = "in_flight" ] \
      || fail "backlog row moved by refused teardown"
  fi
  pass "teardown refuses a superseded task and preserves meta/status/inbox/marker"
}

test_teardown_control_passes_guard() {
  local home id rc
  home=$(make_home teardown-control); id=ctrl-011
  make_evidence "$home" "$id"
  FM_HOME="$home" "$TEARDOWN" "$id" 2> "$TMP_ROOT/control.err"; rc=$?
  [ "$rc" -ne 0 ] || fail "control teardown unexpectedly succeeded"
  grep -Fi "superseded" "$TMP_ROOT/control.err" >/dev/null \
    && fail "guard fired for a task with no marker"
  pass "without the marker the same teardown sails past the supersede guard"
}

# --- watcher exemption -----------------------------------------------------------

test_watch_silence() {
  local dir state fakebin out drain_out pane old_key pause_key old_hash pid
  dir=$(make_case watch-superseded); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; pane="$dir/pane.txt"
  printf 'idle crew, same screen' > "$pane"
  old_hash=$(hash_text "idle crew, same screen")
  fm_write_meta "$state/oldtask.meta" "window=test:fm-oldtask" "kind=ship"
  printf 'working: implementation underway\npaused: awaiting external dependency (vendor window)\n' \
    > "$state/oldtask.status"
  printf '%s' "$(seen_sig "$state/oldtask.status")" > "$state/.seen-oldtask_status"
  printf 'reason=product landed elsewhere\nat=1788992000\ntool=fm-supersede\n' \
    > "$state/oldtask.superseded"
  fm_write_meta "$state/pausetask.meta" "window=test:fm-pausetask" "kind=ship"
  printf 'working: implementation underway\npaused: awaiting external dependency (vendor window)\n' \
    > "$state/pausetask.status"
  printf '%s' "$(seen_sig "$state/pausetask.status")" > "$state/.seen-pausetask_status"
  old_key="test_fm-oldtask"
  pause_key="test_fm-pausetask"
  for k in "$old_key" "$pause_key"; do
    printf '%s' "$old_hash" > "$state/.hash-$k"
    printf '1\n' > "$state/.count-$k"
  done
  : > "$state/.paused-$old_key"
  printf 'stale-hash' > "$state/.stale-$old_key"
  printf 'old' > "$state/.paused-resurfaced-$old_key"
  # Backdate the control's status log past the bounded re-surface cadence so
  # the pre-existing behavior provably FIRES for it (wake + exit + marker),
  # keeping this test from passing vacuously. Signatures ignore mtime, so the
  # primed .seen marker still holds and no signal wake interferes.
  set_mtime $(( $(date +%s) - 7200 )) "$state/pausetask.status"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$pane" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting external' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2> "$dir/watch.err" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher did not exit for the control's re-surfaced pause: $(cat "$out" "$dir/watch.err")"; }
  grep -F "stale: test:fm-pausetask" "$out" >/dev/null \
    || { fail "control paused task did not re-surface (vacuous test): $(cat "$out")"; }
  grep -F "stale: test:fm-oldtask" "$out" >/dev/null \
    && fail "watcher printed a stale wake for the superseded task"
  [ ! -e "$state/.paused-$old_key" ] || fail "superseded pause flag not cleared"
  [ ! -e "$state/.stale-$old_key" ] || fail "superseded stale suppressor not cleared"
  [ ! -e "$state/.paused-resurfaced-$old_key" ] || fail "superseded task resurfaced"
  [ -e "$state/.paused-resurfaced-$pause_key" ] \
    || fail "control re-surface marker missing"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "test:fm-pausetask" >/dev/null \
    || fail "control re-surface was not queued"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "test:fm-oldtask" >/dev/null \
    && fail "a stale wake was queued for the superseded task"
  pass "superseded task emits no stale wake and never resurfaces; unmarked paused control still does"
}

test_predicate_units
test_apply_with_pr_link
test_apply_auto_note
test_apply_idempotent
test_apply_refusals
test_teardown_refuses_superseded
test_teardown_control_passes_guard
test_watch_silence
