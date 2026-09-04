#!/usr/bin/env bash
# fm-dsh-env-exec.sh - safe child-env loader for the dsh harness.
#
# Usage:
#   fm-dsh-env-exec.sh <env-file> -- <command> [args...]
#
# FirstMate's dsh adapter must hand operator config values (e.g. a provider
# API key) to the DSH child process WITHOUT any shell parsing of values. This
# loader replaces a previous spawn-time `set -a; . config/dsh-env; set +a`
# sourcing prefix: sourcing evaluates shell syntax in values (command
# substitution, backticks, separators), which is both a command-injection
# surface and a launch-boundary trick. This loader never evals, never sources,
# and never feeds values through argv expansion twice:
#
#   - argv carries ONLY the env file path, the -- separator, and the real DSH
#     command/args; values never appear in argv.
#   - The file is re-validated here (regular, readable, owner-only perms) so
#     the launch boundary fails closed even if spawn's earlier check raced.
#   - Every non-empty line must be KEY=VALUE with an identifier key
#     (^([A-Za-z_][A-Za-z0-9_]*)=...). Keys are validated BEFORE any export.
#   - The value is the byte-literal remainder of the line after the first '='.
#     Command substitutions, backticks, globs, quotes, spaces, semicolons, and
#     further '=' characters inside a value undergo no evaluation: they are
#     copied byte-for-byte into a single quoted `export "$key=$value"`.
#
# After loading, the loader execs the command with the caller's inherited
# environment (DSH_HOME, DSH_PERMISSION_MODE, DSH_TELEMETRY_DISABLED, and any
# other spawn-provided assignments) MERGED with the operator keys above.
#
# Exit codes: 64 usage, 65 malformed env file, 66 missing/unreadable, 77 perms.
set -eu

[ "$#" -ge 3 ] || {
  echo "usage: fm-dsh-env-exec.sh <env-file> -- <command> [args...]" >&2
  exit 64
}
env_file=$1
[ "${2-}" = -- ] || {
  echo "error: fm-dsh-env-exec expects '--' after the env file path" >&2
  exit 64
}
shift 2
[ "$#" -ge 1 ] || {
  echo "error: fm-dsh-env-exec got no command after --" >&2
  exit 64
}

[ -f "$env_file" ] || {
  echo "error: dsh env file is not a regular file: $env_file" >&2
  exit 66
}
[ -r "$env_file" ] || {
  echo "error: dsh env file is not readable: $env_file" >&2
  exit 66
}
mode=$(stat -c '%a' "$env_file" 2>/dev/null || stat -f '%Lp' "$env_file" 2>/dev/null) || {
  echo "error: could not stat dsh env file: $env_file" >&2
  exit 66
}
if [[ ! $mode =~ ^[0-7]?[0-7]00$ ]]; then
  echo "error: dsh env file must be owner-only (0600 recommended); group/other bits must be zero: $env_file" >&2
  exit 77
fi

lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  line=${line%$'\r'}
  [ -z "$line" ] && continue
  case "$line" in
    [A-Za-z_]*=*) ;;
    *)
      echo "error: dsh env file line $lineno is not KEY=VALUE with a valid identifier key: $env_file" >&2
      exit 65
      ;;
  esac
  key=${line%%=*}
  case "$key" in
    *[!A-Za-z0-9_]*)
      echo "error: dsh env file line $lineno has an invalid key character: $env_file" >&2
      exit 65
      ;;
  esac
  value=${line#*=}
  # Quoted expansion: the value text is NEVER re-parsed, so $(), backticks,
  # globs, quotes, spaces, semicolons, and further '=' remain literal bytes.
  export "$key=$value"
done < "$env_file"

exec "$@"
