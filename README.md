# aip - AI Profile switcher (Codex CLI + Claude Code CLI)

Two ways to use several **subscription** accounts. Both are offline: aip never
talks to the network, never logs in and never refreshes tokens itself. Logins
are always done by the official `codex` / `claude` CLIs.

| Mode | How | Best for |
|---|---|---|
| **Env mode** `aip use` | Each account has its own config dir (`CODEX_HOME`, `CLAUDE_CONFIG_DIR`) | Terminals, several accounts at the same time |
| **Snapshot mode** `aip acc` | Swaps the *default* login (`~/.codex`, `~/.claude`) | IDE plugins / apps that can't take env vars |

## Test first (no install needed)
Runs everything in a temporary sandbox with fake `codex` / `claude` / Keychain commands.
Your real logins, `~/.codex`, `~/.claude` and Keychain are never touched.

- macOS / Linux: `bash tests/macos/run-tests.sh`   (add `--keep` to inspect the sandbox)
- Windows: double-click `tests\windows\run-tests.cmd`

Expected: `Result: N passed, 0 failed`. The suite aborts if it cannot guarantee it only
reaches the fakes.

## Install
Everything lives in one folder in your home directory:
```
~/.aip/
  bin/        the scripts (aip.sh + aip-acc  |  aip.ps1 + aip-acc.ps1)
  codex/      env-mode profiles      claude/  env-mode profiles
  accounts/   snapshot-mode vault (secrets in Keychain on macOS, DPAPI on Windows)
```
**macOS / Linux**: `cd macos && bash install.sh`, then open a new terminal.
Needs `perl` with JSON::PP for `aip acc` (ships with macOS).

**Windows**: double-click `windows\install.cmd`, then open a NEW PowerShell window.

The installer adds one line to `~/.zshrc` (or your PowerShell profile). Upgrading from the
old layout (`~/.ai-profiles`, `~/.aip.sh`, `~/aip.ps1`) is automatic: data is moved into
`~/.aip` and the old files and hook line are removed.

Uninstall: `bash install.sh --uninstall` / `install.cmd -Uninstall` removes `~/.aip/bin`
and the hook; your profiles and saved accounts in `~/.aip` are kept.

## Snapshot mode: `aip acc`
```
aip acc save codex work        # you are logged in as "work" now: save it
aip acc add  codex personal    # logs in another account via `codex login`, keeps "work"
aip acc use  codex work        # switch (restart Codex sessions / IDE plugin afterwards)
aip acc ls                     # * marks the live login
aip acc rm   codex personal    # forget a saved copy (does not revoke)
```
Same for `claude` (`add` starts `claude`; complete `/login`, then `/exit`).

What gets swapped:
- **Codex**: `~/.codex/auth.json` (needs `cli_auth_credentials_store = "file"`, the default).
- **Claude Code**: only `claudeAiOauth` in the macOS Keychain item `Claude Code-credentials`
  and/or `~/.claude/.credentials.json`, plus `oauthAccount` in `~/.claude.json`.
  Everything else (MCP logins, projects, settings) is left byte-for-byte untouched.

Safety built in:
- Before every switch, the live tokens are saved back to their account, so rotated
  refresh tokens are never lost.
- Refuses to switch away from a login that isn't saved, or one it can't identify.
- Claude: refuses while any Claude Code session or the Claude desktop app is running
  (a running session could overwrite the new login). Codex: asks first.
- Verifies the result and restores the previous login if something went wrong.
- Vault: macOS Keychain items `aip-<tool>-<name>`; Windows DPAPI-encrypted files;
  Linux files 0600. Folders 0700 / user-only ACL.

## Env mode: `aip use`
```
aip add  <codex|claude> <name> [--share]   create profile + log in
aip use  <codex|claude> <name>             use in current terminal ("default" = reset)
aip run  <codex|claude> <name> [args]      run once with a profile
aip ls | aip rm <tool> <name> | aip prompt
```

## Rules that keep accounts safe
- Only your own accounts. Never share one account between people.
- Don't rotate accounts to get around usage limits, and don't automate switching.
- For a team, use Business/Team/Enterprise seats or API keys.
