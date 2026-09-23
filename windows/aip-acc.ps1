# aip acc - switch Codex / Claude Code SUBSCRIPTION logins by snapshot (Windows / PowerShell)
#
# Offline only: never talks to the network, never logs in and never refreshes
# tokens itself. Logins are always done by the official `codex` / `claude`
# CLIs; aip only moves their saved credentials between a local vault and the
# live location, so the servers see nothing but the official CLIs.
#
# Live login locations (the default config dirs):
#   Codex       %USERPROFILE%\.codex\auth.json   (requires cli_auth_credentials_store = "file")
#   Claude Code "claudeAiOauth" in %USERPROFILE%\.claude\.credentials.json
#               plus "oauthAccount" in %USERPROFILE%\.claude.json
#               (other keys, e.g. MCP logins "mcpOAuth", are left untouched)
# Vault: $env:AIP_ROOT\accounts\<tool>\<name>\  - secret.dat is DPAPI-encrypted
#        (only your Windows user on this PC can decrypt it); meta.json = email/ids.
#
# Loaded by aip.ps1; use it as:  aip acc <command> ...

$script:AccVault = Join-Path $env:AIP_ROOT 'accounts'
$script:AccIsWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
# test-only: the test suite points this at a sandbox folder ($HOME is read-only in PowerShell)
$script:AccHome = if ($env:AIP_TEST_HOME) { $env:AIP_TEST_HOME } else { $HOME }
$script:AccP = @{
    codex_auth   = Join-Path (Join-Path $script:AccHome '.codex') 'auth.json'
    codex_config = Join-Path (Join-Path $script:AccHome '.codex') 'config.toml'
    claude_cred  = Join-Path (Join-Path $script:AccHome '.claude') '.credentials.json'
    claude_state = Join-Path $script:AccHome '.claude.json'
}
$script:AccUtf8 = New-Object System.Text.UTF8Encoding $false

function script:AccFail([string]$m) { throw [System.Exception]::new("aip: $m") }
function script:AccWarn([string]$m) { Write-Host "aip: warning: $m" -ForegroundColor Yellow }

function script:AccRead([string]$p) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    return [IO.File]::ReadAllText($p)
}

function script:AccWrite([string]$p, [string]$content) {
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = Join-Path $dir ('.aip-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($tmp, $content, $script:AccUtf8)
    try { Move-Item -LiteralPath $tmp -Destination $p -Force -ErrorAction Stop }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; AccFail "cannot replace ${p}: $_" }
}

# ------------------------------------------------ minimal JSON text surgery
# Edits one top-level key and leaves every other byte of the file untouched.
function script:AccWs([string]$t, [int]$i) {
    while ($i -lt $t.Length -and [char]::IsWhiteSpace($t[$i])) { $i++ }
    return $i
}

function script:AccStrEnd([string]$t, [int]$i) {
    $j = $i + 1
    $stop = [char[]]@([char]34, [char]92)          # "  \
    while ($true) {
        $k = $t.IndexOfAny($stop, $j)
        if ($k -lt 0) { AccFail 'malformed JSON (string)' }
        if ($t[$k] -eq [char]92) { $j = $k + 2; continue }
        return $k + 1
    }
}

function script:AccValEnd([string]$t, [int]$i) {
    $c = $t[$i]
    if ($c -eq [char]34) { return (AccStrEnd $t $i) }
    if ($c -eq [char]'{' -or $c -eq [char]'[') {
        $d = 0; $j = $i
        $stop = [char[]]@([char]34, [char]'{', [char]'}', [char]'[', [char]']')
        while ($true) {
            $k = $t.IndexOfAny($stop, $j)
            if ($k -lt 0) { AccFail 'malformed JSON (unterminated)' }
            $ch = $t[$k]
            if ($ch -eq [char]34) { $j = AccStrEnd $t $k; continue }
            if ($ch -eq [char]'{' -or $ch -eq [char]'[') { $d++ } else { $d--; if ($d -eq 0) { return $k + 1 } }
            $j = $k + 1
        }
    }
    $j = $i
    while ($j -lt $t.Length -and (",}] `t`r`n").IndexOf($t[$j]) -lt 0) { $j++ }
    if ($j -eq $i) { AccFail 'malformed JSON (value)' }
    return $j
}

function script:AccKeySpan([string]$t, [string]$key) {
    $i = AccWs $t 0
    if ($i -ge $t.Length -or $t[$i] -ne [char]'{') { AccFail 'not a JSON object' }
    $i++
    while ($true) {
        $i = AccWs $t $i
        if ($i -ge $t.Length) { AccFail 'malformed JSON (object)' }
        $c = $t[$i]
        if ($c -eq [char]'}') { return $null }
        if ($c -eq [char]',') { $i++; continue }
        if ($c -ne [char]34) { AccFail 'malformed JSON (key)' }
        $ks = $i
        $ke = AccStrEnd $t $i
        $rawKey = $t.Substring($ks + 1, $ke - $ks - 2)
        $name = if ($rawKey.Contains('\')) { ('"' + $rawKey + '"') | ConvertFrom-Json } else { $rawKey }
        $i = AccWs $t $ke
        if ($t[$i] -ne [char]':') { AccFail 'malformed JSON (colon)' }
        $vs = AccWs $t ($i + 1)
        $ve = AccValEnd $t $vs
        if ($name -ceq $key) { return @{ k = $ks; vs = $vs; ve = $ve } }
        $i = $ve
    }
}

function script:AccGetRaw([string]$t, [string]$key) {
    if ([string]::IsNullOrWhiteSpace($t)) { return $null }
    $s = AccKeySpan $t $key
    if (-not $s) { return $null }
    $raw = $t.Substring($s.vs, $s.ve - $s.vs)
    if ($raw -eq 'null') { return $null }
    return $raw
}

function script:AccSetRaw([string]$t, [string]$key, [string]$raw) {
    if ([string]::IsNullOrWhiteSpace($t)) { $t = '{}' }
    $s = AccKeySpan $t $key
    if ($s) { return $t.Substring(0, $s.vs) + $raw + $t.Substring($s.ve) }
    $i = AccWs $t 0
    $j = AccWs $t ($i + 1)
    $ins = '"' + $key + '": ' + $raw
    if ($t[$j] -eq [char]'}') { $add = $ins } else { $add = "`n  " + $ins + ',' }
    return $t.Substring(0, $i + 1) + $add + $t.Substring($i + 1)
}

function script:AccDelKey([string]$t, [string]$key) {
    if ([string]::IsNullOrWhiteSpace($t)) { return $t }
    $s = AccKeySpan $t $key
    if (-not $s) { return $t }
    $end = AccWs $t $s.ve
    if ($end -lt $t.Length -and $t[$end] -eq [char]',') {
        $end = AccWs $t ($end + 1)
        return $t.Substring(0, $s.k) + $t.Substring($end)
    }
    $before = $t.Substring(0, $s.k) -replace ',\s*$', ''
    return $before + $t.Substring($s.ve)
}

# ------------------------------------------------------- vault (DPAPI)
function script:AccProtect([string]$s) {
    if ($script:AccIsWindows -and $env:AIP_DPAPI -ne '0') {
        $ss = ConvertTo-SecureString -String $s -AsPlainText -Force
        return 'dpapi:' + (ConvertFrom-SecureString -SecureString $ss)
    }
    return 'plain:' + $s
}

function script:AccUnprotect([string]$s) {
    if ($s.StartsWith('dpapi:')) {
        $ss = ConvertTo-SecureString -String $s.Substring(6)
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
    if ($s.StartsWith('plain:')) { return $s.Substring(6) }
    AccFail 'unknown vault format'
}

function script:AccVDir([string]$tool, [string]$name) { return (Join-Path (Join-Path $script:AccVault $tool) $name) }

function script:AccVaultPut([string]$tool, [string]$name, $live) {
    $d = AccVDir $tool $name
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    AccWrite (Join-Path $d 'secret.dat') (AccProtect $live.secret)
    if ($tool -eq 'claude' -and $live.acct_raw) { AccWrite (Join-Path $d 'oauthAccount.json') $live.acct_raw }
    $meta = [ordered]@{ tool = $tool; id = $live.id; email = $live.email; label = $live.label; saved_at = (Get-Date).ToString('s') }
    AccWrite (Join-Path $d 'meta.json') ($meta | ConvertTo-Json)
}

function script:AccMeta([string]$tool, [string]$name) {
    $m = AccRead (Join-Path (AccVDir $tool $name) 'meta.json')
    if (-not $m) { return $null }
    try { return ($m | ConvertFrom-Json) } catch { return $null }
}

function script:AccVaultGet([string]$tool, [string]$name) {
    $d = AccVDir $tool $name
    $meta = AccMeta $tool $name
    $enc = AccRead (Join-Path $d 'secret.dat')
    if (-not $meta -or -not $enc) { return $null }
    return @{ meta = $meta; secret = (AccUnprotect $enc); acct_raw = (AccRead (Join-Path $d 'oauthAccount.json')) }
}

function script:AccVaultList([string]$tool) {
    $base = Join-Path $script:AccVault $tool
    if (-not (Test-Path -LiteralPath $base)) { return @() }
    $out = @()
    foreach ($dir in (Get-ChildItem -LiteralPath $base -Directory | Sort-Object Name)) {
        if (-not (AccValidName $dir.Name)) { continue }
        $m = AccMeta $tool $dir.Name
        if ($m) { $out += [pscustomobject]@{ name = $dir.Name; id = $m.id; email = $m.email; label = $m.label } }
    }
    return $out
}

function script:AccFindId([string]$tool, $id) {
    if (-not $id) { return $null }
    foreach ($a in (AccVaultList $tool)) { if ($a.id -ceq $id) { return $a.name } }
    return $null
}

# ------------------------------------------------------------ identities
function script:AccJwtPayload([string]$jwt) {
    $p = $jwt.Split('.')
    if ($p.Count -lt 2) { return $null }
    $b = $p[1].Replace('-', '+').Replace('_', '/')
    switch ($b.Length % 4) { 2 { $b += '==' } 3 { $b += '=' } }
    try { return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b)) | ConvertFrom-Json) } catch { return $null }
}

function script:AccCodexId($o) {
    $t = $o.tokens
    if (-not $t) { return $null }
    $p = AccJwtPayload ([string]$t.id_token)
    $auth = if ($p) { $p.'https://api.openai.com/auth' } else { $null }
    $acct = [string]$t.account_id
    if (-not $acct -and $auth) { $acct = [string]$auth.chatgpt_account_id }
    $email = if ($p) { [string]$p.email } else { '' }
    if (-not $acct -and -not $email) { return $null }
    $label = if ($auth) { [string]$auth.chatgpt_plan_type } else { '' }
    if (-not $email) { $email = '(unknown email)' }
    return @{ id = "$($p.email)|$acct"; email = $email; label = $label }
}

function script:AccClaudeId([string]$raw) {
    if (-not $raw) { return $null }
    try { $o = $raw | ConvertFrom-Json } catch { return $null }
    $email = [string]$o.emailAddress; $uuid = [string]$o.accountUuid; $org = [string]$o.organizationUuid
    if (-not $email -and -not $uuid) { return $null }
    $shown = if ($email) { $email } else { '(unknown email)' }
    return @{ id = "$email|$uuid|$org"; email = $shown; label = [string]$o.organizationName }
}

# ---------------------------------------------------------- live logins
function script:AccLive([string]$tool) {
    if ($tool -eq 'codex') {
        $text = AccRead $script:AccP.codex_auth
        if ([string]::IsNullOrWhiteSpace($text)) { return @{ in = $false } }
        try { $o = $text | ConvertFrom-Json } catch { AccFail '~\.codex\auth.json is not valid JSON' }
        $id = AccCodexId $o
        if (-not $id -and $o.OPENAI_API_KEY) { return @{ in = $false; apikey = $true } }
        $r = @{ in = [bool]$o.tokens; secret = $text }
        if ($id) { $r.id = $id.id; $r.email = $id.email; $r.label = $id.label }
        return $r
    }
    $r = @{ in = $false }
    $r.file_text = AccRead $script:AccP.claude_cred
    $r.secret = AccGetRaw $r.file_text 'claudeAiOauth'
    $r.in = [bool]$r.secret
    $r.state_text = AccRead $script:AccP.claude_state
    $r.acct_raw = AccGetRaw $r.state_text 'oauthAccount'
    if ($r.in) {
        $ci = AccClaudeId $r.acct_raw
        if ($ci) { $r.id = $ci.id; $r.email = $ci.email; $r.label = $ci.label }
    }
    return $r
}

function script:AccWriteLive([string]$tool, [string]$secret, [string]$acctRaw) {
    if ($tool -eq 'codex') { AccWrite $script:AccP.codex_auth $secret; return }
    $l = AccLive 'claude'
    AccWrite $script:AccP.claude_cred (AccSetRaw $l.file_text 'claudeAiOauth' $secret)
    if ($acctRaw) { AccWrite $script:AccP.claude_state (AccSetRaw $l.state_text 'oauthAccount' $acctRaw) }
}

# Local logout for adding a new account: removes tokens locally, NO revoke.
function script:AccClearLive([string]$tool) {
    if ($tool -eq 'codex') {
        if (Test-Path -LiteralPath $script:AccP.codex_auth) { Remove-Item -LiteralPath $script:AccP.codex_auth -Force }
        return
    }
    $l = AccLive 'claude'
    if ($l.secret) { AccWrite $script:AccP.claude_cred (AccDelKey $l.file_text 'claudeAiOauth') }
}

# ------------------------------------------------------------- safety checks
function script:AccCheckTool([string]$t) { if ($t -ne 'codex' -and $t -ne 'claude') { AccFail "tool must be 'codex' or 'claude' (got: '$t')" } }
# Names become folder names: allow emails, block '..', leading '.' and path separators.
function script:AccValidName([string]$n) { return ($n -cmatch '^[A-Za-z0-9_][A-Za-z0-9._@+-]{0,99}$') -and -not $n.Contains('..') }
function script:AccCheckName([string]$n) {
    if (-not (AccValidName $n)) { AccFail "profile name may use letters, digits and . _ - @ + (e.g. an email), must not start with '.' or contain '..' (got: '$n')" }
    if ($n -eq 'default') { AccFail "'default' is reserved" }
}

function script:AccSamePath([string]$a, [string]$b) {
    try { $a = [IO.Path]::GetFullPath($a).TrimEnd('\', '/'); $b = [IO.Path]::GetFullPath($b).TrimEnd('\', '/') } catch { }
    return [string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)
}

function script:AccCheckEnv([string]$tool) {
    if ($tool -eq 'codex') {
        if ($env:CODEX_HOME -and -not (AccSamePath $env:CODEX_HOME (Join-Path $script:AccHome '.codex'))) {
            AccFail "CODEX_HOME is set to $env:CODEX_HOME. 'aip acc' manages the default login; run 'aip use codex default' first."
        }
        $cfg = AccRead $script:AccP.codex_config
        if ($cfg -and $cfg -match '(?m)^\s*cli_auth_credentials_store\s*=\s*"(\w+)"' -and $Matches[1] -ne 'file') {
            AccFail "config.toml sets cli_auth_credentials_store = `"$($Matches[1])`", so tokens are not in auth.json. Set it to `"file`" and run 'codex login' again."
        }
    } else {
        if ($env:CLAUDE_CONFIG_DIR -and -not (AccSamePath $env:CLAUDE_CONFIG_DIR (Join-Path $script:AccHome '.claude'))) {
            AccFail "CLAUDE_CONFIG_DIR is set to $env:CLAUDE_CONFIG_DIR. 'aip acc' manages the default login; run 'aip use claude default' first."
        }
        foreach ($v in 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN') {
            if ([Environment]::GetEnvironmentVariable($v, 'Process')) { AccWarn "`$env:$v is set - Claude Code will use it instead of the subscription login." }
        }
    }
}

function script:AccRunning([string]$tool) {
    $hits = @()
    $filter = $env:AIP_TEST_PROC_FILTER   # test-only: limit detection to sandbox processes
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.Id -eq $PID) { continue }
        if ($filter -and -not ([string]$p.Path).Contains($filter)) { continue }
        $n = $p.ProcessName
        $hit = if ($tool -eq 'codex') { $n -match '^codex(-[\w.-]+)?$' } else { $n -eq 'claude' }
        if ($hit) { $hits += ('  pid {0,-7} {1}' -f $p.Id, $n) }
    }
    # npm installs run under node.exe: look at command lines (Windows)
    try {
        $pat = if ($tool -eq 'codex') { '@openai[\\/]codex' } else { '@anthropic-ai[\\/]claude-code' }
        Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -match $pat -and (-not $filter -or ([string]$_.CommandLine).Contains($filter)) } |
            ForEach-Object { $hits += ('  pid {0,-7} {1}' -f $_.ProcessId, $_.CommandLine) }
    } catch { }
    return , $hits
}

function script:AccEnsureClosed([string]$tool, [bool]$force) {
    $p = AccRunning $tool
    if ($p.Count -eq 0) { return }
    Write-Host "Running $tool processes:"; $p | ForEach-Object { Write-Host $_ }
    if ($force) { AccWarn 'continuing because of --force'; return }
    if ($tool -eq 'claude') {
        AccFail ("Close every Claude Code session (terminal, IDE plugins) and the Claude desktop app first.`n" +
                 "     A running session can overwrite the new login with the old account's tokens.`n" +
                 "     (--force skips this check; not recommended.)")
    }
    Write-Host 'Running Codex sessions keep the old account until restarted; they will not overwrite the new login.'
    $a = Read-Host 'Continue? [y/N]'
    if ($a -notin 'y', 'Y', 'yes') { AccFail 'Cancelled' }
}

function script:AccSnapshot([string]$tool, [string]$name, $live) { AccVaultPut $tool $name $live }

# Save the current live login into its matching vault entry before touching it.
function script:AccBackfill([string]$tool) {
    $l = AccLive $tool
    if (-not $l.in) { return $null }
    if (-not $l.id) { AccFail "Cannot identify the current $tool login." }
    $cur = AccFindId $tool $l.id
    if (-not $cur) { AccFail "The current $tool login ($($l.email)) is not saved yet, so switching would lose it.`n     Save it first:  aip acc save $tool <name>" }
    AccSnapshot $tool $cur $l
    return $cur
}

# ---------------------------------------------------------------- commands
function script:AccSave([string]$tool, [string]$name, [bool]$force) {
    AccCheckTool $tool; AccCheckName $name; AccCheckEnv $tool
    $l = AccLive $tool
    if ($l.apikey) { AccFail "Codex is logged in with an API key; 'aip acc' is for ChatGPT subscription logins." }
    if (-not $l.in) { AccFail "No $tool login found. Log in first ($(if ($tool -eq 'codex') { 'codex login' } else { 'claude, then /login' }))." }
    if (-not $l.id) { AccFail "Cannot identify the current $tool login." }
    $dup = AccFindId $tool $l.id
    if ($dup -and $dup -ne $name) { AccFail "$($l.email) is already saved as '$dup'. Use: aip acc save $tool $dup" }
    $m = AccMeta $tool $name
    if ($m -and $m.id -cne $l.id -and -not $force) { AccFail "'$tool/$name' holds another account ($($m.email)). Pick another name or add --force." }
    AccSnapshot $tool $name $l
    Write-Host "Saved $tool/$name  <$($l.email)>"
}

function script:AccUse([string]$tool, [string]$name, [bool]$force) {
    AccCheckTool $tool; AccCheckName $name; AccCheckEnv $tool
    $t = AccVaultGet $tool $name
    if (-not $t) { AccFail "No saved account '$tool/$name'. See: aip acc ls" }
    AccEnsureClosed $tool $force
    $cur = AccBackfill $tool
    if ($cur -eq $name) { Write-Host "$tool is already using '$name' <$($t.meta.email)> (tokens re-saved)."; return }
    if ($cur) { Write-Host "Saved latest tokens of '$cur'." }
    AccWriteLive $tool $t.secret $t.acct_raw
    $after = AccLive $tool
    if ($after.id -cne $t.meta.id) {
        if ($cur) { $b = AccVaultGet $tool $cur; AccWriteLive $tool $b.secret $b.acct_raw }
        AccFail "Verification failed after writing '$name'; the previous login was restored."
    }
    Write-Host "Switched $tool -> '$name' <$($t.meta.email)>."
    Write-Host "Restart running $tool sessions (terminal, IDE plugin, desktop app) to use it."
}

function script:AccAdd([string]$tool, [string]$name, [bool]$force) {
    AccCheckTool $tool; AccCheckName $name; AccCheckEnv $tool
    if (Test-Path -LiteralPath (AccVDir $tool $name)) { AccFail "'$tool/$name' already exists. Use a new name, or: aip acc save $tool $name" }
    $exe = Get-Command $tool -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $exe) { AccFail "'$tool' not found in PATH" }
    AccEnsureClosed $tool $force
    $prev = AccBackfill $tool
    if ($prev) { Write-Host "Saved current login as '$prev'." }
    AccClearLive $tool
    Write-Host 'Log in with the NEW account now (the old one stays saved; nothing is revoked).'
    Write-Host 'Tip: if the browser auto-selects your old account, sign out there or use a private window.'
    if ($tool -eq 'codex') { & $exe.Source login }
    else { Write-Host 'Claude Code is starting: complete the login (type /login if not prompted), then /exit.'; & $exe.Source }
    $l = AccLive $tool
    if (-not $l.in -or -not $l.id) {
        if ($prev) { $b = AccVaultGet $tool $prev; AccWriteLive $tool $b.secret $b.acct_raw; AccWarn "No new login detected - restored '$prev'." }
        AccFail "No new $tool login detected."
    }
    $dup = AccFindId $tool $l.id
    if ($dup) { AccSnapshot $tool $dup $l; AccFail "You logged into $($l.email), which is already saved as '$dup' (now active). Nothing added." }
    AccSnapshot $tool $name $l
    Write-Host "Added $tool/$name  <$($l.email)>  (now active)"
}

function script:AccLs([string[]]$tools) {
    if (-not $tools -or $tools.Count -eq 0) { $tools = @('codex', 'claude') }
    foreach ($tool in $tools) {
        AccCheckTool $tool
        try { $l = AccLive $tool } catch { $l = @{ in = $false } }
        Write-Host "${tool}:"
        $list = @(AccVaultList $tool)
        $matched = $false
        foreach ($a in $list) {
            $on = $l.in -and ($l.id -ceq $a.id)
            if ($on) { $matched = $true }
            $mark = if ($on) { '*' } else { ' ' }
            $lab = if ($a.label) { "  ($($a.label))" } else { '' }
            Write-Host ('  {0} {1,-14} {2}{3}' -f $mark, $a.name, $a.email, $lab)
        }
        if ($list.Count -eq 0) { Write-Host '    (no saved accounts)' }
        if ($l.in -and -not $matched) { Write-Host "    live login $($l.email) is not saved -> aip acc save $tool <name>" }
        if (-not $l.in) { Write-Host '    not logged in' }
    }
}

function script:AccRm([string]$tool, [string]$name) {
    AccCheckTool $tool; AccCheckName $name
    $d = AccVDir $tool $name
    if (-not (Test-Path -LiteralPath $d)) { AccFail "No saved account '$tool/$name'" }
    $m = AccMeta $tool $name
    Write-Host "This forgets the saved copy of $tool/$name <$($m.email)>. Tokens are not revoked."
    $ans = Read-Host 'Delete? [y/N]'
    if ($ans -notin 'y', 'Y', 'yes') { Write-Host 'Cancelled'; return }
    Remove-Item -LiteralPath $d -Recurse -Force
    Write-Host "Deleted $tool/$name"
}

function script:AccHelp {
@'
aip acc - switch Codex / Claude Code subscription logins (offline, official CLIs only)

  aip acc ls [codex|claude]            list saved accounts (* = live login)
  aip acc save <tool> <name>           save the account that is logged in now
  aip acc add  <tool> <name>           log in another account with the official CLI and save it
  aip acc use  <tool> <name>           switch the live login to a saved account
  aip acc rm   <tool> <name>           forget a saved account (does not revoke)

Options: --force  skip the running-session check (not recommended for claude)

First time:   aip acc save codex work        (you are logged in as work)
              aip acc add  codex personal    (logs in personal, keeps work)
Switch:       aip acc use  codex work
'@ | Write-Host
}

function Invoke-AipAcc {
    $all = @($args | ForEach-Object { [string]$_ })
    $force = ($all -contains '--force') -or ($all -contains '-f')
    $a = @($all | Where-Object { $_ -ne '--force' -and $_ -ne '-f' })
    $cmd = if ($a.Count -ge 1) { $a[0] } else { 'ls' }
    $tool = if ($a.Count -ge 2) { $a[1] } else { '' }
    $name = if ($a.Count -ge 3) { $a[2] } else { '' }

    if (-not (Test-Path -LiteralPath $script:AccVault)) {
        New-Item -ItemType Directory -Path $script:AccVault -Force | Out-Null
        if (Get-Command Protect-AipDir -ErrorAction SilentlyContinue) { Protect-AipDir $env:AIP_ROOT }
    }
    $lock = $null
    try {
        try { $lock = [IO.File]::Open((Join-Path $script:AccVault '.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
        catch { AccFail "another 'aip acc' is running" }
        switch ($cmd) {
            { $_ -in 'ls', 'list' }     { AccLs @($a | Select-Object -Skip 1) }
            'save'                      { AccSave $tool $name $force }
            { $_ -in 'use', 'switch' }  { AccUse $tool $name $force }
            'add'                       { AccAdd $tool $name $force }
            { $_ -in 'rm', 'remove' }   { AccRm $tool $name }
            { $_ -in 'help', '-h', '--help' } { AccHelp }
            default { AccFail "unknown command '$cmd' (see: aip acc help)" }
        }
    } catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    } finally {
        if ($lock) { $lock.Dispose() }
    }
}
