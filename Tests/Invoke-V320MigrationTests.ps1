[CmdletBinding()]
param([ValidateSet('3.1.1', '3.2.0', '3.2.1')][string]$PreviousEngine = '3.1.1')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$toolRoot = Split-Path -Parent $PSScriptRoot
foreach ($name in @('Common', 'Persistence', 'RuntimeUpdate')) { Import-Module (Join-Path $toolRoot ("Modules/{0}.psm1" -f $name)) -Force }
function Assert-Migration320 { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message }; Write-Host "PASS: $Message" }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('WUPA-Migration320-' + [Guid]::NewGuid().ToString('N'))
$oldData = $env:ProgramData; $oldRoot = $env:SystemRoot
try {
    $env:ProgramData = New-WudDirectory $fixture
    $env:SystemRoot = New-WudDirectory (Join-Path $fixture 'fake-windows')
    $runtime = New-WudDirectory (Join-Path (Get-WudProgramDataRoot) 'Runtime/3.2.2')
    Copy-Item (Join-Path $toolRoot 'Data') $runtime -Recurse
    Copy-Item (Join-Path $toolRoot 'VERSION') $runtime
    $module = Get-Module RuntimeUpdate
    & $module {
        $script:Tasks = @{}; $script:FailRegistration = $false; $script:FailRestart = $false; $script:OldEntryRunning = $false
        function script:Export-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) return $script:Tasks[$TaskName] }
        function script:Register-ScheduledTask {
            param($TaskName, $TaskPath, $Xml, [switch]$Force, $ErrorAction)
            if ($script:FailRegistration) { $script:FailRegistration = $false; throw 'Injected task registration failure.' }
            $script:Tasks[$TaskName] = $Xml
        }
        function script:Stop-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) }
        function script:Get-CimInstance {
            param($ClassName, $Filter, $ErrorAction)
            if ($script:OldEntryRunning) { return [pscustomobject]@{ ProcessId = -1; CommandLine = $script:OldEntryCommand } }
            return @()
        }
        function script:Stop-WudRecorderTask { param($State) return [pscustomobject]@{ Status = 'Stopped'; Error = $null } }
        function script:Start-WudRecorderTask {
            param($State)
            if ($script:FailRestart -and $State.ToolVersion -eq '3.2.2') { return [pscustomobject]@{ Status = 'StartUnverified'; Error = 'Injected restart failure.' } }
            return [pscustomobject]@{ Status = 'Started'; Error = $null }
        }
    }
    foreach ($scenario in @('Success', 'BusyCollector', 'RegistrationFailure', 'RestartFailure', 'OldProcess', 'UnsupportedSchema', 'PendingRecovery', 'PendingNewState', 'ForeignTask')) {
        $run = New-WudDirectory (Join-Path (Get-WudProgramDataRoot) ("Runs/{0}" -f $scenario))
        $null = New-WudDirectory (Join-Path $run 'State')
        $oldRuntime = New-WudDirectory (Join-Path (Get-WudProgramDataRoot) ('Runtime/' + $PreviousEngine))
        $state = [pscustomobject][ordered]@{
            SchemaVersion = 2; ToolVersion = $PreviousEngine; RunId = $scenario; RunPath = $run; RuntimePath = $oldRuntime
            OutputPath = (Join-Path $fixture ("out/{0}" -f $scenario)); TargetVersion = '25H2'; TargetBuild = 26200
            Status = 'Armed'; CopyTo = $null; StatePath = (Join-Path $run 'State/run-state.json')
            CreatedUtc = '2026-10-01T09:00:00Z'; ExpiresUtc = '2026-10-31T09:00:00Z'
            Task = [pscustomobject]@{ TaskName = "Resume-$scenario"; TaskPath = '\WUPA\' }
            RecorderTask = [pscustomobject]@{ TaskName = "Recorder-$scenario"; TaskPath = '\WUPA\' }
            Hooks = [pscustomobject]@{ OobeMarker = (Join-Path $run 'State/post-oobe.marker') }
            SetupConfig = [pscustomobject]@{ OriginalHash = 'do-not-change'; AddedEntries = @('PostOOBE') }
        }
        Write-WudJsonAtomic (Join-Path (Get-WudProgramDataRoot) 'ActiveRun.json') $state
        Write-WudJsonAtomic $state.StatePath $state
        $samplePath = Join-Path $run 'Evidence/Recorder/ProgressSamples.jsonl'
        Write-WudText $samplePath '{"TimestampUtc":"2026-10-01T09:00:00Z","Os":{"Build":22631}}'
        $baseline = Join-Path $run 'Evidence/Preflight/baseline.json'; Write-WudText $baseline '{"Build":22631}'
        $sampleHash = Get-WudFileHashSafe $samplePath; $baselineHash = Get-WudFileHashSafe $baseline
        $xmls = @{}
        foreach ($kind in @('Resume', 'Recorder')) {
            $script = Join-Path $oldRuntime $(if ($kind -eq 'Resume') { 'Invoke-Win11UpgradeDiag.ps1' } else { 'Watch-Win11Upgrade.ps1' })
            $command = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $xmls["$kind-$scenario"] = '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Triggers><BootTrigger><Enabled>true</Enabled></BootTrigger></Triggers><Principals><Principal><UserId>S-1-5-18</UserId></Principal></Principals><Actions><Exec><Command>' + [Security.SecurityElement]::Escape($command) + '</Command><Arguments>-File &quot;' + [Security.SecurityElement]::Escape($script) + '&quot; -RunId ' + $scenario + '</Arguments><WorkingDirectory>' + [Security.SecurityElement]::Escape($oldRuntime) + '</WorkingDirectory></Exec></Actions></Task>'
        }
        & $module { param($Xmls, $Scenario, $OldRuntime)
            $script:Tasks = $Xmls.Clone(); $script:FailRegistration = $Scenario -eq 'RegistrationFailure'; $script:FailRestart = $Scenario -eq 'RestartFailure'; $script:OldEntryRunning = $Scenario -eq 'OldProcess'; $script:OldEntryCommand = Join-Path $OldRuntime 'Invoke-Win11UpgradeDiag.ps1'
        } $xmls $scenario $oldRuntime
        if ($scenario -eq 'UnsupportedSchema') { $state.SchemaVersion = 99; Write-WudJsonAtomic (Join-Path (Get-WudProgramDataRoot) 'ActiveRun.json') $state }
        if ($scenario -eq 'ForeignTask') { $state.Task.TaskName = 'Unrelated-task'; Write-WudJsonAtomic (Join-Path (Get-WudProgramDataRoot) 'ActiveRun.json') $state }
        if ($scenario -in @('PendingRecovery', 'PendingNewState')) {
            $records = & $module { param($s) return @((Get-WudOwnedTaskXml $s Resume), (Get-WudOwnedTaskXml $s Recorder)) } $state
            $journal = [pscustomobject]@{ Status = 'Pending'; RunId = $scenario; OldState = $state; ResumeTask = $records[0]; RecorderTask = $records[1]; Error = 'Power loss fixture'; PauseStartedUtc = '2026-10-01T09:01:00Z' }
            Write-WudJsonAtomic (Join-Path $run 'State/Updates/interrupted/journal.json') $journal -Depth 40
            & $module { param($s, $r) Set-WudOwnedTaskRuntime (Get-WudOwnedTaskXml $s Resume) $r } $state $runtime
            if ($scenario -eq 'PendingNewState') {
                & $module { param($s, $r) Set-WudOwnedTaskRuntime (Get-WudOwnedTaskXml $s Recorder) $r } $state $runtime
                $changedState = ConvertFrom-WudJsonText ($state | ConvertTo-Json -Depth 40)
                $changedState.ToolVersion = '3.2.2'; $changedState.RuntimePath = $runtime
                Write-WudJsonAtomic (Join-Path (Get-WudProgramDataRoot) 'ActiveRun.json') $changedState
                Write-WudJsonAtomic $state.StatePath $changedState
            }
        }
        $lock = $null
        if ($scenario -eq 'BusyCollector') { $lock = [IO.File]::Open((Join-Path $run 'State/run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        $failed = $false
        try { Invoke-WudActiveRuntimeUpdate $scenario $runtime }
        catch { $failed = $true; Write-Host "EXPECTED FAILURE ($scenario): $($_.Exception.Message)" }
        finally { if ($lock) { $lock.Dispose() } }
        $current = Get-WudActiveRunState
        $tasks = & $module { return $script:Tasks.Clone() }
        if ($scenario -in @('Success', 'PendingRecovery', 'PendingNewState')) {
            Assert-Migration320 (-not $failed -and $current.ToolVersion -eq '3.2.2' -and $current.RuntimePath -eq $runtime) "$scenario migrates the existing state rather than creating a new run"
            Assert-Migration320 ($tasks["Resume-$scenario"].Contains($runtime) -and $tasks["Recorder-$scenario"].Contains($runtime)) "$scenario updates both owned task actions"
            Assert-Migration320 ($tasks["Resume-$scenario"].Contains('<BootTrigger>')) "$scenario preserves existing task triggers"
            $journal = Read-WudJson $current.RuntimeUpdateJournal
            Assert-Migration320 ($journal.Status -eq 'Completed' -and $journal.PauseStartedUtc -and $journal.ResumeVerifiedUtc) "$scenario records the sampling interruption and verified restart"
        }
        else {
            Assert-Migration320 ($failed -and $current.ToolVersion -eq $PreviousEngine) "$scenario refuses or rolls back instead of silently committing"
            if ($scenario -ne 'ForeignTask') { Assert-Migration320 ($tasks["Resume-$scenario"] -eq $xmls["Resume-$scenario"] -and $tasks["Recorder-$scenario"] -eq $xmls["Recorder-$scenario"]) "$scenario retains/restores exact original task definitions" }
        }
        Assert-Migration320 ((Get-WudFileHashSafe $samplePath) -eq $sampleHash -and (Get-WudFileHashSafe $baseline) -eq $baselineHash -and $current.RunId -eq $scenario) "$scenario retains samples, baseline and RunId byte-for-byte"
        Assert-Migration320 ($current.SetupConfig.OriginalHash -eq 'do-not-change' -and $current.Hooks.OobeMarker -eq $state.Hooks.OobeMarker) "$scenario does not modify setup hooks or their backup metadata"
    }
    Write-Output "PASS: active-run migration regression fixtures in $fixture"
}
finally { $env:ProgramData = $oldData; $env:SystemRoot = $oldRoot }
