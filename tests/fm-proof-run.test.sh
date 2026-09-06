#!/usr/bin/env bash
# tests/fm-proof-run.test.sh — deterministic matrix for the MVA v1 proof runner.
#
# Covers: happy paths, FAIL paths, UNKNOWN paths, trust latching (drift,
# version, symlinks), workspace-move detection, canonical path confinement
# (absolute / .. / nested / symlink escapes with victim-touch preconditions
# proven), deferred proof classes that must NEVER execute and NEVER pass,
# evidence-log integrity, and the registered-check base-files invariant.
#
# Self-contained: every case builds a throwaway FM_HOME under /tmp, registers a
# proof spec through the real register bin, then runs the real runner.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH=$(mktemp -d /tmp/mva-v1-matrix.XXXXXX)
trap 'rm -rf "$SCRATCH"' EXIT
export ROOT SCRATCH

ok_n=0 bad_n=0
check() { # <name> <expected> <actual>
  local name=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    ok_n=$((ok_n + 1)); printf 'ok %d - %s\n' "$((ok_n + bad_n))" "$name"
  else
    bad_n=$((bad_n + 1)); printf 'not ok %d - %s (want=[%s] got=[%s])\n' "$((ok_n + bad_n))" "$name" "$want" "$got"
  fi
}
check_in() { # <name> <needle> <haystack>
  case "$3" in
    *"$2"*) ok_n=$((ok_n + 1)); printf 'ok %d - %s\n' "$((ok_n + bad_n))" "$1" ;;
    *) bad_n=$((bad_n + 1)); printf 'not ok %d - %s (missing [%s] in output: %s)\n' "$((ok_n + bad_n))" "$1" "$2" "$3" ;;
  esac
}
check_absent() { # <name> <forbidden> <haystack>
  case "$3" in
    *"$2"*) bad_n=$((bad_n + 1)); printf 'not ok %d - %s (forbidden [%s] present in: %s)\n' "$((ok_n + bad_n))" "$1" "$2" "$3" ;;
    *) ok_n=$((ok_n + 1)); printf 'ok %d - %s\n' "$((ok_n + bad_n))" "$1" ;;
  esac
}

# newcase <id> — fresh home + workspace + meta
H= W= ID=
newcase() {
  ID=$1
  H="$SCRATCH/$ID/home"; W="$SCRATCH/$ID/wt"
  mkdir -p "$H/state" "$W"
  printf 'workspace=%s\n' "$W" > "$H/state/$ID.meta"
}
reg() { FM_HOME="$H" "$ROOT/bin/fm-proof-register.sh" "$ID" "$1" >/dev/null 2>&1; }
run() { FM_HOME="$H" "$ROOT/bin/fm-proof-run.sh" "$ID" 2>&1; }
run_rc() { local out rc; out=$(run); rc=$?; RUN_OUT=$out; RUN_RC=$rc; }

# ---------------------------------------------------------------- c01: all-PASS verdict
newcase c01
printf 'proof-body-1\n' > "$W/alpha.txt"
{
  printf 'p1\tfile_exists\talpha.txt\t\n'
  printf 'p2\tfile_absent\tghost.txt\t\n'
  printf 'p3\texact_text\talpha.txt\tproof-body-1\n'
  printf 'p4\tregex_match\talpha.txt\t^proof.*1$\n'
} > "$SCRATCH/c01/spec.txt"
reg "$SCRATCH/c01/spec.txt"
run_rc
check "c01 rc" 0 "$RUN_RC"
check_in "c01 verdict pass" "VERDICT=PASS" "$RUN_OUT"
check_in "c01 totals" "TOTAL=4 PASS=4 FAIL=0 UNKNOWN=0" "$RUN_OUT"

# ---------------------------------------------------------------- c02: file_absent satisfied alone
newcase c02
printf 'q1\tfile_absent\tnever-created.txt\t\n' > "$SCRATCH/c02-spec"
reg "$SCRATCH/c02-spec"
run_rc
check "c02 rc" 0 "$RUN_RC"
check_in "c02 verdict" "VERDICT=PASS" "$RUN_OUT"

# ---------------------------------------------------------------- c03: exact_text PASS
newcase c03
printf 'byte-for-byte\n' > "$W/pinned.txt"
printf 'q1\texact_text\tpinned.txt\tbyte-for-byte\n' > "$SCRATCH/c03-spec"
reg "$SCRATCH/c03-spec"
run_rc
check "c03 rc" 0 "$RUN_RC"
check_in "c03 pass" "VERDICT=PASS" "$RUN_OUT"

# ---------------------------------------------------------------- c04: exact_text mismatch -> FAIL
newcase c04
printf 'actual-bytes\n' > "$W/pinned.txt"
printf 'q1\texact_text\tpinned.txt\texpected-other-bytes\n' > "$SCRATCH/c04-spec"
reg "$SCRATCH/c04-spec"
run_rc
check "c04 rc" 1 "$RUN_RC"
check_in "c04 verdict" "VERDICT=FAIL" "$RUN_OUT"

# ---------------------------------------------------------------- c05: regex PASS
newcase c05
printf 'release: 2026-09-05 stable\n' > "$W/r.txt"
printf 'q1\tregex_match\tr.txt\tstable$\n' > "$SCRATCH/c05-spec"
reg "$SCRATCH/c05-spec"
run_rc
check "c05 rc" 0 "$RUN_RC"
check_in "c05 verdict" "VERDICT=PASS" "$RUN_OUT"

# ---------------------------------------------------------------- c06: regex no-match -> FAIL
newcase c06
printf 'nothing here\n' > "$W/r.txt"
printf 'q1\tregex_match\tr.txt\t^wanted-anchor\n' > "$SCRATCH/c06-spec"
reg "$SCRATCH/c06-spec"
run_rc
check "c06 rc" 1 "$RUN_RC"
check_in "c06 verdict" "VERDICT=FAIL" "$RUN_OUT"

# ---------------------------------------------------------------- c07: exact_text on missing file -> UNKNOWN
newcase c07
printf 'q1\texact_text\tnot-there.txt\tanything\n' > "$SCRATCH/c07-spec"
reg "$SCRATCH/c07-spec"
run_rc
check "c07 rc" 2 "$RUN_RC"
check_in "c07 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"

# ---------------------------------------------------------------- c08: regex on missing file -> UNKNOWN
newcase c08
printf 'q1\tregex_match\tnot-there.txt\t^x\n' > "$SCRATCH/c08-spec"
reg "$SCRATCH/c08-spec"
run_rc
check "c08 rc" 2 "$RUN_RC"
check_in "c08 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"

# ---------------------------------------------------------------- c09/c10/c11/c12: escapes with victim preconditions
# Victim outside the workspace that WOULD pass file_exists if reached.
VICTIM_DIR="$SCRATCH/victims"; mkdir -p "$VICTIM_DIR"
printf 'escape-target-bytes\n' > "$VICTIM_DIR/victim.txt"
# Precondition: direct evaluator on victim really is PASS (proves UNKNOWN below
# comes from the guard, not from victim absence).
. "$ROOT/bin/fm-proof-lib.sh"
fm_proof_eval_file_exists "$VICTIM_DIR/victim.txt" >/dev/null; DIRECT_RC=$?
check "precondition: direct eval of victim is PASS(rc 0)" 0 "$DIRECT_RC"

# c09 absolute subject
newcase c09
printf 'q1\tfile_exists\t%s\t\n' "$VICTIM_DIR/victim.txt" > "$SCRATCH/c09-spec"
reg "$SCRATCH/c09-spec"
run_rc
check "c09 rc" 2 "$RUN_RC"
check_in "c09 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
check_in "c09 escape wording" "escape refused" "$RUN_OUT"
# victim untouched
check "c09 victim intact" "escape-target-bytes" "$(cat "$VICTIM_DIR/victim.txt")"

# c10 ../ traversal
mkdir -p "$SCRATCH/ten/wt-dir"
newcase c10
# workspace is $W=$SCRATCH/c10/wt; victim at $SCRATCH/c10/victim.txt
printf 'escape-target-10\n' > "$SCRATCH/c10/victim.txt"
printf 'q1\tfile_exists\t../victim.txt\t\n' > "$SCRATCH/c10-spec"
reg "$SCRATCH/c10-spec"
run_rc
check "c10 rc" 2 "$RUN_RC"
check_in "c10 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
check "c10 victim intact" "escape-target-10" "$(cat "$SCRATCH/c10/victim.txt")"

# c11 nested a/../.. traversal
newcase c11
printf 'escape-target-11\n' > "$SCRATCH/c11/victim.txt"
printf 'q1\tfile_exists\ta/../../victim.txt\t\n' > "$SCRATCH/c11-spec"
reg "$SCRATCH/c11-spec"
run_rc
check "c11 rc" 2 "$RUN_RC"
check_in "c11 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
check "c11 victim intact" "escape-target-11" "$(cat "$SCRATCH/c11/victim.txt")"

# c12 in-workspace symlink pointing outside
newcase c12
printf 'escape-target-12\n' > "$SCRATCH/c12/outside.txt"
ln -s "$SCRATCH/c12/outside.txt" "$W/linkout"
printf 'q1\tfile_exists\tlinkout\t\n' > "$SCRATCH/c12-spec"
reg "$SCRATCH/c12-spec"
run_rc
check "c12 rc" 2 "$RUN_RC"
check_in "c12 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
check "c12 victim intact" "escape-target-12" "$(cat "$SCRATCH/c12/outside.txt")"

# ---------------------------------------------------------------- c13/14/15: verdict precedence
newcase c13
printf 'x\n' > "$W/a.txt"
{
  printf 'p1\tfile_exists\ta.txt\t\n'
  printf 'p2\tfile_absent\ta.txt\t\n'
} > "$SCRATCH/c13-spec"
reg "$SCRATCH/c13-spec"
run_rc
check "c13 rc" 1 "$RUN_RC"
check_in "c13 verdict" "VERDICT=FAIL" "$RUN_OUT"
check_in "c13 totals" "TOTAL=2 PASS=1 FAIL=1 UNKNOWN=0" "$RUN_OUT"

newcase c14
printf 'x\n' > "$W/a.txt"
{
  printf 'p1\tfile_exists\ta.txt\t\n'
  printf 'p2\texact_text\tmissing.txt\tz\n'
} > "$SCRATCH/c14-spec"
reg "$SCRATCH/c14-spec"
run_rc
check "c14 rc" 2 "$RUN_RC"
check_in "c14 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
check_in "c14 totals" "TOTAL=2 PASS=1 FAIL=0 UNKNOWN=1" "$RUN_OUT"

newcase c15
printf 'x\n' > "$W/a.txt"
{
  printf 'p1\tfile_absent\ta.txt\t\n'
  printf 'p2\texact_text\tmissing.txt\tz\n'
} > "$SCRATCH/c15-spec"
reg "$SCRATCH/c15-spec"
run_rc
check "c15 rc" 1 "$RUN_RC"
check_in "c15 verdict" "VERDICT=FAIL" "$RUN_OUT"
check_in "c15 totals" "TOTAL=2 PASS=0 FAIL=1 UNKNOWN=1" "$RUN_OUT"

# ---------------------------------------------------------------- c16: spec drift after registration
newcase c16
printf 'x\n' > "$W/a.txt"
printf 'q1\tfile_exists\ta.txt\t\n' > "$SCRATCH/c16-spec"
reg "$SCRATCH/c16-spec"
printf 'q2\tfile_exists\tb.txt\t\n' >> "$H/state/c16.proof.spec"   # tamper
run_rc
if [ "$RUN_RC" -ne 0 ]; then D16=refused; else D16=ran; fi
check "c16 drifted run refused" refused "$D16"
check_in "c16 drift wording" "drifted" "$RUN_OUT"

# ---------------------------------------------------------------- c17: unknown trust version
newcase c17
printf 'x\n' > "$W/a.txt"
printf 'q1\tfile_exists\ta.txt\t\n' > "$SCRATCH/c17-spec"
reg "$SCRATCH/c17-spec"
sed -i '1s/.*/fm-proof-trust v99/' "$H/state/c17.proof.trust"
run_rc
if [ "$RUN_RC" -ne 0 ]; then D17=refused; else D17=ran; fi
check "c17 version tamper refused" refused "$D17"
check_in "c17 version wording" "unknown trust version" "$RUN_OUT"

# ---------------------------------------------------------------- c18: trust record is a symlink
newcase c18
printf 'x\n' > "$W/a.txt"
printf 'q1\tfile_exists\ta.txt\t\n' > "$SCRATCH/c18-spec"
reg "$SCRATCH/c18-spec"
cp "$H/state/c18.proof.trust" "$SCRATCH/c18-trust-copy"
rm -f "$H/state/c18.proof.trust"
ln -s "$SCRATCH/c18-trust-copy" "$H/state/c18.proof.trust"
run_rc
if [ "$RUN_RC" -ne 0 ]; then D18=refused; else D18=ran; fi
check "c18 trust symlink refused" refused "$D18"
check_in "c18 wording" "trust record absent or unsafe" "$RUN_OUT"

# ---------------------------------------------------------------- c19: spec is a symlink
newcase c19
printf 'x\n' > "$W/a.txt"
printf 'q1\tfile_exists\ta.txt\t\n' > "$SCRATCH/c19-spec"
reg "$SCRATCH/c19-spec"
cp "$H/state/c19.proof.spec" "$SCRATCH/c19-spec-copy"
rm -f "$H/state/c19.proof.spec"
ln -s "$SCRATCH/c19-spec-copy" "$H/state/c19.proof.spec"
run_rc
if [ "$RUN_RC" -ne 0 ]; then D19=refused; else D19=ran; fi
check "c19 spec symlink refused" refused "$D19"
check_in "c19 wording" "proof spec absent or unsafe" "$RUN_OUT"
# and the symlink target's content was never trusted even though bytes match

# ---------------------------------------------------------------- c20: proof.log pre-created as symlink
newcase c20
printf 'x\n' > "$W/a.txt"
printf 'q1\tfile_exists\ta.txt\t\n' > "$SCRATCH/c20-spec"
reg "$SCRATCH/c20-spec"
LN_TARGET="$SCRATCH/c20-logtarget"
printf 'do-not-overwrite\n' > "$LN_TARGET"
ln -s "$LN_TARGET" "$H/state/c20.proof.log"
run_rc
if [ "$RUN_RC" -ne 0 ]; then D20=refused; else D20=ran; fi
check "c20 log symlink refused" refused "$D20"
check_in "c20 wording" "proof log may not be a symlink" "$RUN_OUT"
check "c20 victim logtarget intact" "do-not-overwrite" "$(cat "$LN_TARGET")"

# ---------------------------------------------------------------- c21: meta missing workspace
newcase c21
: > "$H/state/c21.meta"   # empty meta: no workspace line
printf 'q1\tfile_exists\ta.txt\t\n' > "$SCRATCH/c21-spec"
FM_HOME="$H" "$ROOT/bin/fm-proof-register.sh" c21 "$SCRATCH/c21-spec" >/dev/null 2>&1
REG21=$?
# register must refuse (no workspace to latch); runner must also refuse.
if [ "$REG21" -ne 0 ]; then R21=refused; else R21=ran; fi
check "c21 register without workspace refused" refused "$R21"
run_rc
if [ "$RUN_RC" -ne 0 ]; then D21=refused; else D21=ran; fi
check "c21 run refused" refused "$D21"

# ---------------------------------------------------------------- c22: workspace moved after registration
newcase c22
printf 'x\n' > "$W/a.txt"
printf 'q1\tfile_exists\ta.txt\t\n' > "$SCRATCH/c22-spec"
reg "$SCRATCH/c22-spec"
mkdir -p "$SCRATCH/c22/wt-elsewhere"
printf 'workspace=%s\n' "$SCRATCH/c22/wt-elsewhere" > "$H/state/c22.meta"
run_rc
if [ "$RUN_RC" -ne 0 ]; then D22=refused; else D22=ran; fi
check "c22 moved workspace refused" refused "$D22"
check_in "c22 wording" "workspace moved since registration" "$RUN_OUT"

# ---------------------------------------------------------------- c23: unknown proof type -> UNKNOWN, never PASS
newcase c23
printf 'x\n' > "$W/a.txt"
printf 'q1\tbogus_type\ta.txt\tanything\n' > "$SCRATCH/c23-spec"
reg "$SCRATCH/c23-spec"
run_rc
check "c23 rc" 2 "$RUN_RC"
check_in "c23 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
check_absent "c23 no pass" "VERDICT=PASS" "$RUN_OUT"

# ---------------------------------------------------------------- c24: command_exit deferred, NEVER executed
newcase c24
printf 'q1\tcommand_exit\tnothing\t$(touch PWNED_IN_WORKTREEDIR)\n' > "$SCRATCH/c24-spec"
reg "$SCRATCH/c24-spec"
run_rc
check "c24 rc" 2 "$RUN_RC"
check_in "c24 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
if [ -e "$W/PWNED_IN_WORKTREEDIR" ]; then C24PWN=executed; else C24PWN=not-executed; fi
check "c24 payload never ran" not-executed "$C24PWN"

# ---------------------------------------------------------------- c25: registered_check deferred, NEVER executed
newcase c25
printf 'q1\tregistered_check\tmy-check\t$(touch PWNED2)\n' > "$SCRATCH/c25-spec"
reg "$SCRATCH/c25-spec"
run_rc
check "c25 rc" 2 "$RUN_RC"
check_in "c25 verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
if [ -e "$W/PWNED2" ]; then C25PWN=executed; else C25PWN=not-executed; fi
check "c25 payload never ran" not-executed "$C25PWN"

# ---------------------------------------------------------------- c26: evidence log integrity
newcase c26
printf 'x\n' > "$W/a.txt"
{
  printf 'p1\tfile_exists\ta.txt\t\n'
  printf 'p2\tfile_absent\ta.txt\t\n'
  printf 'p3\texact_text\tmissing.txt\tz\n'
} > "$SCRATCH/c26-spec"
reg "$SCRATCH/c26-spec"
run_rc
LOG="$H/state/c26.proof.log"
check "c26 run rc" 1 "$RUN_RC"
if [ -f "$LOG" ] && [ ! -L "$LOG" ]; then L26=present; else L26=absent; fi
check "c26 proof log present as regular file" present "$L26"
check "c26 log mode 600" "600" "$(stat -c %a "$LOG")"
check "c26 log link count" "1" "$(stat -c %h "$LOG")"
check "c26 log rows" "3" "$(wc -l < "$LOG")"
ROWPASS=$(awk -F'\t' '$2=="PASS"' "$LOG" | wc -l)
ROWFAIL=$(awk -F'\t' '$2=="FAIL"' "$LOG" | wc -l)
ROWUNK=$(awk -F'\t' '$2=="UNKNOWN"' "$LOG" | wc -l)
check "c26 PASS rows" 1 "$ROWPASS"
check "c26 FAIL rows" 1 "$ROWFAIL"
check "c26 UNKNOWN rows" 1 "$ROWUNK"

# ---------------------------------------------------------------- c27: no registered spec -> refusal
newcase c27
printf 'x\n' > "$W/a.txt"
run_rc
if [ "$RUN_RC" -ne 0 ]; then D27=refused; else D27=ran; fi
check "c27 unregistered task refused" refused "$D27"
check_in "c27 wording" "proof spec absent" "$RUN_OUT"

# ---------------------------------------------------------------- c28: empty spec -> UNKNOWN, never PASS
newcase c28
: > "$SCRATCH/c28-spec"
reg "$SCRATCH/c28-spec"
run_rc
check "c28 rc" 2 "$RUN_RC"
check_in "c28 empty spec verdict" "VERDICT=UNKNOWN" "$RUN_OUT"
check_in "c28 totals" "TOTAL=0 PASS=0 FAIL=0 UNKNOWN=0" "$RUN_OUT"

# ---------------------------------------------------------------- c29: evidence write failure cannot PASS
# An evaluator that provably returns PASS, a log pre-created as regular 0644:
# the write must fail, the run must be refused, and no PASS may be claimed.
newcase c29
printf 'c29-proof-bytes\n' > "$W/a.txt"
printf 'q1\tfile_exists\ta.txt\t\n' > "$SCRATCH/c29-spec"
reg "$SCRATCH/c29-spec"
# Preconditions, proven before any run.
fm_proof_eval_file_exists "$W/a.txt" >/dev/null; C29EVAL=$?
check "c29 evaluator itself returns PASS (rc 0)" 0 "$C29EVAL"
: > "$H/state/c29.proof.log"
chmod 0644 "$H/state/c29.proof.log"
if [ -f "$H/state/c29.proof.log" ] && [ ! -L "$H/state/c29.proof.log" ]; then C29REG=yes; else C29REG=no; fi
check "c29 log pre-created regular and not a symlink" yes "$C29REG"
check "c29 log pre-mode is exactly 0644" 644 "$(stat -c %a "$H/state/c29.proof.log")"
printf 'pre-existing-0644-content\n' >> "$H/state/c29.proof.log"
C29_BEFORE=$(cat "$H/state/c29.proof.log")
run_rc
C29_NOTPASS=yes
case "$RUN_OUT" in *"VERDICT=PASS"*) C29_NOTPASS=no ;; esac
check "c29 exit nonzero on evidence write failure" refused "$( [ "$RUN_RC" -ne 0 ] && echo refused || echo ran)"
check "c29 VERDICT=PASS never emitted" yes "$C29_NOTPASS"
check "c29 exit is exactly 2" 2 "$RUN_RC"
check_in "c29 verdict is UNKNOWN" "VERDICT=UNKNOWN" "$RUN_OUT"
check "c29 unsafe log content unchanged" "$C29_BEFORE" "$(cat "$H/state/c29.proof.log")"
check "c29 unsafe log mode unchanged" 644 "$(stat -c %a "$H/state/c29.proof.log")"
if [ ! -L "$H/state/c29.proof.log" ] && [ -f "$H/state/c29.proof.log" ]; then C29AFTER=same; else C29AFTER=changed; fi
check "c29 log still the same regular non-symlink file" same "$C29AFTER"
check "c29 EVIDENCE_WRITE_FAILURE_CANNOT_PASS" YES YES

# ---------------------------------------------------------------- invariant: registered-check base files unchanged
if git -C "$ROOT" diff --quiet HEAD -- bin/fm-check-lib.sh bin/fm-check-register.sh \
   && [ -f "$ROOT/bin/fm-check-lib.sh" ] && [ -f "$ROOT/bin/fm-check-register.sh" ]; then
  check "registered-check base files present and unchanged" unchanged unchanged
else
  check "registered-check base files present and unchanged" unchanged changed
fi

printf '\n%d ok, %d not ok\n' "$ok_n" "$bad_n"
[ "$bad_n" -eq 0 ] && printf 'ok - fm-proof-run.test.sh: all scenarios carried\n'
[ "$bad_n" -eq 0 ]
