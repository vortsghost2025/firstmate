#!/usr/bin/env bash
# bin/fm-proof-lib.sh - bounded evaluators and evidence writer for fm-proof-run.sh.
#
# Every function here is read-only. None of them write anything besides the
# task's own proof.log under a properly validated state dir. Verdicts are
# reported through exit codes exactly: 0=PASS 1=FAIL 2=UNKNOWN.
set -u

FM_PROOF_VERIFIER=${FM_PROOF_VERIFIER:-fm-proof-run-v1}

# --- evaluator surface -------------------------------------------------------

fm_proof_eval_file_exists() {  # <path>
  local path=$1
  [ -e "$path" ] && { printf 'PASS\tfile exists\n'; return 0; }
  printf 'FAIL\tfile does not exist\n'
  return 1
}

fm_proof_eval_file_absent() {  # <path>
  local path=$1
  [ ! -e "$path" ] && { printf 'PASS\tfile absent\n'; return 0; }
  printf 'FAIL\tfile is present\n'
  return 1
}

fm_proof_eval_exact_text() {  # <path> <expected-bytes>
  local path=$1 want=$2 got
  [ -e "$path" ] || { printf 'UNKNOWN\tfile missing\n'; return 2; }
  [ -r "$path" ] || { printf 'UNKNOWN\tfile unreadable\n'; return 2; }
  got=$(cat -- "$path" 2>/dev/null)
  [ "$got" = "$want" ] && { printf 'PASS\tcontent matches\n'; return 0; }
  printf 'FAIL\tcontent differs\n'
  return 1
}

fm_proof_eval_regex_match() {  # <path> <extended-regex>
  local path=$1 pat=$2
  [ -e "$path" ] || { printf 'UNKNOWN\tfile missing\n'; return 2; }
  [ -s "$path" ] || { printf 'UNKNOWN\tfile empty\n'; return 2; }
  grep -qE -- "$pat" "$path" 2>/dev/null && { printf 'PASS\tpattern found\n'; return 0; }
  printf 'FAIL\tno match\n'
  return 1
}

# --- canonical-path guard ----------------------------------------------------
# fm_proof_canon <subject> <workspace-canonical-realpath>
# Writes the resolved child path to stdout when it's a strict in-workspace path.
# Refuses outright otherwise (absolute, traversal, external symlink).
fm_proof_canon() {
  local subject=$1 workspace=$2 canon
  [ -n "$subject" ] || return 1
  case "$subject" in
    /*) return 1 ;;                      # absolute input: never a workspace child
    *..*) return 1 ;;                    # parent traversal: never acceptable
  esac
  canon=$(realpath -m -- "$workspace/$subject") || return 1
  [ "$canon" = "$workspace" ] && return 1
  case "$canon" in
    "$workspace"/*) printf '%s\n' "$canon" ;;
    *) return 1 ;;
  esac
}

# --- evidence writer ----------------------------------------------------------
# fm_proof_write_row <state-dir> <task-id> <verdict> <proof-id> <type> <note>
# Refuses and returns nonzero unless the destination proves safe: state dir is
# real and not a symlink, log is never a symlink, and an existing log passes the
# full private single-link check. A first write creates the log 0600 and then
# re-validates it before the row lands.
fm_proof_write_row() {
  local state=$1 id=$2 verdict=$3 proof_id=$4 type=$5 note=$6 ts log dev
  [ -d "$state" ] || return 1
  [ ! -L "$state" ] || return 1
  log="$state/$id.proof.log"
  [ ! -L "$log" ] || return 1
  dev=$(fm_pr_file_device "$state") || return 1
  if [ -e "$log" ]; then
    fm_pr_private_file_valid "$log" 600 "$dev" || return 1
  else
    ( umask 077 && : >"$log" ) || return 1
    chmod 600 "$log" 2>/dev/null || { rm -f -- "$log"; return 1; }
    fm_pr_private_file_valid "$log" 600 "$dev" || { rm -f -- "$log"; return 1; }
  fi
  ts=$(date -u +%FT%TZ)
  printf '%s\t%s\t%s\t%s\t%s\n' "$ts" "$verdict" "$proof_id" "$type" "$note" >>"$log"
}
