#!/usr/bin/env bash
# bin/fm-proof-lib.sh - small read-only evaluators used by fm-proof-run.sh.
#
# Each evaluator answers with a PASS/FAIL/UNKNOWN verdict line. They never
# write to the project, never read from outside their argument surfaces, and
# never evaluate user input.

FM_PROOF_VERIFIER=${FM_PROOF_VERIFIER:-fm-proof-run-v1}

# fm_proof_eval_file_exists <path> -> PASS if the file exists, else FAIL.
fm_proof_eval_file_exists() {
  local path=$1
  [ -e "$path" ] && { printf 'PASS\t%s exists\n' "$path"; return 0; }
  printf 'FAIL\t%s absent\n' "$path"
  return 1
}

# fm_proof_eval_file_absent <path> -> PASS if the path doesn't exist.
fm_proof_eval_file_absent() {
  local path=$1
  [ -e "$path" ] && { printf 'FAIL\t%s exists\n' "$path"; return 1; }
  printf 'PASS\t%s absent\n' "$path"
}

# fm_proof_eval_exact_text <path> <expected> - file's exact content must match.
fm_proof_eval_exact_text() {
  local path=$1 want=$2 have
  [ -r "$path" ] || { printf 'UNKNOWN\tfile unreadable\n'; return 1; }
  have=$(cat -- "$path" 2>/dev/null)
  [ -n "$have" ] || { printf 'UNKNOWN\tfile is empty\n'; return 1; }
  if [ "$have" = "$want" ]; then printf 'PASS\tcontent exact match\n'; else printf 'FAIL\tcontent mismatch\n'; return 1; fi
}

# fm_proof_eval_regex_match <path> <pattern> - PASS if the regex matches.
fm_proof_eval_regex_match() {
  local path=$1 pat=$2
  [ -s "$path" ] || { printf 'UNKNOWN\tfile empty or missing\n'; return 1; }
  grep -qE -- "$pat" "$path" >/dev/null 2>&1 && { printf 'PASS\tregex matched\n'; return 0; }
  printf 'FAIL\tregex no match\n'
  return 1
}

# fm_proof_write_row <log> <proof_id> <type> <subject> <expected> <observed> <verdict>
# Writes one bounded tab-separated record; no caller text may corrupt the log.
fm_proof_write_row() {
  local log=$1 id=$2 type=$3 subject=$4 expect=$5 observed=$6 verdict=$7 ts
  ts=$(date -u +%FT%TZ)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$id" "$type" "$subject" "$expect" "$observed" "$verdict" "$FM_PROOF_VERIFIER" >> "$log"
}
