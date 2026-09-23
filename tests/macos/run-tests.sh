#!/bin/bash
# aip test suite (macOS / Linux) - run BEFORE installing:   bash tests/macos/run-tests.sh
#
# Everything runs inside a throw-away folder: HOME points there and codex,
# claude and the macOS `security` (Keychain) command are fake stand-ins.
# Your real ~/.codex, ~/.claude, Keychain and accounts are never touched.
# Options: --keep  keep the sandbox folder for inspection

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"
ACC="$KIT/macos/aip-acc"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1

T="$(mktemp -d "${TMPDIR:-/tmp}/aip-test.XXXXXX")" || exit 1
cleanup() { pkill -f "$T/fake/" 2>/dev/null; [ $KEEP = 1 ] && echo "Sandbox kept: $T" || rm -rf "$T"; }
trap cleanup EXIT

chmod +x "$HERE"/mock/* "$ACC"
export HOME="$T/home" USER="aiptest" AIP_ROOT="$T/home/.aip" AIP_TEST_PROC_FILTER="$T"
export PATH="$HERE/mock:$PATH"
unset CODEX_HOME CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN FAKE_KC AIP_KEYCHAIN
mkdir -p "$HOME/.claude" "$T/fake"

# ---- safety: make sure only the fakes can be reached
for c in codex claude security; do
  if [ "$(command -v $c)" != "$HERE/mock/$c" ]; then echo "ABORT: '$c' does not resolve to the test mock"; exit 2; fi
done
case "$HOME" in "$T"/*) ;; *) echo "ABORT: HOME is not the sandbox"; exit 2;; esac
perl -MJSON::PP -MMIME::Base64 -e 1 2>/dev/null || { echo "ABORT: perl with JSON::PP is required"; exit 2; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "output did not contain [$3]: $(printf '%s' "$2" | head -3)";; esac; }
acc() { perl "$ACC" "$@" 2>&1; }
perm() { if stat -f %Lp "$1" >/dev/null 2>&1; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
fakeproc() { cp /bin/sleep "$T/fake/$1"; "$T/fake/$1" 30 & sleep 0.5; }
killfake() { pkill -f "$T/fake/$1" 2>/dev/null; sleep 0.2; }
strip_oauth() { perl -0pe 's/"oauthAccount"\s*:\s*\{[^{}]*\}//s' "$1"; }

echo "aip tests  (sandbox: $T)"
echo "== Codex"
FAKE_EMAIL=a@x.com FAKE_ACCT=wsA codex login >/dev/null
out=$(acc save codex work);                                   has "save current login" "$out" "Saved codex/work"
out=$(FAKE_EMAIL=b@x.com FAKE_ACCT=wsB acc add codex personal); has "add second account via official login" "$out" "Added codex/personal"
out=$(acc ls codex);                                          has "ls marks live account" "$out" "* personal"
acc use codex work >/dev/null;                                eq  "switch to work" "$(codex whoami)" "wsA rt-a@x.com-1"
codex rotate >/dev/null; codex rotate >/dev/null
acc use codex personal >/dev/null;                            eq  "switch to personal" "$(codex whoami)" "wsB rt-b@x.com-1"
acc use codex work >/dev/null;                                eq  "rotated token of work was saved back (no stale token)" "$(codex whoami)" "wsA rt-a@x.com-3"
FAKE_EMAIL=c@x.com FAKE_ACCT=wsC codex login >/dev/null
out=$(acc use codex personal);                                has "refuses to switch away from an unsaved login" "$out" "is not saved yet"
eq  "unsaved login left untouched" "$(codex whoami)" "wsC rt-c@x.com-1"
out=$(acc save codex work);                                   has "refuses to overwrite another account's name" "$out" "holds another account"
acc save codex third >/dev/null; acc use codex work >/dev/null
out=$(FAKE_EMAIL=d@x.com FAKE_ACCT=wsD acc add codex khoint.danang@gmail.com); has "email address accepted as account name" "$out" "Added codex/khoint.danang@gmail.com"
acc use codex khoint.danang@gmail.com >/dev/null;           eq  "switch using an email name" "$(codex whoami)" "wsD rt-d@x.com-1"
out=$(acc save codex ../evil);                              has "path-like names still rejected" "$out" "must not start with"
acc use codex work >/dev/null
out=$(FAKE_LOGIN_FAIL=1 acc add codex fourth);                has "failed login restores previous account" "$out" "restored 'work'"
eq  "live login after failed add" "$(codex whoami)" "wsA rt-a@x.com-3"
out=$(FAKE_EMAIL=b@x.com FAKE_ACCT=wsB acc add codex dupe);   has "detects login into an already-saved account" "$out" "already saved as 'personal'"
acc use codex work >/dev/null
printf 'cli_auth_credentials_store = "keyring"\n' > "$HOME/.codex/config.toml"
out=$(acc use codex personal);                                has "refuses keyring credential store" "$out" "cli_auth_credentials_store"
rm -f "$HOME/.codex/config.toml"
out=$(CODEX_HOME=/tmp/elsewhere acc use codex personal);      has "refuses when CODEX_HOME is set" "$out" "CODEX_HOME is set"
fakeproc codex
out=$(echo n | acc use codex personal);                       has "warns about running codex and asks" "$out" "Continue?"
eq  "answering 'n' keeps the live login" "$(codex whoami)" "wsA rt-a@x.com-3"
killfake codex
eq  "vault folder is private (700)" "$(perm "$AIP_ROOT/accounts/codex/work")" "700"
eq  "live auth.json stays private (600)" "$(perm "$HOME/.codex/auth.json")" "600"

run_claude_suite() {
  local mode="$1"
  echo "== Claude Code ($mode)"
  rm -rf "$HOME/.claude" "$HOME/.claude.json" "$AIP_ROOT/accounts/claude" "$HOME/.fake-keychain.json"; mkdir -p "$HOME/.claude"
  if [ "$mode" = keychain ]; then export AIP_KEYCHAIN=1 FAKE_KC=1; else export AIP_KEYCHAIN=0; unset FAKE_KC; fi
  FAKE_EMAIL=a@x.com claude >/dev/null 2>&1
  # add an MCP login next to the Claude login, like real use
  if [ "$mode" = keychain ]; then
    S=$(security find-generic-password -s 'Claude Code-credentials' -w)
    S=$(perl -MJSON::PP -e '$d=decode_json($ARGV[0]); $d->{mcpOAuth}={srv=>{accessToken=>"mcp-secret"}}; print encode_json($d)' "$S")
    security add-generic-password -U -a "$USER" -s 'Claude Code-credentials' -w "$S"
  else
    perl -MJSON::PP -i -0pe '$d=decode_json($_); $d->{mcpOAuth}={srv=>{accessToken=>"mcp-secret"}}; $_=encode_json($d)' "$HOME/.claude/.credentials.json"
  fi
  out=$(acc save claude work);                                has "save current login" "$out" "Saved claude/work"
  out=$(FAKE_EMAIL=b@x.com acc add claude personal);          has "add second account via official login" "$out" "Added claude/personal"
  claude rotate >/dev/null; claude rotate >/dev/null
  # rich, pretty ~/.claude.json to prove only oauthAccount is edited
  perl -MJSON::PP -e 'my $f="$ENV{HOME}/.claude.json"; my $d=decode_json(do{local(@ARGV,$/)=$f;<>});
     $d->{projects}={"/work/app"=>{history=>[{display=>"quote \" brace { bracket [ oauthAccount"}]}}; $d->{numStartups}=42;
     open my $o,">",$f; print $o JSON::PP->new->pretty->canonical->encode($d);'
  cp "$HOME/.claude.json" "$T/before.json"
  acc use claude work >/dev/null;                             eq  "switch to work" "$(claude whoami)" "a@x.com sk-ant-ort-a@x.com-1"
  if diff -q <(strip_oauth "$T/before.json") <(strip_oauth "$HOME/.claude.json") >/dev/null; then ok "~/.claude.json unchanged outside oauthAccount"; else bad "~/.claude.json unchanged outside oauthAccount"; fi
  claude rotate >/dev/null
  acc use claude personal >/dev/null;                         eq  "rotated token of personal was saved back" "$(claude whoami)" "b@x.com sk-ant-ort-b@x.com-3"
  acc use claude work >/dev/null;                             eq  "rotated token of work was saved back" "$(claude whoami)" "a@x.com sk-ant-ort-a@x.com-2"
  if [ "$mode" = keychain ]; then store=$(security find-generic-password -s 'Claude Code-credentials' -w); else store=$(cat "$HOME/.claude/.credentials.json"); fi
  has "MCP logins (mcpOAuth) preserved" "$store" "mcp-secret"
  if [ "$mode" = keychain ]; then
    has "vault secrets stored in Keychain" "$(cat "$HOME/.fake-keychain.json")" "aip-claude-personal"
    [ -e "$AIP_ROOT/accounts/claude/work/secret.json" ] && bad "no plaintext token file in vault" || ok "no plaintext token file in vault"
  fi
  fakeproc claude
  out=$(acc use claude personal);                             has "refuses while a Claude session is running" "$out" "Close every Claude Code session"
  eq  "live login untouched after refusal" "$(claude whoami)" "a@x.com sk-ant-ort-a@x.com-2"
  killfake claude
  unset AIP_KEYCHAIN FAKE_KC
}
run_claude_suite file
run_claude_suite keychain

echo "== Env mode (aip.sh)"
out=$(bash -c "source '$KIT/macos/aip.sh'; FAKE_EMAIL=e@x.com FAKE_ACCT=wsE aip add codex envtest >/dev/null; aip use codex envtest >/dev/null; echo \$CODEX_HOME; CODEX_HOME=\$CODEX_HOME codex whoami" 2>&1)
has "aip add/use sets CODEX_HOME to the profile" "$out" "$AIP_ROOT/codex/envtest"
out=$(bash -c "source '$KIT/macos/aip.sh'; FAKE_EMAIL=f@x.com FAKE_ACCT=wsF aip add codex me@mail.com >/dev/null; aip use codex me@mail.com; aip use codex ../x" 2>&1)
has "env mode accepts an email name" "$out" "codex -> me@mail.com"
has "env mode rejects path-like names" "$out" "must not start with"

echo "== Installer (old layout -> ~/.aip, in the sandbox)"
H2="$T/insthome"; mkdir -p "$H2/.ai-profiles/codex/oldprof" "$H2/.ai-profiles/accounts/codex/work"
echo '{"tokens":{}}' > "$H2/.ai-profiles/codex/oldprof/auth.json"
printf '{"tool":"codex","id":"a@x.com|wsA","email":"a@x.com","store":"file"}' > "$H2/.ai-profiles/accounts/codex/work/meta.json"
echo '{}' > "$H2/.ai-profiles/accounts/codex/work/secret.json"
echo old > "$H2/.aip.sh"; echo old > "$H2/.aip-acc"
printf 'export FOO=1\n\n# aip (AI profile switcher)\n[ -f "$HOME/.aip.sh" ] && source "$HOME/.aip.sh"\n' > "$H2/.zshrc"
inst() { env -u AIP_ROOT HOME="$H2" SHELL=/bin/zsh bash "$KIT/macos/install.sh" "$@" 2>&1; }
out=$(inst)
has "installer moves old profiles into ~/.aip" "$out" "Moved $H2/.ai-profiles/codex"
[ -f "$H2/.aip/codex/oldprof/auth.json" ] && [ ! -e "$H2/.ai-profiles" ] && ok "old folder emptied and removed" || bad "old folder emptied and removed"
[ ! -e "$H2/.aip.sh" ] && [ ! -e "$H2/.aip-acc" ] && ok "old files in home folder removed" || bad "old files in home folder removed"
eq  "scripts installed in ~/.aip/bin (helper 700)" "$(perm "$H2/.aip/bin/aip-acc")" "700"
eq  "~/.aip is private (700)" "$(perm "$H2/.aip")" "700"
inst >/dev/null
eq  "shell hook present exactly once after re-install" "$(grep -c '.aip/bin/aip.sh' "$H2/.zshrc")" "1"
eq  "old hook line removed" "$(grep -c 'HOME/.aip.sh' "$H2/.zshrc")" "0"
has "user's own .zshrc lines kept" "$(cat "$H2/.zshrc")" "export FOO=1"
out=$(env -u AIP_ROOT HOME="$H2" AIP_KEYCHAIN=0 bash -c 'source "$HOME/.aip/bin/aip.sh"; aip ls; aip acc ls codex' 2>&1)
has "installed aip finds migrated env profiles" "$out" "oldprof"
has "installed aip acc finds migrated saved accounts" "$out" "work           a@x.com"
out=$(inst --uninstall)
[ ! -e "$H2/.aip/bin" ] && [ -f "$H2/.aip/codex/oldprof/auth.json" ] && ok "uninstall removes scripts, keeps data" || bad "uninstall removes scripts, keeps data"
eq  "uninstall removes the hook" "$(grep -c 'aip' "$H2/.zshrc")" "0"

echo
echo "Result: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
