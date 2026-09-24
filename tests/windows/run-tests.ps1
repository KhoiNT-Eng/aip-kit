# aip test suite (Windows) - run BEFORE installing: double-click tests\windows\run-tests.cmd
#
# Everything runs inside a throw-away folder and uses fake `codex` / `claude`
# commands. Your real %USERPROFILE%\.codex, .claude, .claude.json and accounts
# are never touched. Option: -Keep  keep the sandbox folder for inspection.
param([switch]$Keep)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
$Kit = (Resolve-Path (Join-Path (Join-Path $Here '..') '..')).Path
$OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$T = Join-Path ([IO.Path]::GetTempPath()) ('aip-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$SandHome = Join-Path $T 'home'
New-Item -ItemType Directory -Path (Join-Path $SandHome '.claude') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $T 'fake') -Force | Out-Null

$env:AIP_TEST_HOME = $SandHome
$env:AIP_ROOT = Join-Path $SandHome '.aip'
$env:AIP_TEST_PROC_FILTER = $T
$env:PATH = (Join-Path $Here 'mock') + [IO.Path]::PathSeparator + $env:PATH
foreach ($v in 'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'AIP_DPAPI', 'FAKE_LOGIN_FAIL') {
    Remove-Item "env:$v" -ErrorAction SilentlyContinue
}

# ---- safety: make sure only the fakes can be reached
foreach ($c in 'codex', 'claude') {
    $src = (Get-Command $c -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $src -or -not $src.StartsWith((Join-Path $Here 'mock'))) { Write-Host "ABORT: '$c' does not resolve to the test mock ($src)" -ForegroundColor Red; exit 2 }
}

. (Join-Path (Join-Path $Kit 'windows') 'aip.ps1')
if (-not (Get-Command Invoke-AipAcc -ErrorAction SilentlyContinue)) { Write-Host 'ABORT: aip-acc.ps1 did not load' -ForegroundColor Red; exit 2 }

$script:Pass = 0; $script:Fail = 0
function Ok([string]$n) { $script:Pass++; Write-Host "  PASS  $n" -ForegroundColor Green }
function Bad([string]$n, [string]$why) { $script:Fail++; Write-Host "  FAIL  $n" -ForegroundColor Red; if ($why) { Write-Host "        $why" } }
function Eq([string]$n, $got, $want) { if ("$got" -ceq "$want") { Ok $n } else { Bad $n "expected [$want] got [$got]" } }
function Has([string]$n, [string]$out, [string]$needle) { if ($out.Contains($needle)) { Ok $n } else { Bad $n "output did not contain [$needle]: $($out.Trim())" } }
function Acc { $a = $args; (aip acc @a *>&1 | Out-String) }
function global:Read-Host { param($Prompt) Write-Host $Prompt; return $global:AipTestAnswer }
function Start-Fake([string]$name) {
    if ($OnWindows) {
        $exe = Join-Path (Join-Path $T 'fake') "$name.exe"
        Copy-Item (Join-Path $env:WINDIR 'System32\PING.EXE') $exe
        return Start-Process -FilePath $exe -ArgumentList '-n', '30', '127.0.0.1' -WindowStyle Hidden -PassThru
    }
    $exe = Join-Path (Join-Path $T 'fake') $name
    Copy-Item '/bin/sleep' $exe
    return Start-Process -FilePath $exe -ArgumentList '30' -PassThru
}
function Strip-Oauth([string]$p) { [regex]::Replace([IO.File]::ReadAllText($p), '"oauthAccount"\s*:\s*\{[^{}]*\}', '') }

Write-Host "aip tests  (sandbox: $T)"
try {
    Write-Host '== Codex'
    $env:FAKE_EMAIL = 'a@x.com'; $env:FAKE_ACCT = 'wsA'; codex login | Out-Null
    Has 'save current login' (Acc save codex work) 'Saved codex/work'
    $env:FAKE_EMAIL = 'b@x.com'; $env:FAKE_ACCT = 'wsB'
    Has 'add second account via official login' (Acc add codex personal) 'Added codex/personal'
    Eq 'add logs in with --device-auth (browser login revokes the old session)' ([IO.File]::ReadAllText((Join-Path $env:AIP_TEST_HOME '.codex-login-args'))) 'login --device-auth'
    Has 'ls marks live account' (Acc ls codex) '* personal'
    Acc use codex work | Out-Null;     Eq 'switch to work' (codex whoami) 'wsA rt-a@x.com-1'
    codex rotate; codex rotate
    Acc use codex personal | Out-Null; Eq 'switch to personal' (codex whoami) 'wsB rt-b@x.com-1'
    Acc use codex work | Out-Null;     Eq 'rotated token of work was saved back (no stale token)' (codex whoami) 'wsA rt-a@x.com-3'
    $env:FAKE_EMAIL = 'c@x.com'; $env:FAKE_ACCT = 'wsC'; codex login | Out-Null
    $out = Acc use codex personal
    Has 'refuses to switch away from an unsaved login' $out 'is not saved yet'
    Has 'use suggests a ready-to-run save command' $out 'aip acc save codex c@x.com'
    Eq 'unsaved login left untouched' (codex whoami) 'wsC rt-c@x.com-1'
    Has 'ls suggests a ready-to-run save command' (Acc ls codex) 'aip acc save codex c@x.com'
    $env:FAKE_EMAIL = 'Khoi Nguyen/..x'; $env:FAKE_ACCT = 'wsK'; codex login | Out-Null
    Has 'ls turns an invalid name into a valid one' (Acc ls codex) 'aip acc save codex Khoi-Nguyen-.x'
    [IO.File]::WriteAllText((Join-Path (Join-Path $env:AIP_TEST_HOME '.codex') 'auth.json'), '{"tokens":{"access_token":"x"}}')
    Has 'ls: unidentifiable login gets no save hint' (Acc ls codex) 'Cannot identify the live login'
    $env:FAKE_EMAIL = 'c@x.com'; $env:FAKE_ACCT = 'wsC'; codex login | Out-Null
    Has "refuses to overwrite another account's name" (Acc save codex work) 'holds another account'
    Acc save codex third | Out-Null; Acc use codex work | Out-Null
    $env:FAKE_EMAIL = 'd@x.com'; $env:FAKE_ACCT = 'wsD'
    Has 'email address accepted as account name' (Acc add codex khoint.danang@gmail.com) 'Added codex/khoint.danang@gmail.com'
    Acc use codex khoint.danang@gmail.com | Out-Null; Eq 'switch using an email name' (codex whoami) 'wsD rt-d@x.com-1'
    Has 'path-like names still rejected' (Acc save codex ../evil) 'must not start with'
    Acc use codex work | Out-Null
    $env:FAKE_LOGIN_FAIL = '1'
    Has 'failed login restores previous account' (Acc add codex fourth) "restored 'work'"
    Remove-Item env:FAKE_LOGIN_FAIL
    Eq 'live login after failed add' (codex whoami) 'wsA rt-a@x.com-3'
    $env:FAKE_EMAIL = 'b@x.com'; $env:FAKE_ACCT = 'wsB'
    Has 'detects login into an already-saved account' (Acc add codex dupe) "already saved as 'personal'"
    Acc use codex work | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $SandHome '.codex') 'config.toml'), 'cli_auth_credentials_store = "auto"')
    Has 'refuses keyring/auto credential store' (Acc use codex personal) 'cli_auth_credentials_store'
    Remove-Item (Join-Path (Join-Path $SandHome '.codex') 'config.toml')
    $env:CODEX_HOME = Join-Path $T 'elsewhere'
    Has 'refuses when CODEX_HOME is set' (Acc use codex personal) 'CODEX_HOME is set'
    Remove-Item env:CODEX_HOME
    $p = $null
    try { $p = Start-Fake 'codex' } catch { }
    if ($p) {
        Start-Sleep -Milliseconds 500
        $global:AipTestAnswer = 'n'
        Has 'warns about running codex and asks' (Acc use codex personal) 'Continue?'
        Eq "answering 'n' keeps the live login" (codex whoami) 'wsA rt-a@x.com-3'
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    } else { Write-Host '  SKIP  running-codex check (could not start a fake process)' }
    $sec = [IO.File]::ReadAllText((Join-Path $env:AIP_ROOT 'accounts\codex\work\secret.dat'.Replace('\', [IO.Path]::DirectorySeparatorChar)))
    if ($OnWindows) { Eq 'vault secret is DPAPI-encrypted' $sec.Substring(0, 6) 'dpapi:' } else { Write-Host '  SKIP  DPAPI check (not Windows)' }

    Write-Host '== Claude Code'
    $env:FAKE_EMAIL = 'a@x.com'; claude | Out-Null
    $cf = Join-Path (Join-Path $SandHome '.claude') '.credentials.json'
    $cred = [IO.File]::ReadAllText($cf).Trim()
    [IO.File]::WriteAllText($cf, $cred.Substring(0, $cred.Length - 1) + ',"mcpOAuth":{"srv":{"accessToken":"mcp-secret"}}}')
    Has 'save current login' (Acc save claude work) 'Saved claude/work'
    $env:FAKE_EMAIL = 'b@x.com'
    Has 'add second account via official login' (Acc add claude personal) 'Added claude/personal'
    claude rotate; claude rotate
    $sf = Join-Path $SandHome '.claude.json'
    $acct = [regex]::Match([IO.File]::ReadAllText($sf), '"oauthAccount"\s*:\s*\{[^{}]*\}').Value
    $rich = @'
{
  "numStartups": 42,
  __ACCT__,
  "projects": {"C:/work/app": {"history": [{"display": "quote \" brace { bracket [ oauthAccount"}]}}
}
'@
    [IO.File]::WriteAllText($sf, $rich.Replace('__ACCT__', $acct))
    Copy-Item $sf (Join-Path $T 'before.json')
    Acc use claude work | Out-Null;     Eq 'switch to work' (claude whoami) 'a@x.com sk-ant-ort-a@x.com-1'
    Eq '.claude.json unchanged outside oauthAccount' (Strip-Oauth $sf) (Strip-Oauth (Join-Path $T 'before.json'))
    claude rotate
    Acc use claude personal | Out-Null; Eq 'rotated token of personal was saved back' (claude whoami) 'b@x.com sk-ant-ort-b@x.com-3'
    Acc use claude work | Out-Null;     Eq 'rotated token of work was saved back' (claude whoami) 'a@x.com sk-ant-ort-a@x.com-2'
    Has 'MCP logins (mcpOAuth) preserved' ([IO.File]::ReadAllText($cf)) 'mcp-secret'
    $p = $null
    try { $p = Start-Fake 'claude' } catch { }
    if ($p) {
        Start-Sleep -Milliseconds 500
        Has 'refuses while a Claude session is running' (Acc use claude personal) 'Close every Claude Code session'
        Eq 'live login untouched after refusal' (claude whoami) 'a@x.com sk-ant-ort-a@x.com-2'
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    } else { Write-Host '  SKIP  running-claude check (could not start a fake process)' }

    Write-Host '== Env mode (aip use)'
    $env:FAKE_EMAIL = 'e@x.com'; $env:FAKE_ACCT = 'wsE'
    aip add codex envtest *>&1 | Out-Null
    Eq 'env mode logs in with --device-auth' ([IO.File]::ReadAllText((Join-Path $env:AIP_TEST_HOME '.codex-login-args'))) 'login --device-auth'
    aip use codex envtest *>&1 | Out-Null
    Eq 'aip use sets CODEX_HOME to the profile' $env:CODEX_HOME (Join-Path (Join-Path $env:AIP_ROOT 'codex') 'envtest')
    Eq 'profile has its own login' (codex whoami) 'wsE rt-e@x.com-1'
    aip use codex default *>&1 | Out-Null
    $env:FAKE_EMAIL = 'f@x.com'; $env:FAKE_ACCT = 'wsF'
    aip add codex me@mail.com *>&1 | Out-Null
    Has 'env mode accepts an email name' (aip use codex me@mail.com *>&1 | Out-String) 'codex -> me@mail.com'
    Has 'env mode rejects path-like names' (aip use codex ../x *>&1 | Out-String) 'must not start with'
    aip use codex default *>&1 | Out-Null

    Write-Host '== Installer (old layout -> ~\.aip, in the sandbox)'
    $H2 = Join-Path $T 'insthome'
    $old = Join-Path $H2 '.ai-profiles'
    New-Item -ItemType Directory -Path (Join-Path (Join-Path $old 'codex') 'oldprof') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path (Join-Path (Join-Path $old 'accounts') 'codex') 'work') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path $old 'codex') 'oldprof') 'auth.json'), '{"tokens":{}}')
    [IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path (Join-Path $old 'accounts') 'codex') 'work') 'meta.json'), '{"tool":"codex","id":"a@x.com|wsA","email":"a@x.com"}')
    [IO.File]::WriteAllText((Join-Path (Join-Path (Join-Path (Join-Path $old 'accounts') 'codex') 'work') 'secret.dat'), 'plain:{}')
    [IO.File]::WriteAllText((Join-Path $H2 'aip.ps1'), 'old')
    $prof = Join-Path (Join-Path (Join-Path $H2 'Documents') 'PowerShell') 'profile.ps1'
    New-Item -ItemType Directory -Path (Split-Path $prof -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($prof, "Set-Alias ll Get-ChildItem`r`n# aip (AI profile switcher)`r`nif (Test-Path `"`$HOME\aip.ps1`") { . `"`$HOME\aip.ps1`" }`r`n")
    $inst = Join-Path (Join-Path $Kit 'windows') 'install.ps1'
    $out = (& $inst -TestHome $H2 *>&1 | Out-String)
    Has 'installer moves old profiles into ~\.aip' $out 'Moved'
    if ((Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $H2 '.aip') 'codex') 'oldprof') 'auth.json')) -and -not (Test-Path $old)) { Ok 'old folder emptied and removed' } else { Bad 'old folder emptied and removed' }
    if (-not (Test-Path (Join-Path $H2 'aip.ps1'))) { Ok 'old files in home folder removed' } else { Bad 'old files in home folder removed' }
    if ((Test-Path (Join-Path (Join-Path (Join-Path $H2 '.aip') 'bin') 'aip.ps1')) -and (Test-Path (Join-Path (Join-Path (Join-Path $H2 '.aip') 'bin') 'aip-acc.ps1'))) { Ok 'scripts installed in ~\.aip\bin' } else { Bad 'scripts installed in ~\.aip\bin' }
    & $inst -TestHome $H2 *>&1 | Out-Null
    $pt = [IO.File]::ReadAllText($prof)
    Eq 'profile hook present exactly once after re-install' ([regex]::Matches($pt, [regex]::Escape('.aip\bin\aip.ps1") {')).Count) 1
    Eq 'old hook line removed' ([regex]::Matches($pt, [regex]::Escape('"$HOME\aip.ps1"')).Count) 0
    Has "user's own profile lines kept" $pt 'Set-Alias ll Get-ChildItem'
    $env:AIP_ROOT = Join-Path $H2 '.aip'
    . (Join-Path (Join-Path (Join-Path $H2 '.aip') 'bin') 'aip.ps1')
    $out = (aip ls *>&1 | Out-String) + (aip acc ls codex *>&1 | Out-String)
    Has 'installed aip finds migrated env profiles' $out 'oldprof'
    Has 'installed aip acc finds migrated saved accounts' $out 'a@x.com'
    & $inst -TestHome $H2 -Uninstall *>&1 | Out-Null
    if (-not (Test-Path (Join-Path (Join-Path $H2 '.aip') 'bin')) -and (Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $H2 '.aip') 'codex') 'oldprof') 'auth.json'))) { Ok 'uninstall removes scripts, keeps data' } else { Bad 'uninstall removes scripts, keeps data' }
    Eq 'uninstall removes the hook' ([regex]::Matches([IO.File]::ReadAllText($prof), 'aip').Count) 0
} catch {
    Bad 'test run aborted' $_.Exception.Message
} finally {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { ([string]$_.Path).Contains($T) } | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($Keep) { Write-Host "Sandbox kept: $T" } else { Start-Sleep -Milliseconds 300; Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ''
Write-Host "Result: $($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
