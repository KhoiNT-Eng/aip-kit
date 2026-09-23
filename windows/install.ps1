# Installer for aip (Windows PowerShell 5.1 / PowerShell 7+). Everything goes into %USERPROFILE%\.aip:
#   .aip\bin\            aip.ps1, aip-acc.ps1 (the scripts)
#   .aip\codex|claude\   env-mode profiles
#   .aip\accounts\       snapshot-mode vault
#
#   Double-click install.cmd, or:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1              install / update (migrates the old layout)
#   powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall   remove scripts + profile hook (data kept)
param([switch]$Uninstall, [string]$TestHome)   # -TestHome: test suite only (sandbox folder)
$ErrorActionPreference = 'Stop'

$UserHome = if ($TestHome) { $TestHome } else { $HOME }
$Aip = Join-Path $UserHome '.aip'
$Bin = Join-Path $Aip 'bin'
$OldRoot = Join-Path $UserHome '.ai-profiles'
$mark    = '# aip (AI profile switcher)'
$line    = 'if (Test-Path "$HOME\.aip\bin\aip.ps1") { . "$HOME\.aip\bin\aip.ps1" }'
$oldLine = 'if (Test-Path "$HOME\aip.ps1") { . "$HOME\aip.ps1" }'
$files   = 'aip.ps1', 'aip-acc.ps1'

# Hook into both Windows PowerShell 5.1 and PowerShell 7 (all-hosts profile of current user).
if ($TestHome) { $docs = Join-Path $TestHome 'Documents' }
else {
    $docs = [Environment]::GetFolderPath('MyDocuments')   # handles OneDrive-redirected Documents
    if (-not $docs) { $docs = Join-Path $HOME 'Documents' }
}
$profiles = @(
    (Join-Path (Join-Path $docs 'WindowsPowerShell') 'profile.ps1'),
    (Join-Path (Join-Path $docs 'PowerShell') 'profile.ps1')
)

function Remove-Hook([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    $all = @(Get-Content -LiteralPath $p)
    $kept = @($all | Where-Object { $_ -ne $mark -and $_ -ne $line -and $_ -ne $oldLine })
    if ($kept.Count -eq $all.Count) { return $false }
    $n = $kept.Count
    while ($n -gt 0 -and -not $kept[$n - 1].Trim()) { $n-- }        # drop trailing blank lines we added
    $kept = if ($n -gt 0) { $kept[0..($n - 1)] } else { @() }
    Set-Content -LiteralPath $p -Value $kept -Encoding UTF8
    return $true
}

function Protect-Dir([string]$Path) {
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    if (-not $onWindows) { return }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $Path /inheritance:r /grant:r "*${sid}:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" | Out-Null
}

if ($Uninstall) {
    foreach ($p in $profiles) { if (Remove-Hook $p) { Write-Host "Removed hook from $p" } }
    if (Test-Path -LiteralPath $Bin) { Remove-Item -LiteralPath $Bin -Recurse -Force; Write-Host "Removed $Bin" }
    foreach ($f in $files) { $o = Join-Path $UserHome $f; if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force } }
    Write-Host "Your profiles and saved accounts in $Aip were kept. Delete that folder yourself if you no longer need them (log out of each account first)."
    return
}

foreach ($f in $files) { if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $f))) { throw "$f not found next to install.ps1" } }

$fresh = -not (Test-Path -LiteralPath $Aip)
New-Item -ItemType Directory -Path $Bin -Force | Out-Null
if ($fresh) { try { Protect-Dir $Aip } catch { Write-Host "Warning: could not restrict access to $Aip ($_)" -ForegroundColor Yellow } }

# ---- migrate the previous layout (~\.ai-profiles, ~\aip.ps1, ~\aip-acc.ps1)
if (Test-Path -LiteralPath $OldRoot) {
    foreach ($item in 'codex', 'claude', 'accounts') {
        $src = Join-Path $OldRoot $item
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $Aip $item
        if (Test-Path -LiteralPath $dst) { Write-Host "Note: $dst already exists; left $src in place (merge it by hand)." -ForegroundColor Yellow }
        else { Move-Item -LiteralPath $src -Destination $dst; Write-Host "Moved $src -> $dst" }
    }
    $lock = Join-Path $OldRoot 'accounts\.lock'
    if (Test-Path -LiteralPath $lock) { Remove-Item -LiteralPath $lock -Force }
    if (-not (Get-ChildItem -LiteralPath $OldRoot -Force)) { Remove-Item -LiteralPath $OldRoot -Force; Write-Host "Removed empty $OldRoot" }
}
foreach ($f in $files) { $o = Join-Path $UserHome $f; if (Test-Path -LiteralPath $o) { Remove-Item -LiteralPath $o -Force } }

foreach ($f in $files) {
    $dst = Join-Path $Bin $f
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $f) -Destination $dst -Force
    try { Unblock-File -LiteralPath $dst } catch { }   # remove "downloaded from Internet" mark
}
Write-Host "Installed $Bin\aip.ps1 and aip-acc.ps1"

foreach ($p in $profiles) {
    $dir = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [void](Remove-Hook $p)
    Add-Content -LiteralPath $p -Value "`r`n$mark`r`n$line" -Encoding UTF8
    Write-Host "Hooked into $p"
}

if (-not $TestHome) {
    # Profiles only load if the execution policy allows local scripts.
    $effective = Get-ExecutionPolicy
    if ($effective -in 'Restricted', 'AllSigned', 'Undefined') {
        Write-Host ""
        Write-Host "Your PowerShell execution policy is '$effective', which blocks loading your profile." -ForegroundColor Yellow
        $ans = Read-Host "Set it to 'RemoteSigned' for your user only (recommended)? [y/N]"
        if ($ans -in 'y', 'Y', 'yes') {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Write-Host 'Execution policy set to RemoteSigned (CurrentUser).'
        } else {
            Write-Host 'Skipped. aip will not load automatically until you allow local scripts.' -ForegroundColor Yellow
        }
    }
    foreach ($t in 'codex', 'claude') {
        if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
            Write-Host "Note: '$t' not found in PATH (install it before 'aip add $t ...')." -ForegroundColor Yellow
        }
    }
}

Write-Host @'

Done. Open a NEW PowerShell window (old ones may still point at the previous paths), then:
  aip acc save codex work        # snapshot mode (works with IDEs)
  aip add codex work --share     # env mode (per window)
  aip help
'@
