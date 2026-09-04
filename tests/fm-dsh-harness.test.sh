#!/usr/bin/env bash
# Behavior tests for the dsh v1 adapter (config-driven headless direct CLI).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT_DSH_LIB="$ROOT/bin/fm-dsh-lib.sh"
CONTROL="$ROOT/bin/fm-control-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dsh-harness)

FAKE_SECRET='nvapi-FAKE-SECRET-VALUE-FOR-TESTS-0123456789'

new_cfg() {
  local dir=$1
  mkdir -p "$dir"
  printf '%s' "$dir"
}

write_cfg() {
  local dir=$1 name=$2 value=$3
  printf '%s\n' "$value" > "$dir/$name"
}

make_node() {
  local dir=$1
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/node"
  chmod +x "$dir/node"
  printf '%s' "$dir/node"
}

make_runtime() {
  local dir=$1
  mkdir -p "$dir/apps/cli/lib"
  printf '#!/usr/bin/env node\n' > "$dir/apps/cli/lib/bin.js"
  printf '%s' "$dir"
}

# --- resolution: missing config -------------------------------------------
CFG=$(new_cfg "$TMP_ROOT/missing")
out=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch' 2>/dev/null)
rc=$?
[ "$rc" -ne 0 ] && [ -z "$out" ] && pass 'resolve_launch refuses on missing config (nonzero, empty stdout)' \
  || fail "resolve_launch missing-config rc=$rc out=$out"

err=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch' 2>&1 >/dev/null)
assert_contains "$err" "dsh-executable" "missing-config error names the config file"

# --- resolution: relative executable refused ------------------------------
CFG=$(new_cfg "$TMP_ROOT/relative")
write_cfg "$CFG" dsh-executable 'relative/node'
out=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch' 2>/dev/null) \
  && fail 'resolve_launch accepted a relative executable' \
  || pass 'resolve_launch refuses a relative executable'

# --- resolution: node form happy path -------------------------------------
CFG=$(new_cfg "$TMP_ROOT/node-form")
NODE=$(make_node "$TMP_ROOT/node-form-bin")
RT=$(make_runtime "$TMP_ROOT/node-form-runtime")
write_cfg "$CFG" dsh-executable "$NODE"
write_cfg "$CFG" dsh-runtime-root "$RT"
out=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch')
expected="'$NODE' '$RT/apps/cli/lib/bin.js'"
[ "$out" = "$expected" ] && pass 'node-form resolves to the exact quoted launch pair' \
  || fail "node-form pair mismatch: got [$out] want [$expected]"

# --- resolution: runtime root without bin.js ------------------------------
BADRT=$(new_cfg "$TMP_ROOT/bad-runtime")
CFG=$(new_cfg "$TMP_ROOT/bad-runtime-cfg")
write_cfg "$CFG" dsh-executable "$NODE"
write_cfg "$CFG" dsh-runtime-root "$BADRT"
FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch' 2>/dev/null \
  && fail 'resolve_launch accepted a runtime root without bin.js' \
  || pass 'resolve_launch refuses a runtime root without bin.js'

# --- resolution: empty runtime-root config refuses ------------------------
CFG=$(new_cfg "$TMP_ROOT/empty-root-cfg")
write_cfg "$CFG" dsh-executable "$NODE"
: > "$CFG/dsh-runtime-root"
err=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch' 2>&1 >/dev/null)
rc=$?
[ "$rc" -ne 0 ] && assert_contains "$err" "empty" "empty runtime-root config refuses loudly" \
  || fail "empty runtime-root config was not refused"

# --- resolution: directory at config path refuses -------------------------
CFG=$(new_cfg "$TMP_ROOT/dir-root-cfg")
write_cfg "$CFG" dsh-executable "$NODE"
DIR_AT_CFG=$(new_cfg "$TMP_ROOT/dir-at-config")  # a real directory at the config path
write_cfg "$CFG" dsh-runtime-root "$DIR_AT_CFG"
# A directory at the path means the config itself is a directory; also test a
# symlink-to-directory and an actual mkdir at the path.
rm -f "$CFG/dsh-runtime-root"; mkdir "$CFG/dsh-runtime-root"
FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch' 2>/dev/null \
  && fail 'resolve_launch accepted a directory at config/dsh-runtime-root' \
  || pass 'resolve_launch refuses a directory at config/dsh-runtime-root'

# --- resolution: relative runtime-root value refuses ----------------------
CFG=$(new_cfg "$TMP_ROOT/rel-root-cfg")
write_cfg "$CFG" dsh-executable "$NODE"
write_cfg "$CFG" dsh-runtime-root 'relative/path'
FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch' 2>/dev/null \
  && fail 'resolve_launch accepted a relative runtime-root value' \
  || pass 'resolve_launch refuses a relative runtime-root value'

# --- resolution: launcher form --------------------------------------------
CFG=$(new_cfg "$TMP_ROOT/launcher")
LAUNCHER=$(make_node "$TMP_ROOT/launcher-bin")  # any executable works structurally
write_cfg "$CFG" dsh-executable "$LAUNCHER"
out=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_launch')
[ "$out" = "'$LAUNCHER'" ] && pass 'launcher-form (absent runtime-root) resolves to the single quoted executable' \
  || fail "launcher-form mismatch: got [$out]"

# --- home ------------------------------------------------------------------
CFG=$(new_cfg "$TMP_ROOT/home")
HOMEDIR=$(new_cfg "$TMP_ROOT/homedir")
write_cfg "$CFG" dsh-home "$HOMEDIR"
out=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_home')
[ "$out" = "$HOMEDIR" ] && pass 'home resolves to the configured existing directory' \
  || fail "home mismatch: [$out]"
write_cfg "$CFG" dsh-home "$TMP_ROOT/nonexistent-home"
FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_home' 2>/dev/null \
  && fail 'home accepted a nonexistent directory' \
  || pass 'home refuses a nonexistent directory'

# --- env prefix: absent file means empty prefix ----------------------------
CFG=$(new_cfg "$TMP_ROOT/env-absent")
out=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_env_prefix')
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass 'absent env file yields an empty prefix (rc 0)' \
  || fail "env-absent rc=$rc out=[$out]"

# --- env prefix: permissive mode refused -----------------------------------
CFG=$(new_cfg "$TMP_ROOT/env-loose")
printf 'NVIDIA_API_KEY=%s\n' "$FAKE_SECRET" > "$CFG/dsh-env"
chmod 644 "$CFG/dsh-env"
FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_env_prefix' 2>/dev/null \
  && fail 'env prefix accepted a group/world-readable env file' \
  || pass 'env prefix refuses a group/world-readable env file'

# --- env prefix: invalid line refused, value never echoed ------------------
CFG=$(new_cfg "$TMP_ROOT/env-badline")
{ printf 'GOOD_KEY=value-one\n'; printf "not valid shell without equals\\n"; } > "$CFG/dsh-env"
chmod 600 "$CFG/dsh-env"
err=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_env_prefix' 2>&1 >/dev/null)
rc=$?
[ "$rc" -ne 0 ] && assert_contains "$err" "line 2" "invalid-line error cites the line number"

# --- env prefix: valid file + credential non-leakage ------------------------
CFG=$(new_cfg "$TMP_ROOT/env-good")
printf 'NVIDIA_API_KEY=%s\nOTHER_KEY=some-value\n' "$FAKE_SECRET" > "$CFG/dsh-env"
chmod 600 "$CFG/dsh-env"
out=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '. "'"$ROOT_DSH_LIB"'"; fm_dsh_resolve_env_prefix') \
  || fail 'env prefix failed on a valid 600 KEY=VALUE file'
assert_contains "$out" "fm-dsh-env-exec.sh" "valid env prefix invokes the safe loader"
assert_contains "$out" "'$CFG/dsh-env'" "valid env prefix passes the exact env file path"
assert_contains "$out" " -- " "valid env prefix separates env file from command with --"
assert_not_contains "$out" "$FAKE_SECRET" "env prefix output never contains the credential value"
assert_not_contains "$out" "set -a" "env prefix no longer sources the env file"
assert_not_contains "$out" ";" "env prefix emits no shell statements"

# --- loader: byte-literal delivery, zero execution --------------------------
CFG=$(new_cfg "$TMP_ROOT/loader-run")
MARKER="$TMP_ROOT/loader-run/INJECTED"
cat > "$CFG/dsh-env" <<ENV
FAKE_SECRET=$FAKE_SECRET
E1=\$(touch $MARKER)
E2=\`touch $MARKER\`
E3=semi;colon;evil
E4=spaces  and	tab
E5="double quoted"
E6='single quoted'
E7=has=more=equals
E8=*glob*
ENV
chmod 600 "$CFG/dsh-env"
out=$(FM_DSH_CONFIG_DIR="$CFG" "$ROOT/bin/fm-dsh-env-exec.sh" "$CFG/dsh-env" -- env 2>/dev/null)
rc=$?
[ "$rc" -eq 0 ] && assert_contains "$out" "E1=\$(touch $MARKER)" "loader keeps command-substitution value literal" \
  || fail "loader run failed (rc=$rc)"
assert_contains "$out" 'E2=`touch '"$MARKER"'`' "loader keeps backtick value literal"
assert_contains "$out" 'E3=semi;colon;evil' "loader keeps semicolon value literal"
assert_contains "$out" 'E7=has=more=equals' "loader keeps additional equals literal"
assert_contains "$out" 'E8=*glob*' "loader keeps glob characters literal"
assert_contains "$out" 'E5="double quoted"' "loader keeps double-quoted value literal"
assert_contains "$out" "FAKE_SECRET=$FAKE_SECRET" "loader delivers the credential byte-literal"
[ -e "$MARKER" ] && fail "loader executed a value ($MARKER exists)" \
  || pass 'loader executes NO values (injection marker absent)'

# --- loader: env-only perms refuse at exec boundary -------------------------
CFG=$(new_cfg "$TMP_ROOT/loader-loose")
printf 'K=some-value\n' > "$CFG/dsh-env"
chmod 644 "$CFG/dsh-env"
"$ROOT/bin/fm-dsh-env-exec.sh" "$CFG/dsh-env" -- true 2>/dev/null \
  && fail 'loader accepted a group/world-readable env file' \
  || pass 'loader refuses a group/world-readable env file at exec time'

# --- loader: nonexistent file refuses --------------------------------------
"$ROOT/bin/fm-dsh-env-exec.sh" "$TMP_ROOT/no-such-file" -- true 2>/dev/null \
  && fail 'loader accepted a nonexistent env file' \
  || pass 'loader refuses a nonexistent env file'

# --- loader: missing -- separator refuses ----------------------------------
printf 'K=v\n' > "$CFG/dsh-env"; chmod 600 "$CFG/dsh-env"
"$ROOT/bin/fm-dsh-env-exec.sh" "$CFG/dsh-env" true 2>/dev/null \
  && fail 'loader accepted a command without the -- separator' \
  || pass 'loader refuses a missing -- separator'

# full resolver sweep must not leak either
allout=$(FM_DSH_CONFIG_DIR="$CFG" bash -c '
  . "'"$ROOT_DSH_LIB"'"
  fm_dsh_resolve_launch; fm_dsh_resolve_home; fm_dsh_resolve_env_prefix
' 2>&1)
assert_not_contains "$allout" "$FAKE_SECRET" "no resolver output contains the credential value"

# --- process matcher --------------------------------------------------------
CFG=$(new_cfg "$TMP_ROOT/matcher")
RT=$(make_runtime "$TMP_ROOT/matcher-runtime")
write_cfg "$CFG" dsh-runtime-root "$RT"
( FM_DSH_CONFIG_DIR="$CFG"; . "$ROOT_DSH_LIB"
  fm_dsh_process_matches "/usr/bin/node $RT/apps/cli/lib/bin.js --profile headless" '' ) \
  || fail 'matcher failed to match the configured runtime in process args'
( FM_DSH_CONFIG_DIR="$CFG"; . "$ROOT_DSH_LIB"
  fm_dsh_process_matches "/usr/bin/node /somewhere/else/server.js" '' ) \
  && fail 'matcher matched an unrelated node process' \
  || pass 'matcher leaves unrelated node processes unmatched'
( FM_DSH_CONFIG_DIR="$TMP_ROOT/no-such-config"; . "$ROOT_DSH_LIB"
  fm_dsh_process_matches "/usr/bin/node $RT/apps/cli/lib/bin.js" '' ) \
  && fail 'matcher matched with config absent' \
  || pass 'matcher is a quiet no-op when dsh config is absent'

# --- control-plane tables ---------------------------------------------------
( . "$CONTROL"
  fm_control_harness_supported dsh || exit 1
  [ "$(fm_control_harness_family dsh)" = dsh ] || exit 1
  fm_control_harness_supports_kind dsh ship || exit 1
  fm_control_harness_supports_kind dsh scout || exit 1
  fm_control_harness_supports_kind dsh secondmate 2>/dev/null && exit 1
  fm_control_interrupt_key dsh 2>/dev/null && exit 1
  fm_control_interrupt_repeat dsh 2>/dev/null && exit 1
  fm_control_interrupt_clear_key dsh 2>/dev/null && exit 1
  fm_control_interrupt_ack_source dsh 2>/dev/null && exit 1
  fm_control_exit_command dsh 2>/dev/null && exit 1
  exit 0
) && pass 'control-lib: supported/family/kind verified, interrupt+exit refuse cleanly' \
  || fail 'control-lib dsh rows regressed'

# --- template arm static contract -------------------------------------------
dsh_arm=$(sed -n '/^    dsh) printf/,/;;$/p' "$ROOT/bin/fm-spawn.sh" | head -5)
for token in '--profile headless' '__DSHLAUNCH__' '__DSHHOME__' '__DSHENVPREFIX__' '__OPINPUT__ encode launch-brief < __BRIEF__' 'DSH_PERMISSION_MODE=danger-full-access'; do
  assert_contains "$dsh_arm" "$token" "template arm carries $token"
done
assert_not_contains "$dsh_arm" '__MODELFLAG__' 'template arm emits no model flag'
assert_not_contains "$dsh_arm" '__EFFORTFLAG__' 'template arm emits no effort flag'

pass 'fm-dsh-harness suite complete'
