# fm-dsh-lib.sh - configuration-driven resolution for the dsh harness (v1).
#
# V1 scope: direct CLI, headless profile only, scout and ordinary-crew kinds.
# Everything operational is operator CONFIGURATION under the firstmate config
# directory; no runtime path, home, or credential is ever baked into source.
#
# Config files (all single-line, first line wins, trailing CR stripped):
#   config/dsh-executable  Absolute path. Either a node binary (then
#                          config/dsh-runtime-root MUST also exist) or a
#                          self-contained dsh launcher executable (when
#                          config/dsh-runtime-root does not exist).
#   config/dsh-runtime-root A CONFIG FILE (not a directory) carrying one
#                          absolute runtime-root path whose
#                          apps/cli/lib/bin.js must exist. Its PRESENCE
#                          selects node+bin.js launch-pair mode; its absence
#                          selects launcher mode. A directory at this path, an
#                          empty file, a relative value, or a malformed file
#                          REFUSES - it never silently changes launch mode.
#   config/dsh-home        Existing directory handed to the child as DSH_HOME.
#   config/dsh-env         Optional. Operator-owned KEY=VALUE child-env file
#                          (recommended mode 0600). Delivered to the child by
#                          bin/fm-dsh-env-exec.sh, which reads values as
#                          byte-literal strings (no sourcing/eval) and execs
#                          the DSH command with them exported. Values never
#                          pass through argv, meta, status, reports, logs, or
#                          test output.
#
# Safety posture: NO eval, NO source/dot of operator files, NO free-form
# launch-pair parsing, NO word splitting of operator input. Every component
# emitted here is individually shell_quote'd (or validated against a strict
# character class) so the pane command is safe under set -u/-e callers and
# hostile file contents alike.
#
# Test seam: FM_DSH_CONFIG_DIR overrides the config directory; otherwise
# "$FM_ROOT/config", otherwise the tree this file lives in.

FM_DSH_LIB_ROOT=${FM_DSH_LIB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

# Private quoter so this library is self-contained under any sourcer (spawn,
# backends/tmux.sh, harness detection, tests) without ordering dependencies on
# fm-spawn.sh's own shell_quote.
_fm_dsh_shell_quote() {
  local s=$1
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

fm_dsh_config_dir() {
  printf '%s' "${FM_DSH_CONFIG_DIR:-${FM_ROOT:-$FM_DSH_LIB_ROOT}/config}"
}

# fm_dsh_read_single_line <path> <result-var>
# First line, trailing CR stripped. Fails when the file is absent, unreadable,
# or has an empty first line. Never prints the value.
fm_dsh_read_single_line() {
  local path=$1 result_var=$2 line
  [ -f "$path" ] || return 1
  IFS= read -r line < "$path" || return 1
  line=${line%$'\r'}
  [ -n "$line" ] || return 1
  printf -v "$result_var" '%s' "$line"
  return 0
}

# fm_dsh_require_abs_path <label> <value>
# Validation only: silent on success, diagnostic on failure.
fm_dsh_require_abs_path() {
  case ${2-} in
    /*) return 0 ;;
  esac
  echo "error: dsh config '$1' must be an absolute path (got a relative or malformed value); refusing" >&2
  return 1
}

# fm_dsh_resolve_launch
# Prints the shell-quoted launch pair for the configured runtime:
#   node form:   '<node-abs>' '<root>/apps/cli/lib/bin.js'
#   launcher:    '<launcher-abs>'
# Selection is STRUCTURAL: config/dsh-runtime-root is itself a CONFIG FILE
# whose single line is the absolute runtime-root path. Absent file => launcher
# form; a file present (even empty/relative/malformed) => pair form, validated
# strictly; a DIRECTORY at that path is a hard refusal, never a silent mode
# switch. No free-form parsing, no eval.
fm_dsh_resolve_launch() {
  local cfg exe_file root_file exe root binjs
  cfg=$(fm_dsh_config_dir)
  exe_file=$cfg/dsh-executable
  root_file=$cfg/dsh-runtime-root
  fm_dsh_read_single_line "$exe_file" exe || {
    echo "error: dsh config '$exe_file' is missing or empty; create it with an absolute node or launcher path" >&2
    return 1
  }
  fm_dsh_require_abs_path dsh-executable "$exe" || return 1
  [ -x "$exe" ] || {
    echo "error: dsh executable '$exe' is not executable; refusing" >&2
    return 1
  }
  if [ -e "$root_file" ] && [ ! -f "$root_file" ]; then
    echo "error: dsh config '$root_file' exists but is not a regular file; refusing rather than silently changing launch mode" >&2
    return 1
  fi
  if [ -f "$root_file" ]; then
    fm_dsh_read_single_line "$root_file" root || {
      echo "error: dsh config '$root_file' exists but is unreadable or empty; refusing rather than silently switching to launcher form (remove the file to select launcher form explicitly)" >&2
      return 1
    }
    fm_dsh_require_abs_path dsh-runtime-root "$root" || return 1
    [ -d "$root" ] || {
      echo "error: dsh runtime root '$root' is not a directory; refusing" >&2
      return 1
    }
    binjs=$root/apps/cli/lib/bin.js
    [ -f "$binjs" ] || {
      echo "error: dsh runtime root '$root' does not contain apps/cli/lib/bin.js; refusing" >&2
      return 1
    }
    printf '%s %s' "$(_fm_dsh_shell_quote "$exe")" "$(_fm_dsh_shell_quote "$binjs")"
  else
    printf '%s' "$(_fm_dsh_shell_quote "$exe")"
  fi
}

# fm_dsh_resolve_home
# Prints the raw DSH home directory (caller shell_quote's it).
fm_dsh_resolve_home() {
  local cfg home
  cfg=$(fm_dsh_config_dir)
  fm_dsh_read_single_line "$cfg/dsh-home" home || {
    echo "error: dsh config '$cfg/dsh-home' is missing or empty; create it with the absolute DSH home directory" >&2
    return 1
  }
  fm_dsh_require_abs_path dsh-home "$home" || return 1
  [ -d "$home" ] || {
    echo "error: dsh home '$home' does not exist or is not a directory; refusing" >&2
    return 1
  }
  printf '%s' "$home"
}

# fm_dsh_resolve_env_prefix
# Prints the pane-side child-env prefix for the optional operator env file. The
# prefix invokes bin/fm-dsh-env-exec.sh (a loader that reads KEY=VALUE lines
# byte-literally and execs the DSH command with them exported) instead of ever
# sourcing the file: sourcing would evaluate shell syntax inside values
# (command substitution, backticks, separators) on the spawn boundary.
# Empty output (success) when config/dsh-env is absent, so providers that need
# no injected secret still launch. When present, the file must be owner-only
# readable (group/other bits zero) and every non-empty line must match
# ^[A-Za-z_][A-Za-z0-9_]*=. Validation cites line NUMBERS, never values; the
# loader re-verifies the same contract at exec time so the launch boundary
# fails closed even if this check raced.
fm_dsh_resolve_env_prefix() {
  local cfg env_file loader mode bad
  cfg=$(fm_dsh_config_dir)
  env_file=$cfg/dsh-env
  loader=$FM_DSH_LIB_ROOT/bin/fm-dsh-env-exec.sh
  [ -e "$env_file" ] || return 0
  [ -f "$env_file" ] || {
    echo "error: dsh config '$env_file' is not a regular file; refusing" >&2
    return 1
  }
  [ -x "$loader" ] || {
    echo "error: dsh env loader '$loader' is missing or not executable; refusing" >&2
    return 1
  }
  mode=$(stat -c '%a' "$env_file" 2>/dev/null) || mode=$(stat -f '%Lp' "$env_file" 2>/dev/null) || {
    echo "error: could not stat dsh env file '$env_file'; refusing" >&2
    return 1
  }
  if [[ ! $mode =~ ^[0-7]?[0-7]00$ ]]; then
    echo "error: dsh env file '$env_file' must be accessible only by its owner (mode 600 or 400 recommended; group/other bits must be zero); refusing" >&2
    return 1
  fi
  bad=$(grep -nEv '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" | head -1)
  [ -z "$bad" ] || {
    echo "error: dsh env file '$env_file' line ${bad%%:*} is not KEY=VALUE with a valid identifier key; refusing" >&2
    return 1
  }
  printf '%s %s -- ' "$(_fm_dsh_shell_quote "$loader")" "$(_fm_dsh_shell_quote "$env_file")"
}

# fm_dsh_process_matches <path> [argv0]
# Structural identity for a LIVE dsh worker process: the configured runtime
# root's apps/cli/lib/bin.js appears in the process path or argv. Mirrors the
# launch rule: config/dsh-runtime-root must be a REGULAR config file carrying
# one absolute root path (a directory at that path, an empty/malformed file, or
# absence all mean "cannot prove identity" and match nothing). Unrelated node
# processes never match, and a machine without dsh keeps today's
# classification byte-for-byte.
fm_dsh_process_matches() {
  local path=${1-} argv0=${2-} cfg root_file root needle
  cfg=$(fm_dsh_config_dir)
  root_file=$cfg/dsh-runtime-root
  [ -f "$root_file" ] || return 1
  fm_dsh_read_single_line "$root_file" root || return 1
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  needle=$root/apps/cli/lib/bin.js
  case "$path" in
    *"$needle"*) return 0 ;;
  esac
  case "$argv0" in
    *"$needle"*) return 0 ;;
  esac
  return 1
}
