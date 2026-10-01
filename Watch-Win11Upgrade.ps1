[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunPath,
    [string]$TargetVersion = '25H2',
    [int]$TargetBuild = 26200,
    [ValidateRange(30, 3600)][int]$IntervalSeconds = 60,
    [int]$ProgressBucketSize = 100,
    [int]$MaximumCheckpoints = 8,
    [long]$MaximumCheckpointFileBytes = 16777216,
    [long]$MaximumCheckpointBytes = 67108864,
    [switch]$Once
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$exitCode = 40
try {
    Import-Module (Join-Path $toolRoot 'Modules\Common.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\UpdateTracking.psm1') -Force -ErrorAction Stop
    Import-Module (Join-Path $toolRoot 'Modules\Recorder.psm1') -Force -ErrorAction Stop
    $exitCode = Start-WudProgressRecorder -RunPath $RunPath -TargetVersion $TargetVersion -TargetBuild $TargetBuild -IntervalSeconds $IntervalSeconds -ProgressBucketSize $ProgressBucketSize -MaximumCheckpoints $MaximumCheckpoints -MaximumCheckpointFileBytes $MaximumCheckpointFileBytes -MaximumCheckpointBytes $MaximumCheckpointBytes -Once:$Once
}
catch {
    try {
        $logPath = Join-Path $RunPath 'Recorder.log'
        [IO.File]::AppendAllText($logPath, ('{0} [ERROR] {1}{2}' -f [DateTime]::UtcNow.ToString('o'), $_.Exception.Message, [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
    $exitCode = 40
}
exit $exitCode
