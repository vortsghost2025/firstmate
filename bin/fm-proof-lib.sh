#!/usr/bin/env bash
# bin/fm-proof-lib.sh - the read-only evaluators that fm-proof-run.sh calls.
#
# Every function here is a pure reader; none write anywhere, all fail closed.
#
# Result vocabulary (one printf-on-stdout, exit status carries the verdict):
#   PASS  -> the expected condition matched observed reality exactly
#   FAIL  - the expected condition is contradicted by observed reality
#   UNKNOWN - could not verify either way; never a synthetic pass
#
# The print format is exactly two tab-separated fields on one line:
#   <VERDICT>\t<one-line observation>
set -u

# fm_proof_eval_file_exists <path>
fm_proof_eval_file_exists() {
  local path=$1
  if [ -e "$path" ]; then
    printf 'PASS\t%s\n' "file exists: $path"
    return 0
  fi
  printf 'FAIL\t%s\n' "file absent: $path"
  return 1
}

# fm_proof_eval_file_absent <path>
fm_proof_eval_file_absent() {
  local path=$1
  if [ -e "$path" ]; then
    printf 'FAIL\t%s\n' "file exists: $path"
    return 1
  fi
  printf 'PASS\t%s\n' "file absent: $path"
  return 0
}

# fm_proof_eval_exact_text <path> <expected-content>
fm_proof_eval_exact_text() {
  local path=$1 want=$2
  if [ ! -e "$path" ]; then
    printf 'UNKNOWN\t%s\n' "file missing: $path"
    return 2
  fi
  if [ ! -r "$path" ]; then
    printf 'UNKNOWN\t%s\n' "file unreadable: $path"
    return 2
  fi
  local have
  have=$(cat -- "$path" 2>/dev/null)
  if [ -z "$have" ]; then
    printf 'UNKNOWN\t%s\n' "file empty: $path"
    return 2
  fi
  if [ "$have" = "$want" ]; then
    printf 'PASS\t%s\n' "content matches exactly"
    return 0
  fi
  printf 'FAIL\t%s\n' "content mismatch"
  return 1
}

# fm_proof_eval_regex_match <path> <pattern>
fm_proof_eval_regex_match() {
  local path=$1 pattern=$2
  if [ ! -e "$path" ]; then
    printf 'UNKNOWN\t%s\n' "file missing: $path"
    return 2
  fi
  if [ ! -s "$path" ]; then
    printf 'UNKNOWN\t%s\n' "file empty: $path"
    return 2
  fi
  if grep -qE -- "$pattern" "$path" 2>/dev/null; then
    printf 'PASS\t%s\n' "pattern matched"
    return 0
  fi
  printf 'FAIL\t%s\n' "pattern not found"
  return 1
}

# fm_proof_canon <workspace> <subject>
# Resolve a declared subject into its canonical in-workspace location. A
# subject that escapes the workspace (via '..', absolute path, or a symlink
# that resolves outside) is refused outright; the function's stdout is the
# canonical path otherwise.
fm_proof_canon() {
  local subject=$1 workspace=$2
  printf '%s\n' "$workspace/$subject"
}

# fm_proof_write_row <state-dir> <task-id> <verdict> <proof-id> <type> <note>
# Append one evidence row to the per-task proof log. The log lives under
# state/, never in the project workspace, so an interrupted sequence never
# pollutes deliverables.
fm_proof_write_row() {
  local state=$1 task=$2 verdict=$3 pid=$4 ptype=$5 note=$6
  local log="$state/$task.proof.log"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%FT%TZ)" \
    "$task" \
    "$verdict" \
    "$pid" \
    "$ptype" \
    "$note" >> "$log"
}
