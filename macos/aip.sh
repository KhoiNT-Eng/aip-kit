# aip — AI Profile switcher for Codex CLI & Claude Code CLI
#
# Source this file from ~/.zshrc or ~/.bashrc:
#     source ~/.aip/bin/aip.sh
#
# How it works:
#   Each account lives in its own config directory. `aip` only sets the
#   officially supported environment variables:
#     Codex       -> CODEX_HOME          (credentials: <dir>/auth.json or OS keyring)
#     Claude Code -> CLAUDE_CONFIG_DIR   (credentials: macOS Keychain entry keyed
#                                         to the dir, or <dir>/.credentials.json)
#   It never reads, copies, exports or transmits any token.
#
# Everything lives in:  ${AIP_ROOT:-~/.aip}   (bin/, <tool>/<name> profiles, accounts/)

AIP_ROOT="${AIP_ROOT:-$HOME/.aip}"

# Files/dirs that are safe to share between profiles (NEVER credentials).
_AIP_SHARE_CODEX="config.toml AGENTS.md prompts"
_AIP_SHARE_CLAUDE="settings.json CLAUDE.md commands agents skills"

_aip_var() {
  case "$1" in
    codex)  echo "CODEX_HOME" ;;
    claude) echo "CLAUDE_CONFIG_DIR" ;;
    *) return 1 ;;
  esac
}

_aip_default_dir() {
  case "$1" in
    codex)  echo "$HOME/.codex" ;;
    claude) echo "$HOME/.claude" ;;
  esac
}

_aip_check_tool() {
  case "$1" in
    codex|claude) return 0 ;;
    *) echo "aip: tool must be 'codex' or 'claude' (got: '$1')" >&2; return 1 ;;
  esac
}

_aip_check_name() {
  case "$1" in
    ''|[!A-Za-z0-9_]*|*[!A-Za-z0-9._@+-]*|*..*)
      echo "aip: profile name may use letters, digits and . _ - @ + (e.g. an email), must not start with '.' or contain '..' (got: '$1')" >&2
      return 1 ;;
  esac
}

_aip_dir() { echo "$AIP_ROOT/$1/$2"; }

# Current profile name for a tool ("default" if unset, "custom" if pointing elsewhere)
_aip_current() {
  local var val
  var=$(_aip_var "$1")
  eval "val=\${$var:-}"
  if [ -z "$val" ]; then
    echo "default"
  else
    case "$val" in
      "$AIP_ROOT/$1/"*) echo "${val#"$AIP_ROOT/$1/"}" ;;
      *) echo "custom($val)" ;;
    esac
  fi
}

# Warn about env vars that override the profile's login.
_aip_warn_overrides() {
  local v
  if [ "$1" = "claude" ]; then
    for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
      if eval "[ -n \"\${$v:-}\" ]"; then
        echo "aip: warning: \$$v is set — Claude Code will use it instead of the profile's login." >&2
      fi
    done
  fi
}

_aip_share() {
  local tool="$1" dir="$2" src item items
  src=$(_aip_default_dir "$tool")
  if [ "$tool" = "codex" ]; then items="$_AIP_SHARE_CODEX"; else items="$_AIP_SHARE_CLAUDE"; fi
  for item in $(echo "$items"); do
    if [ -e "$src/$item" ] && [ ! -e "$dir/$item" ]; then
      ln -s "$src/$item" "$dir/$item" && echo "  linked $item -> $src/$item"
    fi
  done
}

_aip_login() {
  local tool="$1" dir="$2"
  if [ "$tool" = "codex" ]; then
    CODEX_HOME="$dir" command codex login
  else
    echo "Claude Code will open; complete the login (run /login if not prompted), then /exit."
    CLAUDE_CONFIG_DIR="$dir" command claude
  fi
}

_aip_help() {
  cat <<'EOF'
aip — switch Codex / Claude Code CLI accounts via official config-dir env vars

Usage:
  aip                                 Show active profile for each tool
  aip ls                              List all profiles
  aip add  <codex|claude> <name> [--share]
                                      Create profile + log in
                                      --share: symlink config (not credentials)
                                      from ~/.codex or ~/.claude
  aip use  <codex|claude> <name>      Use profile in THIS shell ("default" = reset)
  aip run  <codex|claude> <name> [args...]
                                      Run once with a profile (shell unchanged)
  aip login <codex|claude> <name>     Re-login an existing profile
  aip rm   <codex|claude> <name>      Delete a profile (log out first!)
  aip prompt                          Short status string for your shell prompt

Snapshot mode (switches the DEFAULT login, so IDEs/plugins follow it too):
  aip acc ls                          List saved subscription accounts (* = live)
  aip acc save <codex|claude> <name>  Save the account that is logged in now
  aip acc add  <codex|claude> <name>  Log in another account (official CLI) and save it
  aip acc use  <codex|claude> <name>  Switch the live login (close sessions first)
  aip acc rm   <codex|claude> <name>  Forget a saved account

Examples:
  aip add codex work --share
  aip add claude personal
  aip use codex work && codex
  aip run claude personal -p "hello"
EOF
}

aip() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift

  case "$cmd" in
    ""|status|current)
      echo "codex : $(_aip_current codex)"
      echo "claude: $(_aip_current claude)"
      ;;

    ls|list)
      local tool cur name
      for tool in codex claude; do
        cur=$(_aip_current "$tool")
        echo "$tool:"
        if [ "$cur" = "default" ]; then echo "  * default"; else echo "    default"; fi
        for name in $(command ls -1 "$AIP_ROOT/$tool" 2>/dev/null); do
          [ -d "$AIP_ROOT/$tool/$name" ] || continue
          if [ "$name" = "$cur" ]; then echo "  * $name"; else echo "    $name"; fi
        done
      done
      ;;

    add)
      local tool="${1:-}" name="${2:-}" share="${3:-}" dir
      _aip_check_tool "$tool" && _aip_check_name "$name" || return 1
      if [ "$name" = "default" ]; then echo "aip: 'default' is reserved" >&2; return 1; fi
      command -v "$tool" >/dev/null 2>&1 || { echo "aip: '$tool' not found in PATH" >&2; return 1; }
      dir=$(_aip_dir "$tool" "$name")
      if [ -e "$dir" ]; then echo "aip: profile '$tool/$name' already exists" >&2; return 1; fi
      ( umask 077 && mkdir -p "$dir" ) || return 1
      chmod 700 "$AIP_ROOT" "$AIP_ROOT/$tool" "$dir" 2>/dev/null
      echo "Created $dir"
      [ "$share" = "--share" ] && _aip_share "$tool" "$dir"
      _aip_warn_overrides "$tool"
      _aip_login "$tool" "$dir"
      ;;

    use)
      local tool="${1:-}" name="${2:-}" var dir
      _aip_check_tool "$tool" || return 1
      var=$(_aip_var "$tool")
      if [ "$name" = "default" ]; then
        unset "$var"
        echo "$tool -> default ($(_aip_default_dir "$tool"))"
        return 0
      fi
      _aip_check_name "$name" || return 1
      dir=$(_aip_dir "$tool" "$name")
      [ -d "$dir" ] || { echo "aip: no profile '$tool/$name' (create with: aip add $tool $name)" >&2; return 1; }
      export "$var=$dir"
      echo "$tool -> $name"
      _aip_warn_overrides "$tool"
      ;;

    run)
      local tool="${1:-}" name="${2:-}" var dir
      _aip_check_tool "$tool" || return 1
      [ $# -ge 2 ] && shift 2 || shift $#
      if [ "$name" = "default" ]; then
        ( var=$(_aip_var "$tool"); unset "$var"; command "$tool" "$@" )
        return
      fi
      _aip_check_name "$name" || return 1
      dir=$(_aip_dir "$tool" "$name")
      [ -d "$dir" ] || { echo "aip: no profile '$tool/$name'" >&2; return 1; }
      _aip_warn_overrides "$tool"
      if [ "$tool" = "codex" ]; then
        CODEX_HOME="$dir" command codex "$@"
      else
        CLAUDE_CONFIG_DIR="$dir" command claude "$@"
      fi
      ;;

    login)
      local tool="${1:-}" name="${2:-}" dir
      _aip_check_tool "$tool" && _aip_check_name "$name" || return 1
      dir=$(_aip_dir "$tool" "$name")
      [ -d "$dir" ] || { echo "aip: no profile '$tool/$name'" >&2; return 1; }
      _aip_login "$tool" "$dir"
      ;;

    rm|remove)
      local tool="${1:-}" name="${2:-}" dir ans
      _aip_check_tool "$tool" && _aip_check_name "$name" || return 1
      dir=$(_aip_dir "$tool" "$name")
      [ -d "$dir" ] || { echo "aip: no profile '$tool/$name'" >&2; return 1; }
      echo "This deletes $dir."
      echo "Log out FIRST so the token is revoked (and the macOS Keychain entry removed):"
      if [ "$tool" = "codex" ]; then
        echo "    aip run codex $name logout"
      else
        echo "    aip run claude $name   then type /logout"
      fi
      printf "Delete now? [y/N] "
      read -r ans
      case "$ans" in
        y|Y|yes)
          [ "$(_aip_current "$tool")" = "$name" ] && unset "$(_aip_var "$tool")"
          rm -rf -- "$dir" && echo "Deleted $tool/$name"
          ;;
        *) echo "Cancelled" ;;
      esac
      ;;

    prompt)
      local c k out=""
      c=$(_aip_current codex); k=$(_aip_current claude)
      [ "$c" != "default" ] && out="cx:$c"
      [ "$k" != "default" ] && out="${out:+$out }cc:$k"
      [ -n "$out" ] && printf '[%s]' "$out"
      ;;

    acc)
      local helper="${AIP_ACC:-$HOME/.aip/bin/aip-acc}"
      [ -f "$helper" ] || { echo "aip: $helper not found (re-run install.sh)" >&2; return 1; }
      AIP_ROOT="$AIP_ROOT" command perl "$helper" "$@"
      ;;

    -h|--help|help)
      _aip_help
      ;;

    *)
      echo "aip: unknown command '$cmd'" >&2
      _aip_help >&2
      return 1
      ;;
  esac
}
