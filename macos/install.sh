#!/usr/bin/env bash
# Installer for aip (macOS / Linux). Everything goes into ~/.aip:
#   ~/.aip/bin/        aip.sh, aip-acc (the scripts)
#   ~/.aip/codex|claude/<name>   env-mode profiles
#   ~/.aip/accounts/   snapshot-mode vault
#
#   bash install.sh              install / update (also migrates the old layout)
#   bash install.sh --uninstall  remove the scripts and shell hook (your data in ~/.aip is kept)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AIP="$HOME/.aip"
BIN="$AIP/bin"
MARK="# aip (AI profile switcher)"
LINE='[ -f "$HOME/.aip/bin/aip.sh" ] && source "$HOME/.aip/bin/aip.sh"'
OLD_LINE='[ -f "$HOME/.aip.sh" ] && source "$HOME/.aip.sh"'
OLD_ROOT="$HOME/.ai-profiles"

# Shell rc files to hook into
rcs=()
{ [ -f "$HOME/.zshrc" ] || [ "$(basename "${SHELL:-}")" = "zsh" ]; } && rcs+=("$HOME/.zshrc")
if [ "$(basename "${SHELL:-}")" = "bash" ] || [ -f "$HOME/.bashrc" ] || [ -f "$HOME/.bash_profile" ]; then
  if [ "$(uname)" = "Darwin" ]; then rcs+=("$HOME/.bash_profile"); else rcs+=("$HOME/.bashrc"); fi
fi
[ ${#rcs[@]} -eq 0 ] && rcs+=("$HOME/.zshrc")

# Remove our hook lines (old and new) from an rc file, keeping everything else.
unhook() {
  local rc="$1" tmp
  [ -f "$rc" ] || return 0
  grep -qF -e "$MARK" -e "$LINE" -e "$OLD_LINE" "$rc" || return 0
  tmp="$(mktemp)"
  grep -vF -e "$MARK" -e "$LINE" -e "$OLD_LINE" "$rc" > "$tmp" || true
  # drop trailing blank lines left from our block
  perl -0pe 's/\n+\z/\n/; s/\A\n\z//' "$tmp" > "$rc"; rm -f "$tmp"
  return 1   # "changed"
}

if [ "${1:-}" = "--uninstall" ]; then
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    unhook "$rc" || echo "Removed hook from $rc"
  done
  rm -rf "$BIN" "$HOME/.aip.sh" "$HOME/.aip-acc"
  echo "Removed $BIN"
  echo "Your profiles and saved accounts in $AIP were kept. Delete that folder yourself if you no longer need them"
  echo "(log out of each account first; on macOS also remove Keychain items named 'aip-codex-*' / 'aip-claude-*')."
  exit 0
fi

[ -f "$HERE/aip.sh" ] && [ -f "$HERE/aip-acc" ] || { echo "aip.sh / aip-acc not found next to install.sh" >&2; exit 1; }
if ! /usr/bin/env perl -MJSON::PP -MMIME::Base64 -e 1 2>/dev/null; then
  echo "Warning: perl with JSON::PP is required for 'aip acc' (it ships with macOS)." >&2
fi

( umask 077; mkdir -p "$BIN" )
chmod 700 "$AIP" "$BIN"

# ---- migrate the previous layout (~/.ai-profiles, ~/.aip.sh, ~/.aip-acc)
if [ -d "$OLD_ROOT" ]; then
  for item in codex claude accounts; do
    [ -e "$OLD_ROOT/$item" ] || continue
    if [ -e "$AIP/$item" ]; then
      echo "Note: $AIP/$item already exists; left $OLD_ROOT/$item in place (merge it by hand)."
    else
      mv "$OLD_ROOT/$item" "$AIP/$item" && echo "Moved $OLD_ROOT/$item -> $AIP/$item"
    fi
  done
  rm -f "$OLD_ROOT/accounts/.lock" 2>/dev/null || true
  rmdir "$OLD_ROOT" 2>/dev/null && echo "Removed empty $OLD_ROOT" || true
fi
rm -f "$HOME/.aip.sh" "$HOME/.aip-acc"

install -m 0644 "$HERE/aip.sh" "$BIN/aip.sh"
install -m 0700 "$HERE/aip-acc" "$BIN/aip-acc"
echo "Installed $BIN/aip.sh and $BIN/aip-acc"

for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do unhook "$rc" || true; done
for rc in "${rcs[@]}"; do
  touch "$rc"
  printf '\n%s\n%s\n' "$MARK" "$LINE" >> "$rc"
  echo "Hooked into $rc"
done

for t in codex claude; do
  command -v "$t" >/dev/null 2>&1 || echo "Note: '$t' not found in PATH (install it before 'aip add $t ...')."
done

cat <<EOF

Done. Open a NEW terminal (old ones may still point at the previous paths), then:
  aip acc save codex work        # snapshot mode (works with IDEs)
  aip add codex work --share     # env mode (per terminal)
  aip help
EOF
