[CmdletBinding()]
param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,128}$')][string]$RunId)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$runtime = Split-Path -Parent $MyInvocation.MyCommand.Path
try {
    $prefix = [IO.Path]::GetFullPath($runtime).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    foreach ($line in Get-Content -LiteralPath (Join-Path $runtime 'BundleManifest.sha256')) {
        if ($line -match '^\s*$|^\s*#') { continue }
        if ($line -notmatch '^([a-fA-F0-9]{64})\s+\*?(.+)$') { throw 'Malformed engine manifest.' }
        $hash = $matches[1]; $relative = $matches[2]
        $path = [IO.Path]::GetFullPath((Join-Path $runtime $relative))
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $hash) { throw 'Engine integrity verification failed.' }
    }
    foreach ($name in @('Common', 'Persistence', 'RuntimeUpdate')) { Import-Module (Join-Path $runtime ("Modules/{0}.psm1" -f $name)) -Force -ErrorAction Stop }
    if (-not (Test-WudAdministrator)) { throw 'Active-run updates require administrator elevation.' }
    Invoke-WudActiveRuntimeUpdate -RunId $RunId -RuntimePath $runtime
    exit 0
}
catch { Write-Host ("Active-run engine update failed: {0}" -f ($_ | Out-String)); exit 40 }
