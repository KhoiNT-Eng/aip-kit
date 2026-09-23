# TEST MOCK ONLY - fake `claude` used by tests\windows\run-tests.ps1. Never used outside the tests.
$H = $env:AIP_TEST_HOME
if (-not $H) { Write-Host 'mock claude: refusing to run outside the test suite'; exit 2 }
$cdir = Join-Path $H '.claude'
$cf = Join-Path $cdir '.credentials.json'
$sf = Join-Path $H '.claude.json'
if (-not (Test-Path -LiteralPath $cdir)) { New-Item -ItemType Directory -Path $cdir -Force | Out-Null }
function ReadOrEmpty([string]$p) { if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { '' } }
$c = if ($args.Count) { [string]$args[0] } else { '' }
switch ($c) {
    'rotate' {
        $t = [regex]::Replace((ReadOrEmpty $cf), '"refreshToken":"([^"]*)-(\d+)"', { param($m) '"refreshToken":"' + $m.Groups[1].Value + '-' + ([int]$m.Groups[2].Value + 1) + '"' })
        [IO.File]::WriteAllText($cf, $t)
    }
    'whoami' {
        $e = [regex]::Match((ReadOrEmpty $sf), '"emailAddress"\s*:\s*"([^"]*)"').Groups[1].Value
        $r = [regex]::Match((ReadOrEmpty $cf), '"refreshToken"\s*:\s*"([^"]*)"').Groups[1].Value
        "$e $r"
    }
    '' {
        # interactive session: logs in when there is no Claude token
        $cred = ReadOrEmpty $cf
        if ($cred -match '"claudeAiOauth"\s*:\s*\{' -or $env:FAKE_LOGIN_FAIL) { exit 0 }
        $tok = '"claudeAiOauth":{"accessToken":"sk-ant-oat-x","refreshToken":"sk-ant-ort-' + $env:FAKE_EMAIL + '-1","expiresAt":4102444800000,"scopes":["user:inference"],"subscriptionType":"max"}'
        if ($cred.Trim() -match '^\{\s*\}?$' -or -not $cred.Trim()) { $cred = '{' + $tok + '}' }
        else { $cred = $cred.Trim(); $cred = '{' + $tok + ',' + $cred.Substring(1) }
        [IO.File]::WriteAllText($cf, $cred)
        $acct = '"oauthAccount":{"emailAddress":"' + $env:FAKE_EMAIL + '","accountUuid":"u-' + $env:FAKE_EMAIL + '","organizationUuid":"o-' + $env:FAKE_EMAIL + '","organizationName":"Org ' + $env:FAKE_EMAIL + '"}'
        $st = ReadOrEmpty $sf
        if ($st -match '"oauthAccount"\s*:\s*\{[^{}]*\}') { $st = [regex]::Replace($st, '"oauthAccount"\s*:\s*\{[^{}]*\}', $acct) }
        elseif (-not $st.Trim()) { $st = '{' + $acct + '}' }
        else { $st = $st.Trim(); $st = '{' + $acct + ',' + $st.Substring(1) }
        [IO.File]::WriteAllText($sf, $st)
        'Login successful'
    }
}
