# DSH

DSH (DeepSeek Harness) — disposable-runtime CLI (`apps/cli/lib/bin.js`). Verified 2026-08-26 on DSH Linux headless.

## Operating facts

| Fact | Value |
|---|---|
| Binary | No global install. `fm_dsh_resolve_launch()` (`../../../bin/fm-dsh-lib.sh`) resolves from operator config: `<node-abs> <runtime-root>/apps/cli/lib/bin.js` when `config/dsh-runtime-root` exists, else one self-contained launcher from `config/dsh-executable`. Any invalid input refuses before endpoint creation. |
| Config inputs | `config/dsh-executable`, `config/dsh-runtime-root` (presence selects pair form), `config/dsh-home` (becomes `DSH_HOME`), optional `config/dsh-env`: operator-owned 0600 `KEY=VALUE` child-env file. |
| Launch | Encoded brief as positional prompt, `--profile headless`, plus env `DSH_PERMISSION_MODE=danger-full-access` (autonomy control: without it Linux sandbox mounts everything read-only and headless has no escalation channel, so report/status writes block forever — observed live 2026-08-26) and `DSH_TELEMETRY_DISABLED=1`. |
| Model/provider | NOT CLI axes. Owned by `$DSH_HOME/settings.yaml`: `agent-default-model` plus provider block under `llm-pi-ai.providers` (`apiKeyEnv: NVIDIA_API_KEY`); model must be DECLARED in provider block or boot fails `UNKNOWN_MODEL`. Requested `--model`/`--effort` recorded in task meta, never emitted as flags. |
| Busy/liveness | Process-backed v1: tmux classification `fm_dsh_process_matches` recognizes configured runtime's `bin.js` in path/argv[0]; unrelated bare `node` stays `other->ambiguous`. Headless panes render blank during inference — blank is NOT dead/stale. |
| Completion | One-shot: worker exits after final answer; appends keyed FirstMate status lines itself (proven twice in qualification plus E2E), so `done:`/`failed:` wakes arrive normally. |
| Exit | REFUSED (`../../../bin/fm-control-lib.sh` `fm_control_exit_command` returns nonzero): headless has no composer and no verified key surfaces. |
| Interrupt | REFUSED (`fm_control_interrupt_key` returns nonzero): same. |
| Skill invocation | Natural language (no separate verified form); use `../../../bin/fm-send.sh` with encoded brief like other headless. |
| Kind scope | Crewmate + scout only; secondmate refused via `fm_control_harness_supports_kind` (muse precedent). |
| Resume | Not implemented. `dsh --profile tui --resume <session>` exists for future v2. |

## Safe env loader

Credential delivery via `../../../bin/fm-dsh-env-exec.sh` safe `KEY=VALUE` loader — never sources/evals `config/dsh-env`. Loader:

* validates env file is regular, readable, owner-only perms (group/other must be 0, mode 600/400)
* rejects non-empty lines not matching `^[A-Za-z_][A-Za-z0-9_]*=`
* treats value as byte-literal remainder after first `=`; command substitutions, backticks, globs, quotes, spaces, semicolons, additional `=` remain literal via quoted `export "$key=$value"`
* cites line numbers on error, never values
* fails closed on perms/missing/unreadable (exit 77/66/65/64)
* `exec "$@"` so values reach only the DSH child, never parent shell/argv/meta/status/report

`../../../bin/fm-dsh-lib.sh` gates: `fm_dsh_config_dir` test seam `FM_DSH_CONFIG_DIR`, `fm_dsh_resolve_launch` structural node-pair vs launcher selection via `config/dsh-runtime-root` existence, `fm_dsh_require_abs_path` silent validator, `fm_dsh_resolve_env_prefix` mode `^[0-7]?[0-7]00$` and line-format gate citing numbers only, `fm_dsh_process_matches` containment. `config/dsh-runtime-root` as a file whose line is the absolute runtime-root; directory/empty/relative/malformed at that path REFUSES, never silently switches mode. No eval, no source/dot of operator files.

Values never appear in argv, meta, status, reports, logs, or test output.

## Quirk

NIM account function bindings can vanish while `/v1/models` still lists the id (404 `"Specified function ... is not found"`); repair is operator-side model rotation in `settings.yaml` — declare replacement under provider block AND point `agent-default-model` at it. Observed 2026-08-26 rotating `deepseek-v4-flash-0731` → `moonshotai/kimi-k3`.

## Verification

`../../../tests/fm-dsh-harness.test.sh` covers refusal paths, quoted pair emission, launcher form, home validation, env-prefix mode/line gates citing numbers not values, credential non-leakage, process-matcher, control-table refusals, template contract (headless flag, placeholders, autonomy env, no model/effort flags), and byte-literal loader injection marker absent.
