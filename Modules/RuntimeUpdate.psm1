Set-StrictMode -Version 2.0

function Assert-WudRuntimeUpdatePaths {
    param($State, [string]$RuntimePath)
    if ([string]$State.RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,128}$') { throw 'Unsafe run ID.' }
    $root = [IO.Path]::GetFullPath((Get-WudProgramDataRoot)).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $expectedRun = [IO.Path]::GetFullPath((Join-Path $root ("Runs/{0}" -f $State.RunId)))
    if ([IO.Path]::GetFullPath([string]$State.RunPath) -ne $expectedRun) { throw 'The active run is outside its expected ProgramData location.' }
    foreach ($runtime in @($RuntimePath, [string]$State.RuntimePath)) {
        $fullRuntime = [IO.Path]::GetFullPath($runtime)
        if ((Split-Path -Parent $fullRuntime) -ne (Join-Path $root 'Runtime') -or (Split-Path -Leaf $fullRuntime) -notmatch '^\d+\.\d+\.\d+$') { throw 'An engine must use its versioned WUPA Runtime directory.' }
    }
    foreach ($path in @($State.RunPath, $RuntimePath, [string]$State.RuntimePath, $root)) {
        $full = [IO.Path]::GetFullPath($path)
        $prefix = $root + [IO.Path]::DirectorySeparatorChar
        if ($full -ne $root -and -not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Runtime update cannot use paths outside WUPA ProgramData.' }
        for ($cursor = $full; $cursor -and $cursor -ne (Split-Path -Parent $root); $cursor = Split-Path -Parent $cursor) {
            if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Runtime update paths cannot contain reparse points.' }
        }
    }
}

function Get-WudOwnedTaskXml {
    param($State, [ValidateSet('Resume', 'Recorder')][string]$Kind)
    $task = if ($Kind -eq 'Resume') { $State.Task } else { $State.RecorderTask }
    if ($task.TaskName -ne "$Kind-$($State.RunId)" -or $task.TaskPath -ne '\WUPA\') { throw 'Task ownership does not match the active run.' }
    $xmlText = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver = $null
    $document.LoadXml($xmlText)
    $execs = @($document.SelectNodes("//*[local-name()='Actions']/*[local-name()='Exec']"))
    if ($execs.Count -ne 1) { throw 'An owned task must have exactly one executable action.' }
    $command = $execs[0].SelectSingleNode("*[local-name()='Command']")
    $arguments = $execs[0].SelectSingleNode("*[local-name()='Arguments']")
    $scriptName = if ($Kind -eq 'Resume') { 'Invoke-Win11UpgradeDiag.ps1' } else { 'Watch-Win11Upgrade.ps1' }
    $oldScript = Join-Path $State.RuntimePath $scriptName
    $expectedPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not $command -or $command.InnerText -ne $expectedPowerShell -or -not $arguments -or $arguments.InnerText.IndexOf($oldScript, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'An existing task action is not the expected WUPA script.' }
    $principal = $document.SelectSingleNode("//*[local-name()='Principal']/*[local-name()='UserId']")
    if (-not $principal -or $principal.InnerText -notin @('SYSTEM', 'S-1-5-18')) { throw 'The owned task is not running as SYSTEM.' }
    $return = [pscustomobject]@{ TaskName = $task.TaskName; TaskPath = $task.TaskPath; Xml = $xmlText; OldScript = $oldScript; ScriptName = $scriptName }
    return $return
}

function Set-WudOwnedTaskRuntime {
    param($TaskRecord, [string]$RuntimePath)
    $document = New-Object Xml.XmlDocument
    $document.XmlResolver = $null
    $document.LoadXml($TaskRecord.Xml)
    $exec = $document.SelectSingleNode("//*[local-name()='Actions']/*[local-name()='Exec']")
    $arguments = $exec.SelectSingleNode("*[local-name()='Arguments']")
    $arguments.InnerText = [Regex]::Replace($arguments.InnerText, [Regex]::Escape($TaskRecord.OldScript), [Text.RegularExpressions.MatchEvaluator]{ param($match) (Join-Path $RuntimePath $TaskRecord.ScriptName) }, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $working = $exec.SelectSingleNode("*[local-name()='WorkingDirectory']")
    if (-not $working) { $working = $document.CreateElement('WorkingDirectory', $exec.NamespaceURI); $null = $exec.AppendChild($working) }
    $working.InnerText = $RuntimePath
    $null = Register-ScheduledTask -TaskName $TaskRecord.TaskName -TaskPath $TaskRecord.TaskPath -Xml $document.OuterXml -Force -ErrorAction Stop
}

function Wait-WudRecorderStopped {
    param([string]$RunPath)
    $path = Join-Path $RunPath 'State/recorder.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        try { $gate = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None); $gate.Dispose(); return }
        catch { Start-Sleep -Milliseconds 250 }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The old recorder still owns its lock; no runtime files will be overwritten.'
}

function Restore-WudRuntimeUpdate {
    param($Context, $Journal, [string]$JournalPath)
    $oldState = $Journal.OldState
    if ($Journal.RunId -ne $Context.RunId -or $oldState.RunId -ne $Context.RunId) { throw 'Recovery journal run identity is invalid.' }
    Assert-WudRuntimeUpdatePaths -State $oldState -RuntimePath $oldState.RuntimePath
    # A power loss can leave the new recorder running with a Pending journal.
    # Stop that owned recorder before restoring/restarting the old definition.
    $stop = Stop-WudRecorderTask -State $oldState
    if ($stop.Status -ne 'Stopped') { throw 'Recovery could not pause the owned recorder.' }
    Wait-WudRecorderStopped $oldState.RunPath
    # Restoration is idempotent and uses only this case's validated task names.
    foreach ($record in @($Journal.ResumeTask, $Journal.RecorderTask)) {
        if ($record.TaskName -notin @("Resume-$($Context.RunId)", "Recorder-$($Context.RunId)") -or $record.TaskPath -ne '\WUPA\') { throw 'Recovery journal task ownership is invalid.' }
        $null = Register-ScheduledTask -TaskName $record.TaskName -TaskPath $record.TaskPath -Xml $record.Xml -Force -ErrorAction Stop
    }
    Save-WudRunState -Context $Context -State $oldState -SetActive $true
    $restart = Start-WudRecorderTask -State $oldState
    if ($restart.Status -ne 'Started') { throw "Original recorder restart could not be verified: $($restart.Status)." }
    $Journal.Status = 'RolledBack'
    $Journal | Add-Member -NotePropertyName RecoveredUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Write-WudJsonAtomic -Path $JournalPath -InputObject $Journal -Depth 40
    Write-WudLog -Context $Context -Level WARN -Message 'Runtime update restored the original tasks/state and verified recorder restart. The journal records the interruption; evidence was not deleted.'
}

function Invoke-WudActiveRuntimeUpdate {
    param([Parameter(Mandatory = $true)][string]$RunId, [Parameter(Mandatory = $true)][string]$RuntimePath)
    $state = Get-WudActiveRunState
    if (-not $state -or $state.RunId -ne $RunId) { throw 'The requested run is not the current active WUPA case.' }
    Assert-WudRuntimeUpdatePaths -State $state -RuntimePath $RuntimePath
    $lock = $null
    try { $lock = [IO.File]::Open((Join-Path $state.RunPath 'State/run.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Another collector is already handling this run. Retry the engine update when that pass has finished.' }
    try {
        # Re-read under the lock: another GUI may have just committed a change.
        $state = Get-WudActiveRunState
        if (-not $state -or $state.RunId -ne $RunId) { throw 'The active case changed before the engine update acquired its lock.' }
        Assert-WudRuntimeUpdatePaths -State $state -RuntimePath $RuntimePath
        $version = (Get-Content -LiteralPath (Join-Path $RuntimePath 'VERSION') -Raw).Trim()
        $contract = Read-WudJson (Join-Path $RuntimePath 'Data/update-compatibility.json')
        if ($version -notmatch '^\d+\.\d+\.\d+$' -or $contract.EngineVersion -ne $version -or [int]$state.SchemaVersion -notin @($contract.StateSchemas) -or [string]$state.ToolVersion -notin @($contract.CompatiblePreviousEngines)) { throw 'The new engine is not compatible with this run state.' }
        if ([version]$version -lt [version]$state.ToolVersion) { throw 'An active run cannot be migrated to an older engine.' }
        $ctx = New-WudRunContext -ToolRoot $RuntimePath -ToolVersion $version -RunId $RunId -RunPath $state.RunPath -OutputPath $state.OutputPath -Mode 'RuntimeUpdate' -PhaseLabel 'RuntimeUpdate' -TargetVersion $state.TargetVersion -CopyTo $state.CopyTo -MediaPath $null -AcceptWindowsEula $false -IncludeLargeDumps $false -NoInternet $true -NoSetupHooks $true -ArmDays 30
        $updates = New-WudDirectory (Join-Path $state.RunPath 'State/Updates')
        foreach ($pending in @(Get-ChildItem -LiteralPath $updates -Filter 'journal.json' -File -Recurse)) {
            $journal = Read-WudJson $pending.FullName
            if ($journal.Status -eq 'Pending') {
                Write-WudLog $ctx WARN 'Recovering an interrupted runtime update before attempting a new one.'
                Restore-WudRuntimeUpdate -Context $ctx -Journal $journal -JournalPath $pending.FullName
                $state = Get-WudActiveRunState
            }
        }
        if ([IO.Path]::GetFullPath($state.RuntimePath) -eq [IO.Path]::GetFullPath($RuntimePath)) { Write-WudLog $ctx INFO 'This active run already uses the selected engine.'; return }
        if ($state.Status -notin @('Armed', 'ResumedAwaitingTerminal', 'Tracking', 'MonitoringArmed')) { throw "This run's status '$($state.Status)' is not eligible for a recorder runtime update." }
        $resume = Get-WudOwnedTaskXml $state 'Resume'
        $recorder = Get-WudOwnedTaskXml $state 'Recorder'
        $transaction = New-WudDirectory (Join-Path $updates ([Guid]::NewGuid().ToString('N')))
        $journalPath = Join-Path $transaction 'journal.json'
        $journal = [pscustomobject][ordered]@{
            SchemaVersion = 1; Status = 'Pending'; RunId = $RunId
            StartedUtc = [DateTime]::UtcNow.ToString('o'); CompletedUtc = $null
            FromEngine = $state.ToolVersion; ToEngine = $version; OldState = $state
            ResumeTask = $resume; RecorderTask = $recorder
            PauseStartedUtc = $null; ResumeVerifiedUtc = $null; Error = $null
        }
        Write-WudJsonAtomic $journalPath $journal -Depth 40
        try {
            # Stop only our delayed resume task, after acquiring the collector
            # lock; never kill an unrelated PowerShell or Windows Setup process.
            Stop-ScheduledTask -TaskName $state.Task.TaskName -TaskPath $state.Task.TaskPath -ErrorAction Stop
            $oldScript = Join-Path $state.RuntimePath 'Invoke-Win11UpgradeDiag.ps1'
            $other = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($oldScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
            if ($other.Count) { throw 'An older WUPA entry point is still starting. Wait for it to finish, then retry; it was not killed.' }
            $journal.PauseStartedUtc = [DateTime]::UtcNow.ToString('o')
            Write-WudJsonAtomic $journalPath $journal -Depth 40
            $stopped = Stop-WudRecorderTask $state
            if ($stopped.Status -ne 'Stopped') { throw "Recorder pause failed: $($stopped.Error)" }
            Wait-WudRecorderStopped $state.RunPath
            Set-WudOwnedTaskRuntime $resume $RuntimePath
            Set-WudOwnedTaskRuntime $recorder $RuntimePath
            # Clone, don't mutate the OldState preserved in the journal.
            $newState = ConvertFrom-WudJsonText ($state | ConvertTo-Json -Depth 40)
            $newState.RuntimePath = $RuntimePath; $newState.ToolVersion = $version
            $newState | Add-Member -NotePropertyName RuntimeUpdateJournal -NotePropertyValue $journalPath -Force
            Save-WudRunState -Context $ctx -State $newState -SetActive $true
            $restart = Start-WudRecorderTask $newState
            if ($restart.Status -ne 'Started') { throw "New recorder restart could not be verified: $($restart.Status)." }
            $newState | Add-Member -NotePropertyName RecorderStart -NotePropertyValue $restart -Force
            Save-WudRunState -Context $ctx -State $newState -SetActive $true
            $journal.ResumeVerifiedUtc = [DateTime]::UtcNow.ToString('o')
            $journal.CompletedUtc = $journal.ResumeVerifiedUtc; $journal.Status = 'Completed'
            Write-WudJsonAtomic $journalPath $journal -Depth 40
            Write-WudLog -Context $ctx -Level INFO -Message ("Engine updated from {0} to {1}; recorder pause {2} to {3}. Original RunId, baseline, samples and hooks were retained." -f $state.ToolVersion, $version, $journal.PauseStartedUtc, $journal.ResumeVerifiedUtc)
        }
        catch {
            $failure = $_
            $journal.Error = Get-WudErrorDetail $failure
            Write-WudJsonAtomic $journalPath $journal -Depth 40
            try { Restore-WudRuntimeUpdate -Context $ctx -Journal $journal -JournalPath $journalPath }
            catch { Write-WudLog $ctx ERROR ("Automatic rollback requires attention: {0}. Retry Apply engine to recover the Pending journal." -f $_.Exception.Message) }
            throw $failure
        }
    }
    finally { if ($lock) { $lock.Dispose() } }
}

Export-ModuleMember -Function 'Invoke-WudActiveRuntimeUpdate'
