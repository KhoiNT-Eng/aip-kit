# TEST MOCK ONLY - fake `codex` used by tests\windows\run-tests.ps1. Never used outside the tests.
$H = $env:AIP_TEST_HOME
if (-not $H) { Write-Host 'mock codex: refusing to run outside the test suite'; exit 2 }
$dir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $H '.codex' }
$f = Join-Path $dir 'auth.json'
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
function B64U([string]$s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
$c = if ($args.Count) { [string]$args[0] } else { '' }
switch ($c) {
    'login' {
        if ($env:FAKE_LOGIN_FAIL) { exit 1 }
        $payload = '{"email":"' + $env:FAKE_EMAIL + '","https://api.openai.com/auth":{"chatgpt_account_id":"' + $env:FAKE_ACCT + '","chatgpt_plan_type":"plus"}}'
        $json = '{"OPENAI_API_KEY":null,"tokens":{"id_token":"h.' + (B64U $payload) + '.s","access_token":"at","refresh_token":"rt-' + $env:FAKE_EMAIL + '-1","account_id":"' + $env:FAKE_ACCT + '"},"last_refresh":"2026-09-23T00:00:00Z"}'
        [IO.File]::WriteAllText($f, $json)
        'Successfully logged in'
    }
    'rotate' {
        $t = [IO.File]::ReadAllText($f)
        $t = [regex]::Replace($t, '"refresh_token":"([^"]*)-(\d+)"', { param($m) '"refresh_token":"' + $m.Groups[1].Value + '-' + ([int]$m.Groups[2].Value + 1) + '"' })
        [IO.File]::WriteAllText($f, $t)
    }
    'whoami' {
        $o = [IO.File]::ReadAllText($f) | ConvertFrom-Json
        "$($o.tokens.account_id) $($o.tokens.refresh_token)"
    }
}
