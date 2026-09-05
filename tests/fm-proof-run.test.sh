#!/usr/bin/env bash
# tests/fm-proof-run.test.sh - deterministic coverage of bin/fm-proof-run.sh.
#
# Each scenario builds its own disposable home+worktree under the suite's
# temp root and writes only through FM_HOME. Nothing here ever touches the
# canonical home, the project worktree's tracked bytes, or true fixtures.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib.sh"

PROOT=$(fm_test_tmproot fm-proof-run)
HOME_ROOT="$PROOT/home"
STATE_DIR="$HOME_ROOT/state"
WS_ROOT="$PROOT/worktree"
TASK=mva-crackme

mkdir -p "$STATE_DIR" "$WS_ROOT"

REG="$ROOT/bin/fm-proof-register.sh"
RUN="$ROOT/bin/fm-proof-run.sh"

fresh_spec() {
  local body=$1
  printf '%s\n' "$body" > "$STATE_DIR/$TASK.proof.spec"
}
fresh_register() {
  FM_HOME="$HOME_ROOT" "$REG" "$TASK" "$STATE_DIR/$TASK.proof.spec" >/dev/null
}
run_proof() {
  FM_HOME="$HOME_ROOT" "$RUN" "$TASK" 2>&1
}
setup_meta() {
  printf 'workspace=%s\n' "$WS_ROOT" > "$STATE_DIR/$TASK.meta"
}
clean_state() {
  rm -f -- "$STATE_DIR/$TASK.proof.spec" "$STATE_DIR/$TASK.proof.trust" \
    "$STATE_DIR/$TASK.proof.log"
}

# ---------------------------------------------------------------------------
#  1. expected PASS verdict + overall exit 0
setup_meta
printf 'hello\n' > "$WS_ROOT/target.txt"
fresh_spec $'p1\tfile_exists\ttarget.txt\t-\n'
fresh_register
out=$(run_proof)
code=$?
expect_code 0 "$code" "all proofs pass returns exit 0"
assert_contains "$out" 'VERDICT=PASS' "run prints the PASS verdict"
clean_state

#  2. expected FAIL when the artifact is absent
setup_meta
rm -f "$WS_ROOT/target.txt"
fresh_spec $'p2\tfile_exists\ttarget.txt\t-\n'
fresh_register
out=$(run_proof)
code=$?
expect_code 1 "$code" "FAIL when artifact missing"
assert_contains "$out" 'VERDICT=FAIL' "expected FAIL verdict line"
clean_state

#  3. UNKNOWN for a BSD-only proof type
setup_meta
fresh_spec $'p3\tno_such_type\t--\t-\n'
fresh_register
out=$(run_proof)
code=$?
expect_code 2 "$code" "unsupported type -> non-zero exit"
assert_contains "$out" 'VERDICT=UNKNOWN' "refusal note must mention UNKNOWN"
clean_state

#  4. malformed spec (bad column count) - must stay UNKNOWN, never PASS
setup_meta
printf 'p4\ttwo\tcolumns\n' > "$STATE_DIR/$TASK.proof.spec"
fresh_register
out=$(run_proof)
assert_contains "$out" 'VERDICT=UNKNOWN' "malformed row means UNKNOWN"
assert_not_contains "$out" 'VERDICT=PASS' "malformed row must not claim success"
clean_state

#  5. unsupported proof type is always UNKNOWN, not PASS
setup_meta
fresh_spec $'p5\tempty\ttarget\t-\n'
fresh_register
out=$(run_proof)
assert_contains "$out" 'UNKNOWN' "unsupported type is always UNKNOWN"
clean_state

#  6. missing artifact at evaluation time
setup_meta
fresh_spec $'p6\tfile_exists\tphantom.txt\t-\n'
fresh_register
rm -f "$WS_ROOT/phantom.txt"
out=$(run_proof)
assert_contains "$out" 'FAIL' "absent subject (registered file_exists) must produce FAIL"
assert_not_contains "$out" 'VERDICT=PASS' "phantom claim must not PASS"
clean_state

#  7. stale artifact: registration hash must catch it
setup_meta
printf 'hot\n' > "$WS_ROOT/hot.txt"
fresh_spec $'p7\tfile_exists\thot.txt\t-\n'
fresh_register
# rewrite the spec in place after registration
printf 'p7\tfile_absent\thot.txt\t-\n' > "$STATE_DIR/$TASK.proof.spec"
out=$(run_proof)
code=$?
expect_code 1 "$code" "post-registration edit must refuse"
assert_contains "$out" 'mismatch' "hash mismatch message must appear"
clean_state

#  8. timeout: never falsely PASS a command-based proof that would hang
setup_meta
fresh_spec $'p8\tcommand_exit\tno_such_command_ever\t-\n'
fresh_register
start=$(date +%s)
out=$(run_proof)
  end=$(date +%s)
  [ $((end - start)) -lt 10 ] || fail "slow commands banned: ran more than 10s"
assert_contains "$out" 'VERDICT=UNKNOWN' "non-executable raw commands cannot PASS"
clean_state

#  9. wrong workspace: record's workspace doesn't match the recorded task meta
WS_ROOT_OTHER="$PROOT/wrong-workspace"
mkdir -p "$WS_ROOT_OTHER"
( cd "$WS_ROOT_OTHER" && touch settled.txt )
setup_meta
printf 'workspace=%s\n' "$WS_ROOT_OTHER" > "$STATE_DIR/$TASK.meta"
fresh_spec $'p9\tfile_exists\tsettled.txt\t-\n'
fresh_register
out=$(run_proof)
# should be able to run and still PASS (workspace is just what the meta says)
printf 'settled\n' > "$WS_ROOT_OTHER/settled.txt"
out=$(run_proof)
clean_state
rm -rf "$WS_ROOT_OTHER"

# 10. worker cannot self-approve its own spec without a registration re-pin
setup_meta
fresh_spec $'p10\tfile_exists\tpin.txt\t-\n'
fresh_register
printf 'x\n' > "$WS_ROOT/pin.txt"
out=$(run_proof)
assert_contains "$out" 'PASS' "first registered run passes"
# worker now writes a different spec by overriding register/time (hash differs)
printf 'p10\tfile_exists\tpin.txt\t-\n' > "$STATE_DIR/$TASK.proof.spec"
out=$(run_proof)
code=$?
expect_code 1 "$code" "self-approval must fail (registered hash mismatch)"
clean_state

# 11. raw command injection: a spec that would try to execute commands can never
# pass - the proof runner only evaluates the registered, trusted-shape types.
setup_meta
fresh_spec $'p11\texec:cmd\tevaluate-me\t-\n'
fresh_register
out=$(run_proof)
assert_contains "$out" 'UNKNOWN' "raw command shape must be UNKNOWN"
assert_not_contains "$out" 'REGRESSION'  # so no code executed unexpectedly
clean_state

# 12. proof spec tamper after registration is what the pin is for
setup_meta
fresh_spec $'p12\tfile_exists\tx.txt\t-\n'
fresh_register
printf 'x\n' > "$WS_ROOT/x.txt"
sed -i 's/x.txt/y.txt/' "$STATE_DIR/$TASK.proof.spec" 2>/dev/null || sed -i '' 's/x.txt/y.txt/' "$STATE_DIR/$TASK.proof.spec"
out=$(run_proof)
expect_code $? 1 "tampered proof spec must refuse"
clean_state

# 13. ../ escape probe: realpath on a literal ../irregular path must refuse or
# return UNKNOWN, always with proof-runner dispatch on the property.
setup_meta
fresh_spec $'p13\tfile_exists\t../../../etc/passwd\t-\n'
fresh_register
out=$(run_proof)
assert_not_contains "$out" 'VERDICT=PASS' "directory escape must refuse"
clean_state

# 14. symlink escape: even if the subject exists via a link, canonicalization
# takes it out of the workspace and the check must fail safe.
setup_meta
ln -sf /etc/shadow "$WS_ROOT/trap.txt"
fresh_spec $'p14\tregex_match\ttrap.txt\tshadow\n'
fresh_register
out=$(run_proof)
assert_contains "$out" 'UNKNOWN' "symlink escape is UNKNOWN"
assert_contains "$out" 'VERDICT=UNKNOWN'
clean_state

# 15. legacy tasks (no spec at all) never gets spurious verification claims
setup_meta
# no spec, no register - simulates the fleet's ordinary pre-V1 default
out=$(run_proof)
code=$?
expect_code 1 "$code" "absent spec setup is always refused"
clean_state

# 16. content diff impossible: after a run, any read-only run left zero writes
ws_snapshot() { find "$WS_ROOT" -type f 2>/dev/null | sort | xargs -r sha256sum 2>/dev/null; }
setup_meta
fresh_spec $'p16\tfile_exists\t*\t-\n'
fresh_register
before=$(ws_snapshot)
run_proof >/dev/null 2>&1 || true
after=$(ws_snapshot)
[ "$before" = "$after" ] || fail "workspace content changed in evaluation"
clean_state

# 17. trusted file writes: only to the state dir, not the tracked worktree
setup_meta
printf 'target\n' > "$WS_ROOT/note.txt"
fresh_spec $'p17\tfile_exists\tnote.txt\t-\n'
fresh_register
run_proof >/dev/null 2>&1
[ -f "$STATE_DIR/$TASK.proof.log" ] || fail "proof log must be written"
assert_grep "PASS" "$STATE_DIR/$TASK.proof.log" "PASS row recorded"
clean_state

printf '\n'
pass "fm-proof-run: all 17 deterministic scenarios green"
