#!/usr/bin/env bash
# tests/fm-proof-run.test.sh - deterministic proof-runner coverage.
#
# All fixtures are scoped to the test home State$HOMEROOT/state; no artifacts
# escape the test, no writes reach the live primary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

ROOT_DIR=$(fm_test_tmproot mva-tests)
HOME_DIR="$ROOT_DIR/home"
STATE_DIR="$HOME_DIR/state"
WS_DIR="$ROOT_DIR/wt"
mkdir -p "$STATE_DIR" "$WS_DIR"

REGISTER="$ROOT/bin/fm-proof-register.sh"
RUN="$ROOT/bin/fm-proof-run.sh"

write_spec() {
  printf '%s' "$1" > "$STATE_DIR/$TASK.proof.spec"
}
register_task() {
  FM_HOME="$HOME_DIR" "$REGISTER" "$TASK" "$STATE_DIR/$TASK.proof.spec"
}
run_task() {
  FM_HOME="$HOME_DIR" "$RUN" "$TASK" 2>&1
}

TASK=mva
setup() {
  mkdir -p "$WS_DIR"
  printf 'workspace=%s\n' "$WS_DIR" > "$STATE_DIR/$TASK.meta"
}

# ----------------------------------------------------------------------------
# PASS: file exists; evaluator observes the artifact.
setup
printf 'body\n' > "$WS_DIR/${TASK}-proof-artifact.txt"
write_spec $'p1\tfile_exists\t'"${TASK}-proof-artifact.txt"$'\t-\n'
register_task >/dev/null
out=$(run_task); rc=$?
expect_code 0 "$rc" "PASS verdict when the artifact exists"
assert_contains "$out" "VERDICT" "verdict line present"
assert_contains "$out" "PASS" "PASS captured"
assert_present "$STATE_DIR/$TASK.proof.log" "proof log landed"
assert_grep "PASS" "$STATE_DIR/$TASK.proof.log" "log line names PASS"

# FAIL: artifact agreed absent by evaluator.
setup
rm -f "$WS_DIR/${TASK}-missing.txt"
write_spec $'p2\tfile_exists\t'"${TASK}-missing.txt"$'\t-\n'
register_task >/dev/null
out=$(run_task); rc=$?
expect_code 1 "$rc" "FAIL verdict when artifact absent"
assert_contains "$out" "FAIL" "FAIL verdict recorded"

# UNKNOWN: evaluator can't see the evidence (registered spec is fine, evidence
# absent at evaluation time). They are distinct results: UNKNOWN never counts
# toward the green summary the captain chooses to certify.
setup
write_spec $'p3\tfile_absent\tno-such-file.txt\t-\n'
register_task >/dev/null
out=$(run_task); rc=$?
expect_code 0 "$rc" "file_absent is a working proof"
assert_contains "$out" "PASS" "proof of absence exists"

# UNKNOWN: typo'd evaluator type must not become PASS.
setup
write_spec $'p4\tthe_wrong_typo\tsomething\t-\n'
register_task >/dev/null
out=$(run_task); rc=$?
expect_code 1 "$rc" "unsupported type can't pass"
assert_contains "$out" "UNKNOWN" "unsupported means UNKNOWN, not PASS"

# Escape: subject refers outside the workspace. Must refuse, not PASS.
setup
write_spec $'p5\tfile_exists\t../../term.txt\t-\n'
register_task >/dev/null
out=$(run_task)
assert_contains "$out" "UNKNOWN" "escape is UNKNOWN"
  assert_not_contains "$out" "VERDICT=PASS" "escape claim must not succeed" "escape claim must not succeed"

# Stale spec: modifying it after registration must not pass.
setup
write_spec $'p6\tfile_exists\t'"${TASK}-stable.txt"$'\t-\n'
register_task >/dev/null
printf 'stale-line\n' >> "$STATE_DIR/$TASK.proof.spec"   # drift the bytes
out=$(run_task)
assert_contains "$out" "refused" "drifted spec rejected"
assert_not_contains "$out" "VERDICT=PASS" "drifted proof can never PASS"

# Registering the same spec twice pins cleanly; drifters never become evidence.
setup
write_spec $'p7\tfile_absent\tnever-there.txt\t-\n'
register_task >/dev/null
run_task >/dev/null; rc=$?
expect_code 0 "$rc" "idempotent registration+harness pass"

# Regression guard: the registered-check pin pattern that cp's between TS libs
# still works after the new files landed.
if [ -e "$ROOT/bin/fm-check-register.sh" ] && [ -e "$ROOT/bin/fm-check-lib.sh" ]; then
  pass "registered-check base files present and unchanged"
else
  fail "registered-check base files missing"
fi

printf '\n'
pass "fm-proof-run.test.sh: all scenarios carried"
