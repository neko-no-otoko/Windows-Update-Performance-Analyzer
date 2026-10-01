[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'This smoke test requires an isolated Windows runner.' }
$root = Split-Path -Parent $PSScriptRoot
if (-not $OutputPath) { $OutputPath = Join-Path $root 'dist' }
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$programRoot = Join-Path $env:ProgramData 'WUPA'
if (Test-Path (Join-Path $programRoot 'ActiveRun.json')) { throw 'Refusing to launch a test against an existing active case.' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$exe = Join-Path $OutputPath ("WUPA-{0}-win-x64.exe" -f $version)
$process = $null
try {
    $process = Start-Process -FilePath $exe -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    $ready = $false
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Portable executable exited before readiness: $($process.ExitCode)." }
        if ($process.MainWindowHandle -eq [IntPtr]::Zero) { continue }
        $window = [Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        $condition = New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::NameProperty, 'Check for updates')
        $link = $window.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
        # This link becomes enabled only after payload extraction, verification,
        # updater/key initialization and the bounded initial check have finished.
        $ready = $null -ne $link -and $link.Current.IsEnabled
    } while (-not $ready -and [DateTime]::UtcNow -lt $deadline)
    if (-not $ready) { throw 'The actual portable executable did not complete GUI/collector preparation within 45 seconds.' }
    $runtime = Join-Path $programRoot ("Runtime/{0}" -f $version)
    $manifest = Join-Path $runtime 'BundleManifest.sha256'
    if ((Get-FileHash $manifest).Hash -ne (Get-FileHash (Join-Path $root 'BundleManifest.sha256')).Hash) { throw 'Extracted payload manifest differs from the build source.' }
    $count = 0
    foreach ($line in Get-Content $manifest) {
        if ($line -match '^([a-fA-F0-9]{64})\s+\*?(.+)$') {
            if ((Get-FileHash (Join-Path $runtime $matches[2])).Hash -ne $matches[1]) { throw 'Actual EXE extracted an incorrect payload file.' }
            $count++
        }
    }
    if ($count -lt 1 -or (Test-Path (Join-Path $programRoot 'ActiveRun.json'))) { throw 'Startup unexpectedly created a tracking case or no payload was verified.' }
    [pscustomobject]@{ Passed = $true; Version = $version; Runtime = 'win-x64'; VerifiedPayloadFiles = $count; GuiReady = $ready; TrackingCaseCreated = $false; Scope = 'Actual self-contained EXE startup/key initialization/payload verification on an isolated Windows CI runner; no collector or upgrade action clicked.' } | ConvertTo-Json | Set-Content (Join-Path $OutputPath 'WUPA-portable-smoke.json') -Encoding UTF8
    Write-Host "PASS: actual portable EXE startup, updater readiness and $count extracted payload hashes; no tracking case was created."
}
finally {
    # Only the exact process launched by this isolated smoke test is stopped.
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
}
