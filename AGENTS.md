# AGENTS.md - aip (AI Profile switcher for Codex CLI + Claude Code CLI)

Guide for AI coding agents (Codex, Claude Code, ...) working in this repo.
User-facing docs: [README.md](README.md).

## Goal
Use several **subscription** accounts (ChatGPT for Codex, Claude Pro/Max/Team for
Claude Code) on one machine, macOS and Windows, from the terminal and from IDE plugins
(e.g. JetBrains `jetbrains-cc-gui`) that spawn the `codex` / `claude` CLIs.

## Hard constraints (never break)
- No network. Never call OpenAI/Anthropic APIs, never log in or refresh tokens.
- Only move credentials the **official CLIs** wrote. Logins happen only via
  `codex login` / `claude` -> `/login`.
- No account sharing, no auto-rotation to dodge limits.
- Rejected tools (don't reintroduce their ideas): `Lampese/codex-switcher`
  (fake encryption, unauthenticated web server, client impersonation),
  `cc-switch-cli` (OAuth proxy impersonating Codex, plaintext token DB, calls
  Anthropic usage API, can't switch Claude subscriptions).

## Git rules
- **Never commit, amend, push, tag or rebase on your own.** Only when the owner asks
  explicitly in the current request. Approval of a design or a fix is not approval to commit.
- When done, leave changes uncommitted and report what changed (`git status` / `git diff --stat`).
- Don't stage or revert changes you didn't make (the owner may have local edits).

## Verified facts the design relies on
**Codex** (`openai/codex` @ `30fc686`):
- `cli_auth_credentials_store` default `file` -> `CODEX_HOME/auth.json`. `keyring`/`auto`
  = tokens in OS keyring, file swap does nothing -> aip refuses.
- `auth.json` is loaded once; running sessions must be restarted. A guarded reload refuses
  to refresh if the on-disk `account_id` changed (no overwrite).
- Refresh tokens rotate; reuse = forced re-login -> **backfill before every switch**.
- Identity = `email|account_id` (Team members share `account_id`).
- **Browser login (`codex login`) revokes the previously logged-in session** (verified
  2026-09-24, codex 0.156.1): the older account then fails with
  `workspace routing discovery unauthorized (401)` / `token_revoked` /
  `refresh_token_invalidated`. aip therefore always runs `codex login --device-auth`.
  Diagnose a saved login without touching `~/.codex`: copy it into a temp `CODEX_HOME`
  and send `initialize` + `account/read` to `codex app-server` over stdio.

**Claude Code** (closed source; docs + GitHub issues):
- macOS token: Keychain service `Claude Code-credentials` (suffix `-<sha256(dir)[:8]>`
  with `CLAUDE_CONFIG_DIR`), JSON `{claudeAiOauth, mcpOAuth}`; fallback
  `~/.claude/.credentials.json`. Linux/Windows: file only.
- Identity: `~/.claude.json` top-level `oauthAccount`; swap together with the token.
- Refresh tokens single-use; reuse revokes the family. Running sessions / Claude Desktop
  may write stale tokens back -> **refuse Claude switch while any claude process runs**.

## Layout
```
macos/    aip.sh (sourced fn, bash 3.2 + zsh)  aip-acc (Perl, JSON::PP)  install.sh
windows/  aip.ps1 (PS 5.1 + 7)  aip-acc.ps1 (dot-sourced)  install.ps1  install.cmd
tests/macos/    run-tests.sh + mock/{codex,claude,security}
tests/windows/  run-tests.ps1 + run-tests.cmd + mock/{codex.ps1,claude.ps1}
```
Installed: `~/.aip/{bin,codex/<n>,claude/<n>,accounts/<tool>/<n>,accounts/.lock}`
(root overridable with `AIP_ROOT`).

## Two modes
- **Env mode** (`aip add|use|run|login|rm|ls|prompt`): sets `CODEX_HOME` /
  `CLAUDE_CONFIG_DIR` only. `--share` links config, never credentials.
- **Snapshot mode** (`aip acc ls|save|add|use|rm`): swaps the default login.
  - Codex: whole `~/.codex/auth.json`.
  - Claude: only `claudeAiOauth` (every store that holds it) + `oauthAccount` in
    `~/.claude.json`, via JSON text surgery on one top-level key. All other bytes untouched.
  - Vault: macOS Keychain `aip-<tool>-<name>`; Linux `secret.json` 0600; Windows DPAPI.
  - `use`: env check -> process guard -> backfill -> write -> verify -> restore on mismatch.
  - `add`: backfill -> local clear (no revoke) -> official login -> save.
  - Hints for an unsaved live login print a ready-to-copy `aip acc save <tool> <name>`;
    the name is the displayed email, sanitized to a valid name (`suggest_name` /
    `AccSuggestName`).
  - Names `^[A-Za-z0-9_][A-Za-z0-9._@+-]{0,99}$`, no `..`, `default` reserved.

## Test-only hooks (keep; test use only)
`AIP_TEST_PROC_FILTER`, `AIP_TEST_HOME` (PS), `AIP_KEYCHAIN=0|1` (Perl),
`AIP_DPAPI=0` (PS), `install.ps1 -TestHome <dir>`. Mocks refuse to run outside the
suites; suites abort if `codex`/`claude`/`security` don't resolve to the mocks.

## Commands
```bash
bash tests/macos/run-tests.sh [--keep]               # expect 62 passed, 0 failed
pwsh -NoProfile -File tests/windows/run-tests.ps1 [-Keep]   # expect 49 passed
perl -c macos/aip-acc && bash -n macos/aip.sh macos/install.sh
LC_ALL=C grep -n '[^[:print:][:space:]]' windows/*.ps1 tests/windows/*.ps1  # must print nothing
```
Run the relevant suite after every change. A feature change needs a test; a safety
change should make an existing test fail when reverted.

## Conventions
- Code, comments, CLI messages: English. `.ps1` files: **ASCII only** (PS 5.1 reads
  BOM-less files as ANSI).
- Shell must work in bash 3.2 **and** zsh; Perl uses core modules only.
- PowerShell must work in 5.1 **and** 7.

## Gotchas already hit
- PS: function `Rd` is shadowed by alias `rd`; aliases win over functions.
- PS: `Invoke-X @($args | ...)` doesn't splat; assign to a variable, then `@var`.
- PS: `$HOME` is read-only (hence `AIP_TEST_HOME`). Use nested `Join-Path`, not `'a\b'`.
- PS runner: `$ErrorActionPreference='Stop'`; an aborted run counts as failure.
- bash: `echo y | aip ...` runs `aip` in a subshell; use here-strings in tests.
- macOS: a **copied** `/bin/sleep` is killed (`Killed: 9`, code signature); fake
  processes in tests use a symlink instead.
- Test regex typos look like product bugs; inspect the real file before "fixing" code.

## Status / open items
- macOS suite: 62/62 on real macOS (2026-09-24). Windows suite: last green run was 43/43
  on pwsh 7.5 on Linux; the 6 tests added for `--device-auth` / save hints have not run
  yet (no pwsh on the Mac). Untested on Windows PS 5.1 / real DPAPI / junctions.
- Real Codex snapshot switching used on macOS (2026-09-24). Claude `/login` not yet.
- Ideas not built (ask the owner first): `aip init` + per-project PATH shim,
  `aip wrap` wrappers for IDE CLI paths, pre-switch backup ring (deliberately skipped).
