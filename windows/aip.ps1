# aip - AI Profile switcher for Codex CLI & Claude Code CLI (Windows / PowerShell)
#
# Works with Windows PowerShell 5.1 and PowerShell 7+.
# Load it from your PowerShell profile:
#     notepad $PROFILE        # add the line below, save, restart PowerShell
#     . "$HOME\.aip\bin\aip.ps1"
#
# How it works:
#   Each account lives in its own config directory. `aip` only sets the
#   officially supported environment variables for the current PowerShell session:
#     Codex       -> CODEX_HOME          (credentials: <dir>\auth.json or Windows Credential Manager)
#     Claude Code -> CLAUDE_CONFIG_DIR   (credentials: <dir>\.credentials.json)
#   It never reads, copies, exports or transmits any token.
#
# Everything lives in:  $env:AIP_ROOT  (default: $HOME\.aip)  - bin\, <tool>\<name> profiles, accounts\

if (-not $env:AIP_ROOT) { $env:AIP_ROOT = Join-Path $HOME '.aip' }

$script:AipVars    = @{ codex = 'CODEX_HOME'; claude = 'CLAUDE_CONFIG_DIR' }
$script:AipDefault = @{ codex = (Join-Path $HOME '.codex'); claude = (Join-Path $HOME '.claude') }
# Files/dirs that are safe to share between profiles (NEVER credentials).
$script:AipShare   = @{
    codex  = @('config.toml', 'AGENTS.md', 'prompts')
    claude = @('settings.json', 'CLAUDE.md', 'commands', 'agents', 'skills')
}

function script:Test-AipTool([string]$Tool) {
    if ($script:AipVars.ContainsKey($Tool)) { return $true }
    Write-Host "aip: tool must be 'codex' or 'claude' (got: '$Tool')" -ForegroundColor Red
    return $false
}

function script:Test-AipName([string]$Name) {
    if ($Name -match '^[A-Za-z0-9_][A-Za-z0-9._@+-]{0,99}$' -and -not $Name.Contains('..')) { return $true }
    Write-Host "aip: profile name may use letters, digits and . _ - @ + (e.g. an email), must not start with '.' or contain '..' (got: '$Name')" -ForegroundColor Red
    return $false
}

function script:Get-AipDir([string]$Tool, [string]$Name) {
    return (Join-Path (Join-Path $env:AIP_ROOT $Tool) $Name)
}

function script:Get-AipCurrent([string]$Tool) {
    $val = [Environment]::GetEnvironmentVariable($script:AipVars[$Tool], 'Process')
    if (-not $val) { return 'default' }
    $prefix = (Join-Path $env:AIP_ROOT $Tool) + [IO.Path]::DirectorySeparatorChar
    if ($val.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $val.Substring($prefix.Length)
    }
    return "custom($val)"
}

function script:Write-AipOverrideWarning([string]$Tool) {
    if ($Tool -ne 'claude') { return }
    foreach ($v in 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN') {
        if ([Environment]::GetEnvironmentVariable($v, 'Process')) {
            Write-Host "aip: warning: `$env:$v is set - Claude Code will use it instead of the profile's login." -ForegroundColor Yellow
        }
    }
}

# Restrict a directory to the current user (+ SYSTEM), no inherited ACEs.
function script:Protect-AipDir([string]$Path) {
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    if (-not $onWindows) { return }
    try {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls.exe $Path /inheritance:r /grant:r "*${sid}:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" | Out-Null
    } catch {
        Write-Host "aip: warning: could not tighten ACL on $Path ($_)" -ForegroundColor Yellow
    }
}

function script:Add-AipShareLinks([string]$Tool, [string]$Dir) {
    $src = $script:AipDefault[$Tool]
    foreach ($item in $script:AipShare[$Tool]) {
        $from = Join-Path $src $item
        $to   = Join-Path $Dir $item
        if (-not (Test-Path -LiteralPath $from) -or (Test-Path -LiteralPath $to)) { continue }
        $isDir = (Get-Item -LiteralPath $from).PSIsContainer
        try {
            New-Item -ItemType SymbolicLink -Path $to -Target $from -ErrorAction Stop | Out-Null
            Write-Host "  linked $item -> $from"
        } catch {
            if ($isDir) {
                # Junctions need no admin rights / Developer Mode.
                New-Item -ItemType Junction -Path $to -Target $from | Out-Null
                Write-Host "  junction $item -> $from"
            } else {
                Copy-Item -LiteralPath $from -Destination $to
                Write-Host "  copied $item (enable Windows Developer Mode for a live symlink)" -ForegroundColor Yellow
            }
        }
    }
}

# Run the real CLI with a given config dir, restoring the session env afterwards.
function script:Invoke-AipTool([string]$Tool, [string]$Dir, [object[]]$ToolArgs) {
    $var = $script:AipVars[$Tool]
    $old = [Environment]::GetEnvironmentVariable($var, 'Process')
    try {
        [Environment]::SetEnvironmentVariable($var, $Dir, 'Process')   # $null = unset
        $exe = Get-Command $Tool -CommandType Application, ExternalScript -ErrorAction Stop | Select-Object -First 1
        & $exe.Source @ToolArgs
    } finally {
        [Environment]::SetEnvironmentVariable($var, $old, 'Process')
    }
}

function script:Invoke-AipLogin([string]$Tool, [string]$Dir) {
    if ($Tool -eq 'codex') {
        # Device code login: the browser login flow revokes the previously logged-in session.
        Invoke-AipTool 'codex' $Dir @('login', '--device-auth')
    } else {
        Write-Host "Claude Code will open; complete the login (run /login if not prompted), then /exit."
        Invoke-AipTool 'claude' $Dir @()
    }
}

function script:Show-AipHelp {
@'
aip - switch Codex / Claude Code CLI accounts via official config-dir env vars

Usage:
  aip                                 Show active profile for each tool
  aip ls                              List all profiles
  aip add  <codex|claude> <name> [--share]
                                      Create profile + log in
                                      --share: link config (not credentials)
                                      from ~\.codex or ~\.claude
  aip use  <codex|claude> <name>      Use profile in THIS PowerShell window ("default" = reset)
  aip run  <codex|claude> <name> [args...]
                                      Run once with a profile (window unchanged)
  aip login <codex|claude> <name>     Re-login an existing profile
  aip rm   <codex|claude> <name>      Delete a profile (log out first!)
  aip prompt                          Short status string for your prompt

Snapshot mode (switches the DEFAULT login, so IDEs/plugins follow it too):
  aip acc ls                          List saved subscription accounts (* = live)
  aip acc save <codex|claude> <name>  Save the account that is logged in now
  aip acc add  <codex|claude> <name>  Log in another account (official CLI) and save it
  aip acc use  <codex|claude> <name>  Switch the live login (close sessions first)
  aip acc rm   <codex|claude> <name>  Forget a saved account

Examples:
  aip add codex work --share
  aip add claude personal
  aip use codex work; codex
  aip run claude personal -p "hello"
'@ | Write-Host
}

function aip {
    $cmd  = if ($args.Count -ge 1) { [string]$args[0] } else { '' }
    $tool = if ($args.Count -ge 2) { [string]$args[1] } else { '' }
    $name = if ($args.Count -ge 3) { [string]$args[2] } else { '' }
    $rest = if ($args.Count -ge 4) { @($args[3..($args.Count - 1)]) } else { @() }

    switch ($cmd) {
        { $_ -in '', 'status', 'current' } {
            Write-Host ("codex : " + (Get-AipCurrent 'codex'))
            Write-Host ("claude: " + (Get-AipCurrent 'claude'))
        }

        { $_ -in 'ls', 'list' } {
            foreach ($t in 'codex', 'claude') {
                $cur = Get-AipCurrent $t
                Write-Host "${t}:"
                if ($cur -eq 'default') { Write-Host '  * default' } else { Write-Host '    default' }
                $base = Join-Path $env:AIP_ROOT $t
                if (Test-Path -LiteralPath $base) {
                    Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name | ForEach-Object {
                        if ($_.Name -eq $cur) { Write-Host "  * $($_.Name)" } else { Write-Host "    $($_.Name)" }
                    }
                }
            }
        }

        'add' {
            if (-not (Test-AipTool $tool) -or -not (Test-AipName $name)) { return }
            if ($name -eq 'default') { Write-Host "aip: 'default' is reserved" -ForegroundColor Red; return }
            if (-not (Get-Command $tool -CommandType Application, ExternalScript -ErrorAction SilentlyContinue)) {
                Write-Host "aip: '$tool' not found in PATH" -ForegroundColor Red; return
            }
            $dir = Get-AipDir $tool $name
            if (Test-Path -LiteralPath $dir) { Write-Host "aip: profile '$tool/$name' already exists" -ForegroundColor Red; return }
            $rootExisted = Test-Path -LiteralPath $env:AIP_ROOT
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if (-not $rootExisted) { Protect-AipDir $env:AIP_ROOT }
            Write-Host "Created $dir"
            if ($rest -contains '--share') { Add-AipShareLinks $tool $dir }
            Write-AipOverrideWarning $tool
            Invoke-AipLogin $tool $dir
        }

        'use' {
            if (-not (Test-AipTool $tool)) { return }
            $var = $script:AipVars[$tool]
            if ($name -eq 'default') {
                [Environment]::SetEnvironmentVariable($var, $null, 'Process')
                Write-Host "$tool -> default ($($script:AipDefault[$tool]))"
                return
            }
            if (-not (Test-AipName $name)) { return }
            $dir = Get-AipDir $tool $name
            if (-not (Test-Path -LiteralPath $dir)) {
                Write-Host "aip: no profile '$tool/$name' (create with: aip add $tool $name)" -ForegroundColor Red; return
            }
            [Environment]::SetEnvironmentVariable($var, $dir, 'Process')
            Write-Host "$tool -> $name"
            Write-AipOverrideWarning $tool
        }

        'run' {
            if (-not (Test-AipTool $tool)) { return }
            if ($name -eq 'default') { Invoke-AipTool $tool $null $rest; return }
            if (-not (Test-AipName $name)) { return }
            $dir = Get-AipDir $tool $name
            if (-not (Test-Path -LiteralPath $dir)) { Write-Host "aip: no profile '$tool/$name'" -ForegroundColor Red; return }
            Write-AipOverrideWarning $tool
            Invoke-AipTool $tool $dir $rest
        }

        'login' {
            if (-not (Test-AipTool $tool) -or -not (Test-AipName $name)) { return }
            $dir = Get-AipDir $tool $name
            if (-not (Test-Path -LiteralPath $dir)) { Write-Host "aip: no profile '$tool/$name'" -ForegroundColor Red; return }
            Invoke-AipLogin $tool $dir
        }

        { $_ -in 'rm', 'remove' } {
            if (-not (Test-AipTool $tool) -or -not (Test-AipName $name)) { return }
            $dir = Get-AipDir $tool $name
            if (-not (Test-Path -LiteralPath $dir)) { Write-Host "aip: no profile '$tool/$name'" -ForegroundColor Red; return }
            Write-Host "This deletes $dir."
            Write-Host "Log out FIRST so the token is revoked:"
            if ($tool -eq 'codex') { Write-Host "    aip run codex $name logout" }
            else { Write-Host "    aip run claude $name   then type /logout" }
            $ans = Read-Host 'Delete now? [y/N]'
            if ($ans -in 'y', 'Y', 'yes') {
                if ((Get-AipCurrent $tool) -eq $name) {
                    [Environment]::SetEnvironmentVariable($script:AipVars[$tool], $null, 'Process')
                }
                # Remove links first so their targets (shared config) are never touched.
                Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.LinkType } | ForEach-Object {
                    if ($_.PSIsContainer) { [IO.Directory]::Delete($_.FullName) } else { [IO.File]::Delete($_.FullName) }
                }
                Remove-Item -LiteralPath $dir -Recurse -Force
                Write-Host "Deleted $tool/$name"
            } else {
                Write-Host 'Cancelled'
            }
        }

        'prompt' {
            $parts = @()
            $c = Get-AipCurrent 'codex';  if ($c -ne 'default') { $parts += "cx:$c" }
            $k = Get-AipCurrent 'claude'; if ($k -ne 'default') { $parts += "cc:$k" }
            if ($parts.Count) { return '[' + ($parts -join ' ') + ']' }
            return ''
        }

        'acc' {
            if (-not (Get-Command Invoke-AipAcc -ErrorAction SilentlyContinue)) {
                Write-Host "aip: aip-acc.ps1 not loaded (re-run install.cmd)" -ForegroundColor Red; return
            }
            $accArgs = @($args | Select-Object -Skip 1)
            Invoke-AipAcc @accArgs
        }

        { $_ -in '-h', '--help', 'help' } { Show-AipHelp }

        default {
            Write-Host "aip: unknown command '$cmd'" -ForegroundColor Red
            Show-AipHelp
        }
    }
}

# Tab completion: aip <cmd> <tool> <profile>
Register-ArgumentCompleter -CommandName aip -Native -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    $words = @($commandAst.CommandElements | ForEach-Object { $_.ToString() })
    $pos = $words.Count
    if ($wordToComplete) { $pos-- }
    $candidates = switch ($pos) {
        1 { 'ls', 'add', 'use', 'run', 'login', 'rm', 'prompt', 'acc', 'help' }
        2 { 'codex', 'claude' }
        3 {
            $base = Join-Path $env:AIP_ROOT $words[2]
            $names = @('default')
            if (Test-Path -LiteralPath $base) { $names += (Get-ChildItem -LiteralPath $base -Directory).Name }
            $names
        }
    }
    $candidates | Where-Object { $_ -like "$wordToComplete*" } |
        ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
}

# Snapshot mode (aip acc ...) lives in a separate file next to this one.
$script:AipAccFile = Join-Path $PSScriptRoot 'aip-acc.ps1'
if (Test-Path -LiteralPath $script:AipAccFile) { . $script:AipAccFile }
