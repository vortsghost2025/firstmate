#!/usr/bin/env bash
# bin/fm-proof-register.sh - pin a proof spec's exact bytes and the current
# workspace into a FirstMate-owned trust record.
#
# The task's spec is written by firstmate into a temporary location; this
# script installs it at state/<id>.proof.spec (0600, single-link) and writes a
# matching three-line trust record at state/<id>.proof.trust. Everything after
# registration is read-only: both files are bound to exactly what was captured
# here, and any drift rejects the runner outright.
#
# Usage: bin/fm-proof-register.sh <task-id> <spec-path>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

. "$SCRIPT_DIR/fm-pr-lib.sh"

# --------- inputs -----------------------------------------------------------
[ $# -eq 2 ] || { printf 'usage: fm-proof-register.sh <task-id> <proof-spec>\n' >&2; exit 2; }
TASK_ID=$1
SRC_SPEC=$2

fm_pr_task_id_valid "$TASK_ID" \
  || { printf 'refused: invalid task id: %s\n' "$TASK_ID" >&2; exit 1; }
[ -f "$SRC_SPEC" ] || { printf 'refused: source proof spec absent\n' >&2; exit 1; }
[ ! -L "$SRC_SPEC" ] || { printf 'refused: source proof spec may not be a symlink\n' >&2; exit 1; }

# ---------- state-side destination ------------------------------------------
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { printf 'refused: state directory is unsafe\n' >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || { printf 'refused: state device unavailable\n' >&2; exit 1; }

TARGET_SPEC="$STATE/$TASK_ID.proof.spec"
TARGET_TRUST="$STATE/$TASK_ID.proof.trust"

# Never write through a stale link or onto a non-regular destination.
for dest in "$TARGET_SPEC" "$TARGET_TRUST"; do
  if [ -L "$dest" ]; then
    printf 'refused: destination is a symlink: %s\n' "$dest" >&2
    exit 1
  fi
  if [ -e "$dest" ] && [ ! -f "$dest" ]; then
    printf 'refused: destination is not a regular file: %s\n' "$dest" >&2
    exit 1
  fi
done

# ---------- workspace identity ----------------------------------------------
META="$STATE/$TASK_ID.meta"
[ -f "$META" ] || { printf 'refused: task metadata absent: %s\n' "$META" >&2; exit 1; }
WORKSPACE_RAW=$(sed -n 's/^workspace=//p' "$META" | head -1)
[ -n "$WORKSPACE_RAW" ] || { printf 'refused: task record missing workspace=\n' >&2; exit 1; }
WORKSPACE=$(readlink -f -- "$WORKSPACE_RAW" 2>/dev/null)
[ -n "$WORKSPACE" ] && [ -d "$WORKSPACE" ] || {
  printf 'refused: recorded workspace cannot be canonicalized: %s\n' "$WORKSPACE_RAW" >&2
  exit 1
}

# ---------- install spec on the trusted path -------------------------------
# Hash first so the trust record can carry the exact pinned bytes.
SPEC_HASH=$(sha256sum -- "$SRC_SPEC" | awk '{print $1}')

SPEC_TMP=$(mktemp "$STATE/.proof-spec.XXXXXX") || { printf 'refused: cannot create temporary spec path\n' >&2; exit 1; }
chmod 0600 "$SPEC_TMP" || { rm -f -- "$SPEC_TMP"; exit 1; }
cp -- "$SRC_SPEC" "$SPEC_TMP" || { rm -f -- "$SPEC_TMP"; exit 1; }

# Validate the installed copy before the trust record is written.
fm_pr_private_file_valid "$SPEC_TMP" 600 "$STATE_DEVICE" || {
  printf 'refused: installed spec is not a private file\n' >&2
  rm -f -- "$SPEC_TMP"
  exit 1
}
mv -f -- "$SPEC_TMP" "$TARGET_SPEC" || { rm -f -- "$SPEC_TMP"; exit 1; }
fm_pr_private_file_valid "$TARGET_SPEC" 600 "$STATE_DEVICE" || {
  printf 'refused: installed spec ended up wrong\n' >&2
  exit 1
}

# ---------- trust record ----------------------------------------------------
TRUST_TMP=$(mktemp "$STATE/.proof-trust.XXXXXX") || { printf 'refused: cannot create temporary trust path\n' >&2; exit 1; }
chmod 0600 "$TRUST_TMP" || { rm -f -- "$TRUST_TMP"; exit 1; }
{
  printf 'fm-proof-trust v2\n'
  printf '%s\n' "$SPEC_HASH"
  printf '%s\n' "$WORKSPACE"
} > "$TRUST_TMP"
fm_pr_private_file_valid "$TRUST_TMP" 600 "$STATE_DEVICE" || {
  rm -f -- "$TRUST_TMP"
  printf 'refused: staged trust record failed validation\n' >&2
  exit 1
}
mv -f -- "$TRUST_TMP" "$TARGET_TRUST" || { rm -f -- "$TRUST_TMP"; exit 1; }

# Read back the registered bytes from their final location so the evidence is
# proven rather than presumed.
FRESH_SPEC_HASH=$(sha256sum -- "$TARGET_SPEC" 2>/dev/null | awk '{print $1}')
if [ "$FRESH_SPEC_HASH" != "$SPEC_HASH" ]; then
  printf 'refused: written spec hash differs from source\n' >&2
  rm -f -- "$TARGET_SPEC" "$TARGET_TRUST"
  exit 1
fi

printf 'registered: %s (spec=%s, workspace=%s)\n' "$TASK_ID" "$SPEC_HASH" "$WORKSPACE"
