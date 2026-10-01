Set-StrictMode -Version 2.0

function Get-WudProgramDataRoot {
    if (-not $env:ProgramData) { throw 'ProgramData is unavailable.' }
    return (Join-Path $env:ProgramData 'WUPA')
}

function Get-WudActiveStatePath {
    return (Join-Path (Get-WudProgramDataRoot) 'ActiveRun.json')
}

function Get-WudActiveRunState {
    $path = Get-WudActiveStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Read-WudJson -Path $path }
    catch { return $null }
}

function Get-WudRunState {
    param([Parameter(Mandatory = $true)][string]$RunPath)
    return Read-WudJson -Path (Join-Path $RunPath 'State\run-state.json')
}

function Get-WudEncodedTextFileInfo {
    param([Parameter(Mandatory = $true)][string]$Path)
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = [Text.Encoding]::Default
    $preambleLength = 0
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        $encoding = New-Object Text.UTF32Encoding($false, $true)
        $preambleLength = 4
    }
    elseif ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        $encoding = New-Object Text.UTF32Encoding($true, $true)
        $preambleLength = 4
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $encoding = New-Object Text.UTF8Encoding($true)
        $preambleLength = 3
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $encoding = [Text.Encoding]::Unicode
        $preambleLength = 2
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $encoding = [Text.Encoding]::BigEndianUnicode
        $preambleLength = 2
    }
    $textLength = $bytes.Length - $preambleLength
    $text = if ($textLength -gt 0) { $encoding.GetString($bytes, $preambleLength, $textLength) } else { '' }
    $newLine = if ($text.Contains("`r`n")) { "`r`n" } elseif ($text.Contains("`n")) { "`n" } elseif ($text.Contains("`r")) { "`r" } else { "`r`n" }
    [byte[]]$preamble = New-Object byte[] $preambleLength
    if ($preambleLength -gt 0) { [Array]::Copy($bytes, 0, $preamble, 0, $preambleLength) }
    return [pscustomobject]@{ Bytes = $bytes; Encoding = $encoding; Preamble = $preamble; Text = $text; NewLine = $newLine }
}

function Write-WudEncodedTextFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][Text.Encoding]$Encoding,
        [byte[]]$Preamble = @()
    )
    if ($null -eq $Preamble) { [byte[]]$Preamble = New-Object byte[] 0 }
    [byte[]]$body = $Encoding.GetBytes([string]$Text)
    [byte[]]$content = New-Object byte[] ($Preamble.Length + $body.Length)
    if ($Preamble.Length -gt 0) { [Array]::Copy($Preamble, 0, $content, 0, $Preamble.Length) }
    if ($body.Length -gt 0) { [Array]::Copy($body, 0, $content, $Preamble.Length, $body.Length) }
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporary, $content)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Save-WudRunState {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [bool]$SetActive = $true
    )
    $statePath = Join-Path $Context.RunPath 'State\run-state.json'
    $State.StatePath = $statePath
    Write-WudJsonAtomic -Path $statePath -InputObject $State -Depth 30
    if ($SetActive) {
        $activeRoot = New-WudDirectory -Path (Get-WudProgramDataRoot)
        $null = $activeRoot
        Write-WudJsonAtomic -Path (Get-WudActiveStatePath) -InputObject $State -Depth 30
    }
}

function Get-WudLightOsIdentity {
    $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    return [pscustomobject][ordered]@{
        ComputerName   = $env:COMPUTERNAME
        DisplayVersion = $version.DisplayVersion
        CurrentBuild   = $version.CurrentBuild
        UBR            = $version.UBR
        ProductName    = $version.ProductName
        EditionId      = $version.EditionID
        CapturedUtc    = [DateTime]::UtcNow.ToString('o')
    }
}

function Resolve-WudAutomaticMode {
    param([string]$ToolRoot, [string]$TargetVersion = '25H2')
    $active = Get-WudActiveRunState
    if ($active) { return 'Resume' }
    $identity = Get-WudLightOsIdentity
    $targetBuild = 26200
    if ($ToolRoot) {
        try { $targetBuild = [int](Get-WudTargetDefinition -ToolRoot $ToolRoot -TargetVersion $TargetVersion).buildFamily }
        catch { }
    }
    if ($identity.DisplayVersion -eq $TargetVersion -or [int]$identity.CurrentBuild -ge $targetBuild) { return 'Forensic' }
    $rollbackCandidates = @(
        (Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\Rollback\setupact.log'),
        (Join-Path $env:SystemRoot 'Panther\setupact.log'),
        (Join-Path $env:SystemRoot 'Logs\SetupDiag\SetupDiagResults.xml')
    )
    foreach ($candidate in $rollbackCandidates) {
        if (Test-Path -LiteralPath $candidate) {
            try {
                if ((Get-Item -LiteralPath $candidate).LastWriteTimeUtc -ge [DateTime]::UtcNow.AddDays(-30)) { return 'Forensic' }
            }
            catch { }
        }
    }
    return 'Preflight'
}

function Install-WudRuntimeCopy {
    param([Parameter(Mandatory = $true)]$Context)
    $runtimeRoot = New-WudDirectory -Path (Join-Path (Get-WudProgramDataRoot) ("Runtime\{0}" -f $Context.ToolVersion))
    $sourceFull = [IO.Path]::GetFullPath($Context.ToolRoot).TrimEnd('\')
    $runtimeFull = [IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\')
    if ($sourceFull -eq $runtimeFull) { return $runtimeRoot }
    foreach ($file in @('Invoke-Win11UpgradeDiag.ps1', 'Watch-Win11Upgrade.ps1', 'Update-WupaActiveRun.ps1', 'BundleManifest.sha256', 'VERSION', 'NOTICE.md')) {
        $source = Join-Path $Context.ToolRoot $file
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $runtimeRoot $file) -Force }
    }
    foreach ($folder in @('Modules', 'Data', 'Assets')) {
        $source = Join-Path $Context.ToolRoot $folder
        $destination = Join-Path $runtimeRoot $folder
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force -ErrorAction Stop }
        Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force -ErrorAction Stop
    }
    return $runtimeRoot
}

function Protect-WudRunAcl {
    param([Parameter(Mandatory = $true)]$Context, [string]$Path = $Context.RunPath, [string]$Name = 'protect-staging-acl')
    $sid = Get-WudCurrentUserSid
    $arguments = @($Path, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
    if ($sid -and $sid -notin @('S-1-5-18', 'S-1-5-32-544')) { $arguments += ("*{0}:(OI)(CI)F" -f $sid) }
    $result = Invoke-WudProcess -Context $Context -FilePath 'icacls.exe' -ArgumentList $arguments -Name $Name -TimeoutSeconds 300
    return $result.Succeeded
}

function New-WudHookScripts {
    param($Context, [string]$TaskName)
    $hookPath = New-WudDirectory -Path (Join-Path (Get-WudProgramDataRoot) ("Hooks\{0}" -f $Context.RunId))
    $markers = New-WudDirectory -Path (Join-Path $Context.RunPath 'State\Markers')
    $oobeMarker = Join-Path $markers 'post-oobe.marker'
    $rollbackMarker = Join-Path $markers 'post-rollback.marker'
    $taskPath = "\WUPA\$TaskName"
    $oobe = @"
@echo off
> "$oobeMarker" echo %DATE% %TIME% PostOOBE
schtasks.exe /Run /TN "$taskPath" >nul 2>&1
exit /b 0
"@
    $rollback = @"
@echo off
> "$rollbackMarker" echo %DATE% %TIME% PostRollback
schtasks.exe /Run /TN "$taskPath" >nul 2>&1
exit /b 0
"@
    Write-WudText -Path (Join-Path $hookPath 'setupcomplete.cmd') -Text $oobe -Encoding Ascii
    Write-WudText -Path (Join-Path $hookPath 'setuprollback.cmd') -Text $rollback -Encoding Ascii
    return [pscustomobject]@{ HookPath = $hookPath; OobeMarker = $oobeMarker; RollbackMarker = $rollbackMarker }
}

function Get-WudTaskFolder {
    param(
        [Parameter(Mandatory = $true)]$ScheduleService,
        [Parameter(Mandatory = $true)]$RootFolder
    )
    # The Schedule.Service COM API rejects a folder lookup with a trailing
    # slash on current Windows 11 builds even though ScheduledTasks cmdlets
    # require that slash in -TaskPath. Resume creates the folder first; a
    # subsequent recorder lookup must therefore use the canonical COM path.
    $comPath = '\WUPA'
    try {
        return [pscustomobject]@{ Folder = $ScheduleService.GetFolder($comPath); Created = $false }
    }
    catch {
        try {
            return [pscustomobject]@{ Folder = $RootFolder.CreateFolder('WUPA'); Created = $true }
        }
        catch {
            # A concurrent/preceding registration can win between lookup and
            # creation. Re-open once so ERROR_ALREADY_EXISTS is idempotent;
            # any genuine access or COM failure remains fatal.
            return [pscustomobject]@{ Folder = $ScheduleService.GetFolder($comPath); Created = $false }
        }
    }
}

function Install-WudResumeTask {
    param($Context, [string]$RuntimePath)
    $taskName = "Resume-$($Context.RunId)"
    $taskPath = '\WUPA\'
    $folderCreated = $false
    $scheduleService = New-Object -ComObject 'Schedule.Service'
    $scheduleService.Connect()
    $rootFolder = $scheduleService.GetFolder('\')
    $folderResult = Get-WudTaskFolder -ScheduleService $scheduleService -RootFolder $rootFolder
    $folderCreated = [bool]$folderResult.Created
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $RuntimePath 'Invoke-Win11UpgradeDiag.ps1'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action Resume -RunId "{1}" -NoOpen -DelaySeconds 180' -f $script, $Context.RunId
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $RuntimePath
    $startup = New-ScheduledTaskTrigger -AtStartup
    $daily = New-ScheduledTaskTrigger -Daily -At '03:00'
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 6)
    try { Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger @($startup, $daily) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null }
    catch {
        if ($folderCreated) { try { $rootFolder.DeleteFolder('WUPA', 0) } catch { } }
        throw
    }
    return [pscustomobject]@{ TaskName = $taskName; TaskPath = $taskPath; FullName = "$taskPath$taskName"; FolderCreated = $folderCreated }
}

function Install-WudRecorderTask {
    param($Context, [string]$RuntimePath)
    $taskName = "Recorder-$($Context.RunId)"
    $taskPath = '\WUPA\'
    $scheduleService = New-Object -ComObject 'Schedule.Service'
    $scheduleService.Connect()
    $rootFolder = $scheduleService.GetFolder('\')
    $null = Get-WudTaskFolder -ScheduleService $scheduleService -RootFolder $rootFolder
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $RuntimePath 'Watch-Win11Upgrade.ps1'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RunPath "{1}" -TargetVersion "{2}" -TargetBuild {3} -IntervalSeconds {4} -ProgressBucketSize {5} -MaximumCheckpoints {6} -MaximumCheckpointFileBytes {7} -MaximumCheckpointBytes {8}' -f
        $script, $Context.RunPath, $Context.TargetVersion, $Context.Target.buildFamily,
        $Context.Settings.recorder.sampleIntervalSeconds, $Context.Settings.recorder.progressBucketPercent,
        $Context.Settings.recorder.maximumCheckpoints, $Context.Settings.recorder.maximumCheckpointFileBytes,
        $Context.Settings.recorder.maximumCheckpointBytes
    $action = New-ScheduledTaskAction -Execute $powerShell -Argument $arguments -WorkingDirectory $RuntimePath
    $startup = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $executionLimit = New-TimeSpan -Days ([Math]::Min(365, [Math]::Max(1, $Context.ArmDays + 1)))
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit $executionLimit -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $startup -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    return [pscustomobject]@{ TaskName = $taskName; TaskPath = $taskPath; FullName = "$taskPath$taskName" }
}

function Start-WudRecorderTask {
    param([Parameter(Mandatory = $true)]$State)
    $recorderTask = Get-WudObjectPropertyValue $State 'RecorderTask'
    if (-not $recorderTask) { return [pscustomobject]@{ Status = 'NotConfigured'; Error = $null } }
    try {
        $stopMarker = Join-Path $State.RunPath 'State\recorder.stop'
        if (Test-Path -LiteralPath $stopMarker) { Remove-Item -LiteralPath $stopMarker -Force -ErrorAction Stop }
        Start-ScheduledTask -TaskName $recorderTask.TaskName -TaskPath $recorderTask.TaskPath -ErrorAction Stop
        # Start-ScheduledTask confirms only that Task Scheduler accepted the
        # request. Verify that the task reached Running and that the recorder
        # process owns its exclusive lock before declaring monitoring healthy.
        $lockPath = Join-Path $State.RunPath 'State\recorder.lock'
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        $taskState = $null
        $lockHeld = $false
        do {
            try { $taskState = [string](Get-ScheduledTask -TaskName $recorderTask.TaskName -TaskPath $recorderTask.TaskPath -ErrorAction Stop).State }
            catch { $taskState = 'QueryFailed' }
            $probe = $null
            $lockHeld = $false
            if (Test-Path -LiteralPath $lockPath) {
                try { $probe = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
                catch { $lockHeld = $true }
                finally { if ($probe) { $probe.Dispose() } }
            }
            if ($taskState -eq 'Running' -and $lockHeld) {
                return [pscustomobject]@{ Status = 'Started'; Error = $null; TaskState = $taskState; RecorderLockHeld = $true; VerifiedUtc = [DateTime]::UtcNow.ToString('o') }
            }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)
        return [pscustomobject]@{
            Status = 'StartUnverified'
            Error = "Task Scheduler accepted the recorder start, but Running state plus exclusive recorder-lock ownership was not observed within 15 seconds. LastTaskState=$taskState; RecorderLockHeld=$lockHeld"
            TaskState = $taskState
            RecorderLockHeld = $lockHeld
            VerifiedUtc = [DateTime]::UtcNow.ToString('o')
        }
    }
    catch { return [pscustomobject]@{ Status = 'StartFailed'; Error = (Get-WudErrorDetail -ErrorRecord $_) } }
}

function Stop-WudRecorderTask {
    param([Parameter(Mandatory = $true)]$State)
    $stopMarker = Join-Path $State.RunPath 'State\recorder.stop'
    try { Write-WudText -Path $stopMarker -Text ([DateTime]::UtcNow.ToString('o')) }
    catch { }
    $recorderTask = Get-WudObjectPropertyValue $State 'RecorderTask'
    if (-not $recorderTask) { return [pscustomobject]@{ Status = 'NotConfigured'; Error = $null } }
    try {
        Stop-ScheduledTask -TaskName $recorderTask.TaskName -TaskPath $recorderTask.TaskPath -ErrorAction SilentlyContinue
        return [pscustomobject]@{ Status = 'Stopped'; Error = $null }
    }
    catch { return [pscustomobject]@{ Status = 'StopFailed'; Error = (Get-WudErrorDetail -ErrorRecord $_) } }
}

function Get-WudSetupConfigKey {
    param([string]$Line)
    if ($Line -match '^\s*([A-Za-z][A-Za-z0-9]*)\s*(?:=|$)') { return $matches[1] }
    return $null
}

function Install-WudSetupConfigHooks {
    param($Context, $Hooks)
    $configPath = Join-Path $env:SystemDrive 'Users\Default\AppData\Local\Microsoft\Windows\WSUS\SetupConfig.ini'
    $statePath = New-WudDirectory -Path (Join-Path $Context.RunPath 'State\Persistence')
    $backupPath = Join-Path $statePath 'SetupConfig.original'
    $metaPath = Join-Path $statePath 'SetupConfig.metadata.json'
    $originalExisted = Test-Path -LiteralPath $configPath
    $originalLines = @()
    $originalHash = $null
    $originalFileInfo = $null
    if ($originalExisted) {
        Copy-Item -LiteralPath $configPath -Destination $backupPath -Force
        $originalFileInfo = Get-WudEncodedTextFileInfo -Path $configPath
        $originalLines = @([Regex]::Split($originalFileInfo.Text, '\r\n|\n|\r'))
        $originalHash = Get-WudFileHashSafe -Path $configPath
    }
    else { $originalLines = @('[SetupConfig]') }
    $firstMeaningful = @($originalLines | Where-Object { $_ -notmatch '^\s*(?:$|[;#])' } | Select-Object -First 1)
    $metadata = [ordered]@{
        ConfigPath      = $configPath
        OriginalExisted = $originalExisted
        BackupPath      = if ($originalExisted) { $backupPath } else { $null }
        OriginalHash    = $originalHash
        ModifiedHash    = $null
        AddedEntries    = @()
        Conflicts       = @()
        Modified        = $false
        InvalidFormat   = $false
    }
    if (@($firstMeaningful).Count -eq 0 -or $firstMeaningful[0].Trim() -ine '[SetupConfig]') {
        $metadata.InvalidFormat = $true
        Write-WudJsonAtomic -Path $metaPath -InputObject ([pscustomobject]$metadata)
        return [pscustomobject]$metadata
    }
    $existingKeys = @{}
    foreach ($line in $originalLines) {
        $key = Get-WudSetupConfigKey -Line $line
        if ($key) { $existingKeys[$key.ToLowerInvariant()] = $line }
    }
    $desired = New-Object Collections.ArrayList
    $null = $desired.Add([pscustomobject]@{ Key = 'PostOOBE'; Value = $Hooks.HookPath })
    $null = $desired.Add([pscustomobject]@{ Key = 'PostRollback'; Value = $Hooks.HookPath })
    if (-not $existingKeys.ContainsKey('postrollback')) { $null = $desired.Add([pscustomobject]@{ Key = 'PostRollbackContext'; Value = 'system' }) }
    $copyLogs = New-WudDirectory -Path (Join-Path $Context.RunPath 'SetupCopyLogs')
    $null = $desired.Add([pscustomobject]@{ Key = 'CopyLogs'; Value = $copyLogs })
    $newLines = New-Object Collections.ArrayList
    foreach ($line in $originalLines) { $null = $newLines.Add($line) }
    $added = New-Object Collections.ArrayList
    $conflicts = New-Object Collections.ArrayList
    foreach ($entry in $desired) {
        $keyLower = $entry.Key.ToLowerInvariant()
        if ($existingKeys.ContainsKey($keyLower)) {
            $null = $conflicts.Add([pscustomobject]@{ Key = $entry.Key; Existing = $existingKeys[$keyLower]; RequestedValue = $entry.Value })
            continue
        }
        $line = '{0}={1}' -f $entry.Key, $entry.Value
        $null = $newLines.Add($line)
        $null = $added.Add($line)
    }
    $temporary = $null
    try {
        if (@($added).Count -gt 0) {
            $parent = New-WudDirectory -Path (Split-Path -Parent $configPath)
            $null = $parent
            $temporary = "$configPath.$([Guid]::NewGuid().ToString('N')).tmp"
            if ($originalExisted) {
                Copy-Item -LiteralPath $configPath -Destination $temporary -Force
                $prefix = if ($originalFileInfo.Text.Length -gt 0 -and $originalFileInfo.Text -notmatch '(?:\r\n|\n|\r)$') { $originalFileInfo.NewLine } else { '' }
                $appendText = $prefix + ((@($added) | ForEach-Object { [string]$_ }) -join $originalFileInfo.NewLine) + $originalFileInfo.NewLine
                [byte[]]$appendBytes = $originalFileInfo.Encoding.GetBytes($appendText)
                $stream = [IO.File]::Open($temporary, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $stream.Write($appendBytes, 0, $appendBytes.Length) }
                finally { $stream.Dispose() }
            }
            else {
                [IO.File]::WriteAllLines($temporary, [string[]]$newLines, [Text.Encoding]::ASCII)
            }
            Move-Item -LiteralPath $temporary -Destination $configPath -Force
            $temporary = $null
            $metadata.Modified = $true
            $metadata.ModifiedHash = Get-WudFileHashSafe -Path $configPath
        }
        $metadata.AddedEntries = @($added)
        $metadata.Conflicts = @($conflicts)
        Write-WudJsonAtomic -Path $metaPath -InputObject ([pscustomobject]$metadata)
        return [pscustomobject]$metadata
    }
    catch {
        if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if ($metadata.Modified) {
            if ($originalExisted -and (Test-Path -LiteralPath $backupPath)) { Copy-Item -LiteralPath $backupPath -Destination $configPath -Force }
            elseif (-not $originalExisted -and (Test-Path -LiteralPath $configPath)) { Remove-Item -LiteralPath $configPath -Force }
        }
        throw
    }
}

function Install-WudPersistence {
    param([Parameter(Mandatory = $true)]$Context)
    $task = $null
    $recorderTask = $null
    $hooks = $null
    try {
        $runtime = Install-WudRuntimeCopy -Context $Context
        if (-not (Protect-WudRunAcl -Context $Context -Path (Get-WudProgramDataRoot) -Name 'protect-programdata-acl')) { throw 'The ProgramData staging ACL could not be restricted.' }
        if (-not (Protect-WudRunAcl -Context $Context -Path $Context.RunPath -Name 'protect-run-acl')) { throw 'The run staging ACL could not be restricted.' }
        $task = Install-WudResumeTask -Context $Context -RuntimePath $runtime
        $recorderTask = Install-WudRecorderTask -Context $Context -RuntimePath $runtime
        $setupConfig = $null
        if (-not $Context.NoSetupHooks) {
            $hooks = New-WudHookScripts -Context $Context -TaskName $task.TaskName
            $setupConfig = Install-WudSetupConfigHooks -Context $Context -Hooks $hooks
        }
    }
    catch {
        if ($task) {
            try { Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        }
        if ($recorderTask) {
            try { Unregister-ScheduledTask -TaskName $recorderTask.TaskName -TaskPath $recorderTask.TaskPath -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        }
        if ($hooks -and $hooks.HookPath -and (Test-Path -LiteralPath $hooks.HookPath)) {
            try { Remove-Item -LiteralPath $hooks.HookPath -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
        throw
    }
    $identity = Get-WudLightOsIdentity
    $state = [pscustomobject][ordered]@{
        SchemaVersion      = 2
        ToolVersion       = $Context.ToolVersion
        RunId             = $Context.RunId
        RunPath           = $Context.RunPath
        RuntimePath       = $runtime
        OutputPath        = $Context.OutputPath
        TargetVersion     = $Context.TargetVersion
        TargetBuild       = $Context.Target.buildFamily
        CopyTo            = $Context.CopyTo
        CreatedUtc        = $Context.StartedUtc
        ExpiresUtc        = [DateTime]::UtcNow.AddDays($Context.ArmDays).ToString('o')
        Status            = 'Armed'
        BaselineIdentity  = $identity
        Task              = $task
        RecorderTask      = $recorderTask
        Recorder          = [pscustomobject][ordered]@{
            SampleIntervalSeconds = $Context.Settings.recorder.sampleIntervalSeconds
            ProgressBucketPercent = $Context.Settings.recorder.progressBucketPercent
            MaximumCheckpoints = $Context.Settings.recorder.maximumCheckpoints
            TelemetryPath = (Join-Path $Context.RunPath 'Evidence\Recorder\ProgressSamples.jsonl')
        }
        Hooks             = $hooks
        SetupConfig       = $setupConfig
        NoInternet        = $Context.NoInternet
        IncludeLargeDumps = $Context.IncludeLargeDumps
        NoSetupHooks      = $Context.NoSetupHooks
        StatePath         = $null
    }
    try { Save-WudRunState -Context $Context -State $state -SetActive $true }
    catch {
        try { Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        if ($recorderTask) { try { Unregister-ScheduledTask -TaskName $recorderTask.TaskName -TaskPath $recorderTask.TaskPath -Confirm:$false -ErrorAction SilentlyContinue } catch { } }
        try { $null = Restore-WudSetupConfig -Context $Context -State $state } catch { }
        if ($hooks -and $hooks.HookPath -and (Test-Path -LiteralPath $hooks.HookPath)) {
            try { Remove-Item -LiteralPath $hooks.HookPath -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
        throw
    }
    return $state
}

function Test-WudSetupInProgress {
    $processNames = @('setuphost', 'setupprep', 'SetupPlatform', 'Windows10UpgraderApp', 'WindowsUpdateBox')
    foreach ($name in $processNames) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true }
    }
    try {
        $setup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
        if ($setup.SystemSetupInProgress -eq 1 -or $setup.UpgradeInProgress -eq 1) { return $true }
    }
    catch { }
    return $false
}

function Get-WudResumeSignal {
    param([Parameter(Mandatory = $true)]$State)
    $createdUtc = ConvertTo-WudUtcDateTime $State.CreatedUtc
    $identity = Get-WudLightOsIdentity
    $signals = New-Object Collections.ArrayList
    $providerResults = New-Object Collections.ArrayList
    $upgradeIdentity = Read-WudJson -Path (Join-Path $State.RunPath 'State/upgrade-identity.json')
    $markers = @(
        @{ Kind = 'PostOOBE marker'; Path = (Join-Path $State.RunPath 'State\Markers\post-oobe.marker') },
        @{ Kind = 'PostRollback marker'; Path = (Join-Path $State.RunPath 'State\Markers\post-rollback.marker') }
    )
    foreach ($marker in $markers) {
        if ((Get-WudObjectPropertyValue $upgradeIdentity 'Status') -eq 'Locked' -and (Test-Path -LiteralPath $marker.Path)) {
            $item = Get-Item -LiteralPath $marker.Path
            if ($item.LastWriteTimeUtc -ge $createdUtc) { $null = $signals.Add([pscustomobject]@{ Kind = $marker.Kind; Source = $marker.Path; TimestampUtc = $item.LastWriteTimeUtc.ToString('o') }) }
        }
    }
    if ([string]$identity.DisplayVersion -eq [string]$State.TargetVersion -or [int]$identity.CurrentBuild -eq [int]$State.TargetBuild) {
        $null = $signals.Add([pscustomobject]@{ Kind = 'Target build reached'; Source = 'Current OS identity'; TimestampUtc = $identity.CapturedUtc })
    }
    # Global/stale SetupDiag results and unscoped error tokens cannot finish a
    # monitored case. Require a fresh terminal result for its locked identity.
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        $history = New-Object Collections.ArrayList
        if ($count -gt 0) { foreach ($entry in @($searcher.QueryHistory(0, [Math]::Min($count, 500)))) {
            $date = [DateTime]::SpecifyKind([DateTime]$entry.Date, [DateTimeKind]::Utc)
            if ($date -le $createdUtc -or [int]$entry.Operation -ne 1) { continue }
            $null = $history.Add([pscustomobject]@{ DateUtc = $date.ToString('o'); Title = $entry.Title; UpdateID = $entry.UpdateIdentity.UpdateID; RevisionNumber = $entry.UpdateIdentity.RevisionNumber; ServiceID = $entry.ServiceID; ResultCode = [int]$entry.ResultCode; HResult = $entry.HResult })
        } }
        $upgradeIdentity = Resolve-WudUpgradeIdentity -Records @($history) -TargetVersion $State.TargetVersion -ExistingLock $upgradeIdentity
        if ($upgradeIdentity.Status -eq 'Locked') { Write-WudJsonAtomic -Path (Join-Path $State.RunPath 'State/upgrade-identity.json') -InputObject $upgradeIdentity -Depth 15 }
        $latest = @($history | Where-Object { Test-WudUpgradeIdentityMatch $_ $upgradeIdentity } | Sort-Object DateUtc -Descending | Select-Object -First 1)
        $recordedEvents = @((Read-WudJsonLines -Path (Join-Path $State.RunPath 'Evidence/Recorder/UpdateEvents.jsonl')).Records | Where-Object { Test-WudUpgradeIdentityMatch $_ $upgradeIdentity } | Sort-Object TimestampUtc -Descending | Select-Object -First 1)
        foreach ($entry in $latest) {
            if ($recordedEvents.Count -gt 0 -and $recordedEvents[0].Boundary -in @('DownloadStarted', 'InstallStarted') -and ([DateTimeOffset]::Parse($recordedEvents[0].TimestampUtc)) -gt ([DateTimeOffset]::Parse($entry.DateUtc))) { continue }
            if ((Test-WudUpgradeIdentityMatch $entry $upgradeIdentity) -and $entry.ResultCode -in @(4, 5)) {
                $null = $signals.Add([pscustomobject]@{ Kind = 'Windows Update terminal result'; Source = 'Microsoft.Update.Session history'; TimestampUtc = $entry.DateUtc; ResultCode = $entry.ResultCode; HResult = $entry.HResult; Title = $entry.Title; UpdateID = $entry.UpdateID; RevisionNumber = $entry.RevisionNumber })
            }
        }
        $null = $providerResults.Add([pscustomobject]@{ Provider = 'Microsoft.Update.Session history'; Source = 'WUA COM history'; Status = 'Available'; Error = $null })
    }
    catch { $null = $providerResults.Add([pscustomobject]@{ Provider = 'Microsoft.Update.Session history'; Source = 'WUA COM history'; Status = 'Failed'; Error = Get-WudErrorDetail -ErrorRecord $_ }) }
    return [pscustomobject][ordered]@{
        Ready = @($signals).Count -gt 0
        CurrentIdentity = $identity
        Signals = @($signals)
        Providers = @($providerResults)
        EvaluatedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Restore-WudSetupConfig {
    param($Context, $State)
    $metadataPath = Join-Path $State.RunPath 'State\Persistence\SetupConfig.metadata.json'
    if (-not (Test-Path -LiteralPath $metadataPath)) { return 'NotConfigured' }
    $metadata = Read-WudJson -Path $metadataPath
    if (-not $metadata -or -not $metadata.Modified) { return 'NotModified' }
    $configPath = [string]$metadata.ConfigPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        if ($metadata.OriginalExisted -and $metadata.BackupPath -and (Test-Path -LiteralPath $metadata.BackupPath)) {
            Copy-Item -LiteralPath $metadata.BackupPath -Destination $configPath -Force
            return 'RestoredMissingFile'
        }
        return 'AlreadyAbsent'
    }
    $currentHash = Get-WudFileHashSafe -Path $configPath
    if ($currentHash -eq $metadata.ModifiedHash) {
        if ($metadata.OriginalExisted) { Copy-Item -LiteralPath $metadata.BackupPath -Destination $configPath -Force }
        else { Remove-Item -LiteralPath $configPath -Force }
        return 'RestoredExactOriginal'
    }
    $fileInfo = Get-WudEncodedTextFileInfo -Path $configPath
    $updatedText = $fileInfo.Text
    foreach ($ownedLine in @($metadata.AddedEntries)) {
        $pattern = '^(?:{0})(?:\r\n|\n|\r|$)' -f [Regex]::Escape([string]$ownedLine)
        $updatedText = [Regex]::Replace($updatedText, $pattern, '', [Text.RegularExpressions.RegexOptions]::Multiline)
    }
    Write-WudEncodedTextFileAtomic -Path $configPath -Text $updatedText -Encoding $fileInfo.Encoding -Preamble $fileInfo.Preamble
    Write-WudLog -Context $Context -Level WARN -Message 'SetupConfig changed after tracking began; only WUPA-owned entries were removed to preserve later administrator changes.'
    return 'RemovedOwnedEntriesFromDivergedFile'
}

function Remove-WudPersistence {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$State,
        [string]$FinalStatus = 'Completed',
        [bool]$KeepActivePointer = $false
    )
    $cleanup = [ordered]@{ Task = 'NotFound'; RecorderTask = 'NotFound'; SetupConfig = 'NotModified'; Hooks = 'NotFound'; ActivePointer = 'NotFound'; CompletedUtc = [DateTime]::UtcNow.ToString('o') }
    try {
        $stop = Stop-WudRecorderTask -State $State
        $cleanup.RecorderTask = $stop.Status
        $ownedRecorderTask = Get-WudObjectPropertyValue $State 'RecorderTask'
        if ($ownedRecorderTask) {
            Unregister-ScheduledTask -TaskName $ownedRecorderTask.TaskName -TaskPath $ownedRecorderTask.TaskPath -Confirm:$false -ErrorAction Stop
            $cleanup.RecorderTask = 'Removed'
        }
    }
    catch { $cleanup.RecorderTask = "Failed: $($_.Exception.Message)" }
    try {
        if ($State.Task) {
            Unregister-ScheduledTask -TaskName $State.Task.TaskName -TaskPath $State.Task.TaskPath -Confirm:$false -ErrorAction Stop
            $cleanup.Task = 'Removed'
            if ($State.Task.PSObject.Properties['FolderCreated'] -and $State.Task.FolderCreated) {
                try {
                    $service = New-Object -ComObject 'Schedule.Service'
                    $service.Connect()
                    $folder = $service.GetFolder($State.Task.TaskPath)
                    if ($folder.GetTasks(0).Count -eq 0 -and $folder.GetFolders(0).Count -eq 0) { $service.GetFolder('\').DeleteFolder('WUPA', 0) }
                }
                catch { }
            }
        }
    }
    catch { $cleanup.Task = "Failed: $($_.Exception.Message)" }
    try { $cleanup.SetupConfig = Restore-WudSetupConfig -Context $Context -State $State }
    catch { $cleanup.SetupConfig = "Failed: $($_.Exception.Message)" }
    try {
        if ($State.Hooks -and $State.Hooks.HookPath -and (Test-Path -LiteralPath $State.Hooks.HookPath)) {
            Remove-Item -LiteralPath $State.Hooks.HookPath -Recurse -Force -ErrorAction Stop
            $cleanup.Hooks = 'Removed'
        }
    }
    catch { $cleanup.Hooks = "Failed: $($_.Exception.Message)" }
    if ($KeepActivePointer) { $cleanup.ActivePointer = 'RetainedForInteractiveCopy' }
    else {
        try {
            $activePath = Get-WudActiveStatePath
            if (Test-Path -LiteralPath $activePath) {
                $active = Read-WudJson -Path $activePath
                if ($active.RunId -eq $State.RunId) {
                    Remove-Item -LiteralPath $activePath -Force
                    $cleanup.ActivePointer = 'Removed'
                }
            }
        }
        catch { $cleanup.ActivePointer = "Failed: $($_.Exception.Message)" }
    }
    $State.Status = $FinalStatus
    $State | Add-Member -NotePropertyName Cleanup -NotePropertyValue ([pscustomobject]$cleanup) -Force
    Save-WudRunState -Context $Context -State $State -SetActive $KeepActivePointer
    Write-WudJsonAtomic -Path (Join-Path $State.RunPath 'State\cleanup.json') -InputObject ([pscustomobject]$cleanup)
    return [pscustomobject]$cleanup
}

function Complete-WudDeferredCopyState {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$State)
    $activePath = Get-WudActiveStatePath
    if (Test-Path -LiteralPath $activePath) {
        $active = Read-WudJson -Path $activePath
        if ($active.RunId -eq $State.RunId) { Remove-Item -LiteralPath $activePath -Force -ErrorAction Stop }
    }
    $State.Status = 'CompletedInteractiveCopy'
    $State | Add-Member -NotePropertyName InteractiveCopyCompletedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    Save-WudRunState -Context $Context -State $State -SetActive $false
}

Export-ModuleMember -Function @(
    'Get-WudProgramDataRoot', 'Get-WudActiveRunState', 'Get-WudRunState', 'Save-WudRunState',
    'Get-WudLightOsIdentity', 'Resolve-WudAutomaticMode', 'Install-WudPersistence', 'Test-WudSetupInProgress',
    'Get-WudResumeSignal', 'Remove-WudPersistence', 'Complete-WudDeferredCopyState',
    'Install-WudRecorderTask', 'Start-WudRecorderTask', 'Stop-WudRecorderTask'
)
