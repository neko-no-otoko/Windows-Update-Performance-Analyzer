[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($module in @('Common', 'UpdateTracking', 'Recorder', 'Collectors', 'Analysis', 'Review', 'Report')) { Import-Module (Join-Path $toolRoot ("Modules/{0}.psm1" -f $module)) -Force }
function Assert-Report320 { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('WUPA-Report320-' + [Guid]::NewGuid().ToString('N'))
$oldDrive = $env:SystemDrive; $oldRoot = $env:SystemRoot; $oldData = $env:ProgramData
try {
    $env:SystemDrive = New-WudDirectory (Join-Path $fixture 'fake-drive')
    $env:SystemRoot = New-WudDirectory (Join-Path $fixture 'fake-windows')
    $env:ProgramData = New-WudDirectory (Join-Path $fixture 'fake-programdata')
    foreach ($scenario in @('Already25H2', 'BaselineAndFinal', 'LegacyDump', 'PartialMetadata', 'TruncatedMetadata')) {
        $caseRoot = Join-Path $fixture $scenario
        $ctx = New-WudRunContext -ToolRoot $toolRoot -ToolVersion '3.2.0-test' -RunId $scenario -RunPath (Join-Path $caseRoot 'run') -OutputPath (Join-Path $caseRoot 'out') -Mode 'Forensic' -PhaseLabel 'Forensic' -TargetVersion '25H2' -CopyTo $null -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
        $ctx.Inventory['Identity'] = [pscustomobject]@{ DisplayVersion = '25H2'; Build = 26200; UBR = 1; ImageState = 'IMAGE_STATE_COMPLETE'; ComputerName = 'fixture' }
        if ($scenario -eq 'BaselineAndFinal') {
            $ctx.PhaseLabel = 'Preflight'; $ctx.Mode = 'Preflight'
            $ctx.SnapshotPath = New-WudDirectory (Join-Path $ctx.EvidencePath 'Preflight')
            & (Get-Module Collectors) { param($c) Invoke-WudRawEvidenceCollector $c } $ctx
            $ctx.PhaseLabel = 'Finalize'; $ctx.Mode = 'Finalize'
            $ctx.SnapshotPath = New-WudDirectory (Join-Path $ctx.EvidencePath 'Finalize')
            Write-WudJsonLine -Path (Join-Path $ctx.RunPath 'Evidence/Recorder/ProgressSamples.jsonl') -InputObject ([pscustomobject]@{ TimestampUtc = '2026-10-01T09:00:00Z'; Os = [pscustomobject]@{ Build = 22631; TargetPresent = $false } })
            Write-WudJsonLine -Path (Join-Path $ctx.RunPath 'Evidence/Recorder/ProgressSamples.jsonl') -InputObject ([pscustomobject]@{ TimestampUtc = '2026-10-01T10:00:00Z'; Os = [pscustomobject]@{ Build = 26200; TargetPresent = $true } })
        }
        & (Get-Module Collectors) { param($c) Invoke-WudRawEvidenceCollector $c } $ctx
        $rawPath = Join-Path $ctx.SnapshotPath 'raw-copy-results.json'
        if ($scenario -eq 'LegacyDump') {
            Write-WudJsonAtomic $rawPath ([pscustomobject]@{ Sources = @(); MemoryDump = [pscustomobject]@{ Path = 'C:\Windows\MEMORY.DMP'; Copied = $false; Length = 123; CopyReason = 'Legacy metadata only.' } })
        }
        if ($scenario -eq 'PartialMetadata') { Write-WudJsonAtomic $rawPath ([pscustomobject]@{ Sources = @([pscustomobject]@{ Source = 'fixture' }); MemoryDump = [pscustomobject]@{ Copied = $false } }) }
        if ($scenario -eq 'TruncatedMetadata') {
            Write-WudText $rawPath '{"Sources":'
            Write-WudText (Join-Path $ctx.SnapshotPath 'collector-records.json') '{"Id":'
        }
        $null = Invoke-WudFactAnalysis $ctx
        $null = Export-WudReviewBundle $ctx
        $report = Export-WudReportArtifacts $ctx
        Assert-Report320 (-not (Test-Path (Join-Path $ctx.OutputPath 'Report.pending'))) "$scenario removes the completion marker only after export succeeds"
        foreach ($name in @('Report.html', 'Summary.json', 'Manifest.json', 'Checksums.sha256', 'Evidence.zip', 'ReviewBundle.zip')) { Assert-Report320 (Test-Path (Join-Path $ctx.OutputPath $name)) "$scenario produces $name rather than fatal code 40" }
        $manifest = Read-WudJson (Join-Path $ctx.OutputPath 'Manifest.json')
        Assert-Report320 ([bool]$manifest.ArchiveVerification.Verified) "$scenario archive reopens and verifies"
        if ($scenario -in @('Already25H2', 'BaselineAndFinal')) {
            $exclusions = @($manifest.SourceMappings | Where-Object State -eq 'ExcludedByDesign')
            Assert-Report320 ($exclusions.Count -eq $(if ($scenario -eq 'BaselineAndFinal') { 2 } else { 1 })) "$scenario preserves real excluded-dump records"
            Assert-Report320 ($null -eq $exclusions[0].SourcePath -and $null -eq $exclusions[0].Present -and -not $exclusions[0].Copied -and $exclusions[0].Detail) "$scenario does not invent dump presence/path/copy success"
        }
        if ($scenario -eq 'LegacyDump') { Assert-Report320 (@($manifest.SourceMappings | Where-Object State -eq 'MetadataOnly').Count -eq 1) 'Old dump metadata remains readable with optional fields missing' }
        if ($scenario -eq 'PartialMetadata') { Assert-Report320 (@($manifest.SourceMappings | Where-Object State -eq 'MetadataIncomplete').Count -eq 2) 'Incomplete metadata is explicitly labeled without a strict-mode crash' }
        if ($scenario -eq 'TruncatedMetadata') { Assert-Report320 (@($manifest.CollectionGaps | Where-Object Status -eq 'MetadataUnreadable').Count -eq 2) 'Truncated metadata is retained and reported as material coverage gaps' }
        if ($scenario -in @('PartialMetadata', 'TruncatedMetadata')) { Assert-Report320 ($ctx.ExitCode -eq 30) "$scenario reports materially incomplete evidence with code 30" }
        Assert-Report320 ($ctx.ExitCode -ne 40) "$scenario does not report a tool failure"
    }
    Write-Output "PASS: real collector/exporter regression fixtures in $fixture"
}
finally { $env:SystemDrive = $oldDrive; $env:SystemRoot = $oldRoot; $env:ProgramData = $oldData }
