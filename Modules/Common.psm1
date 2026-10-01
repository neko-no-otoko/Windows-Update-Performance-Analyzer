Set-StrictMode -Version 2.0

function Test-WudIsWindows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Test-WudAdministrator {
    if (-not (Test-WudIsWindows)) { return $false }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Test-WudInteractiveUser {
    if (-not [Environment]::UserInteractive) { return $false }
    if (-not (Test-WudIsWindows)) { return $true }
    try {
        return ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18')
    }
    catch { return $false }
}

function Get-WudCurrentUserSid {
    if (-not (Test-WudIsWindows)) { return $null }
    try { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    catch { return $null }
}

function Get-WudPublicDocumentsPath {
    <#
        Resolve the machine-wide Public Documents folder without depending on
        the identity that happens to run a preflight or SYSTEM resume pass.
    #>
    $publicRoot = [Environment]::GetEnvironmentVariable('PUBLIC')
    if (-not [string]::IsNullOrWhiteSpace($publicRoot)) {
        return [IO.Path]::GetFullPath((Join-Path $publicRoot 'Documents'))
    }

    try {
        $knownFolder = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonDocuments)
        if (-not [string]::IsNullOrWhiteSpace($knownFolder)) {
            return [IO.Path]::GetFullPath($knownFolder)
        }
    }
    catch { }

    if (-not [string]::IsNullOrWhiteSpace($env:SystemDrive)) {
        return [IO.Path]::GetFullPath((Join-Path $env:SystemDrive 'Users\Public\Documents'))
    }
    throw 'The Windows Public Documents folder could not be resolved.'
}

function New-WudDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -ItemType Directory -Path $Path -Force
    }
    return (Get-Item -LiteralPath $Path).FullName
}

function Read-WudJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return ConvertFrom-WudJsonText -Text (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
}

function ConvertFrom-WudJsonText {
    param([Parameter(Mandatory = $true)][string]$Text)
    # PowerShell 7.5 otherwise turns UTC JSON strings into DateTime objects.
    # String coercion then loses their offset when older PS5-compatible code
    # calls DateTimeOffset.Parse. Keep the PS5 wire behavior on both runtimes.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { return $Text | ConvertFrom-Json -DateKind String -ErrorAction Stop }
    return $Text | ConvertFrom-Json -ErrorAction Stop
}

function Write-WudJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()]$InputObject,
        [int]$Depth = 30
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { $null = New-WudDirectory -Path $parent }
    $temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    $json = $InputObject | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-WudText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Text,
        [ValidateSet('Utf8', 'Ascii')][string]$Encoding = 'Utf8'
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { $null = New-WudDirectory -Path $parent }
    $encoder = if ($Encoding -eq 'Ascii') { [Text.Encoding]::ASCII } else { New-Object Text.UTF8Encoding($false) }
    [IO.File]::WriteAllText($Path, $Text, $encoder)
}

function Get-WudObjectPropertyValue {
    <#
        Read an optional property without triggering Set-StrictMode when Windows,
        a COM provider, CIM, or a registry record returns a sparse object.
    #>
    param(
        $InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        try { return $property.Value }
        catch { return $Default }
    }
    return $Default
}

function Get-WudErrorDetail {
    param($ErrorRecord)
    if ($null -eq $ErrorRecord) { return 'Unknown error.' }
    $message = if ($ErrorRecord.Exception) { [string]$ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    $location = $null
    if ($ErrorRecord.PSObject.Properties['InvocationInfo'] -and $ErrorRecord.InvocationInfo) {
        $location = [string]$ErrorRecord.InvocationInfo.PositionMessage
    }
    $stack = if ($ErrorRecord.PSObject.Properties['ScriptStackTrace']) { [string]$ErrorRecord.ScriptStackTrace } else { $null }
    return (@($message, $location, $stack) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join [Environment]::NewLine
}

function ConvertTo-WudUtcDateTime {
    param([Parameter(Mandatory = $true)]$Value)
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).UtcDateTime }
    if ($Value -is [DateTime]) {
        $date = [DateTime]$Value
        if ($date.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($date, [DateTimeKind]::Utc) }
        return $date.ToUniversalTime()
    }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $parsed.UtcDateTime }
    throw "Timestamp is not a supported UTC/offset value: $Value"
}

function Get-WudTargetDefinition {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$TargetVersion
    )
    $catalog = Read-WudJson -Path (Join-Path $ToolRoot 'Data/targets.json')
    $target = @($catalog.targets | Where-Object { $_.displayVersion -eq $TargetVersion }) | Select-Object -First 1
    if (-not $target) { throw "Target version '$TargetVersion' is not defined in Data\targets.json." }
    return $target
}

function New-WudRunContext {
    param(
        [Parameter(Mandatory = $true)][string]$ToolRoot,
        [Parameter(Mandatory = $true)][string]$ToolVersion,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$RunPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$PhaseLabel,
        [Parameter(Mandatory = $true)][string]$TargetVersion,
        [string]$CopyTo,
        [string]$MediaPath,
        [bool]$AcceptWindowsEula,
        [bool]$IncludeLargeDumps,
        [bool]$NoInternet,
        [bool]$NoSetupHooks,
        [int]$ArmDays
    )
    $settings = Read-WudJson -Path (Join-Path $ToolRoot 'Data/settings.json')
    $target = Get-WudTargetDefinition -ToolRoot $ToolRoot -TargetVersion $TargetVersion
    $null = New-WudDirectory -Path $RunPath
    $evidencePath = New-WudDirectory -Path (Join-Path $RunPath 'Evidence')
    $snapshotPath = New-WudDirectory -Path (Join-Path $evidencePath $PhaseLabel)

    return [pscustomobject][ordered]@{
        SchemaVersion       = 2
        ToolVersion        = $ToolVersion
        ToolRoot           = $ToolRoot
        RunId              = $RunId
        RunPath            = $RunPath
        EvidencePath       = $evidencePath
        SnapshotPath       = $snapshotPath
        OutputPath         = $OutputPath
        Mode               = $Mode
        PhaseLabel         = $PhaseLabel
        TargetVersion      = $TargetVersion
        Target             = $target
        Settings           = $settings
        CopyTo             = $CopyTo
        MediaPath          = $MediaPath
        AcceptWindowsEula  = $AcceptWindowsEula
        IncludeLargeDumps  = $IncludeLargeDumps
        NoInternet         = $NoInternet
        NoSetupHooks       = $NoSetupHooks
        ArmDays            = $ArmDays
        StartedUtc         = [DateTime]::UtcNow.ToString('o')
        CompletedUtc       = $null
        LogPath            = (Join-Path $RunPath 'Collector.log')
        CollectorRecords   = New-Object Collections.ArrayList
        ProcessRecords     = New-Object Collections.ArrayList
        CollectionGaps     = New-Object Collections.ArrayList
        Findings           = New-Object Collections.ArrayList
        Facts              = New-Object Collections.ArrayList
        Timeline           = New-Object Collections.ArrayList
        Inventory          = [ordered]@{}
        Attempts           = New-Object Collections.ArrayList
        ExcludedEvidence   = New-Object Collections.ArrayList
        CollectionComplete = $true
        LastCopyResult     = $null
        ReviewData         = $null
        UpgradeTracking    = $null
        UpgradeTiming      = $null
        UpdateActivity     = $null
        ReviewBundle       = $null
        Recorder            = $null
        StatusModel        = [pscustomobject][ordered]@{
            CurrentOsState   = 'Unreadable'
            BuildTransition  = 'NotObserved'
            AttemptOutcome   = 'NotObserved'
            DeploymentSource = 'Unattributed'
            OutcomeBanner    = 'No Upgrade Outcome Observed'
            TargetPresent    = $false
            WindowsUpdateEvidenceConfirmed = $false
            ObservedBuilds   = @()
        }
        Outcome            = 'Not Determined'
        PrimaryFinding     = $null
        ExitCode           = 0
    }
}

function Write-WudLog {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory = $true)][string]$Message
    )
    $line = '{0} [{1}] {2}' -f [DateTime]::UtcNow.ToString('o'), $Level, $Message
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN' { 'Yellow' }
        'DEBUG' { 'DarkGray' }
        default { 'Gray' }
    }
    try { Write-Host $line -ForegroundColor $color }
    catch { Write-Output $line }
    try {
        $parent = Split-Path -Parent $Context.LogPath
        if ($parent) { $null = New-WudDirectory -Path $parent }
        [IO.File]::AppendAllText($Context.LogPath, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
}

function ConvertTo-WudCommandLineArgument {
    param([AllowEmptyString()][string]$Value)
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function ConvertTo-WudCsvCell {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -isnot [string]) { return $Value }
    # Excel and similar spreadsheet applications can execute formula-like CSV
    # fields. Preserve the visible value while forcing text interpretation.
    if ($Value -match '^[\t\r\n ]*[=+\-@]') { return "'$Value" }
    return $Value
}

function Add-WudCollectionGap {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Collector,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$Detail,
        [ValidateSet('Optional', 'Material')][string]$Impact = 'Optional'
    )
    $gap = [pscustomobject][ordered]@{
        Collector  = $Collector
        Source     = $Source
        Status     = $Status
        Detail     = $Detail
        Impact     = $Impact
        RecordedUtc = [DateTime]::UtcNow.ToString('o')
    }
    if ($Context.PSObject.Properties['CollectionGaps']) { $null = $Context.CollectionGaps.Add($gap) }
    if ($Impact -eq 'Material') { $Context.CollectionComplete = $false }
    return $gap
}

function Get-WudArtifactObservation {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject][ordered]@{ Path = $Path; Exists = $false; Present = $false; IsDirectory = $false; FileCount = 0; Length = 0L; LastWriteUtc = $null; Sha256 = $null; Fingerprint = 'Absent' }
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        $hash = Get-WudFileHashSafe -Path $Path
        return [pscustomobject][ordered]@{
            Path = $Path; Exists = $true; Present = $true; IsDirectory = $false; FileCount = 1; Length = [long]$item.Length
            LastWriteUtc = $item.LastWriteTimeUtc.ToString('o'); Sha256 = $hash
            Fingerprint = 'File|{0}|{1}|{2}' -f $item.Length, $item.LastWriteTimeUtc.Ticks, $hash
        }
    }
    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue)
    $length = 0L
    $latest = $null
    foreach ($file in $files) {
        $length += [long]$file.Length
        if ($null -eq $latest -or $file.LastWriteTimeUtc -gt $latest) { $latest = $file.LastWriteTimeUtc }
    }
    return [pscustomobject][ordered]@{
        Path = $Path; Exists = $true; Present = $files.Count -gt 0; IsDirectory = $true; FileCount = $files.Count; Length = $length
        LastWriteUtc = if ($latest) { $latest.ToString('o') } else { $null }; Sha256 = $null
        Fingerprint = 'Directory|{0}|{1}|{2}' -f $files.Count, $length, $(if ($latest) { $latest.Ticks } else { 0 })
    }
}

function Invoke-WudProcess {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$TimeoutSeconds = 600,
        [int[]]$SuccessExitCodes = @(0),
        [string]$WorkingDirectory,
        [string[]]$ExpectedArtifacts = @()
    )
    $commandPath = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Commands')
    $safeName = ($Name -replace '[^A-Za-z0-9._-]', '_')
    $stdoutPath = Join-Path $commandPath ($safeName + '.stdout.txt')
    $stderrPath = Join-Path $commandPath ($safeName + '.stderr.txt')
    $argumentLine = (($ArgumentList | ForEach-Object { ConvertTo-WudCommandLineArgument -Value ([string]$_) }) -join ' ')
    $artifactBefore = @{}
    foreach ($artifactPath in @($ExpectedArtifacts)) { $artifactBefore[$artifactPath] = Get-WudArtifactObservation -Path $artifactPath }
    $started = [DateTime]::UtcNow
    Write-WudLog -Context $Context -Level INFO -Message ("Running {0}" -f $Name)
    $process = $null
    $timedOut = $false
    $errorMessage = $null
    $errorDetail = $null
    $exitCode = $null
    $processId = $null
    $processHandle = $null
    try {
        $parameters = @{
            FilePath               = $FilePath
            PassThru               = $true
            RedirectStandardOutput = $stdoutPath
            RedirectStandardError  = $stderrPath
        }
        # Windows PowerShell 5.1 rejects Start-Process -ArgumentList '' even
        # though no arguments is valid for commands such as systeminfo and
        # mountvol. Do not bind the parameter for an empty argument array.
        if (@($ArgumentList).Count -gt 0) { $parameters.ArgumentList = $argumentLine }
        if ($WorkingDirectory) { $parameters.WorkingDirectory = $WorkingDirectory }
        $process = Start-Process @parameters
        $processId = $process.Id
        # On current Windows 11 builds, Windows PowerShell 5.1 can discard the
        # native handle returned by Start-Process -PassThru unless -Wait is also
        # specified. That leaves HasExited available but ExitCode permanently
        # null. Open the handle while the process is alive so timeout polling and
        # the eventual exit code are both reliable. This is intentionally before
        # the first HasExited check, including for commands that exit immediately.
        $processHandle = $process.Handle
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $process.HasExited) {
            if ([DateTime]::UtcNow -ge $deadline) {
                $timedOut = $true
                try { Stop-Process -Id $process.Id -Force -ErrorAction Stop }
                catch { }
                break
            }
            Start-Sleep -Milliseconds 500
            $process.Refresh()
        }
        try { $process.WaitForExit() } catch { }
        if (-not $timedOut) {
            $process.Refresh()
            $exitCode = [int]$process.ExitCode
        }
    }
    catch {
        $errorMessage = $_.Exception.Message
        $errorDetail = Get-WudErrorDetail -ErrorRecord $_
        Write-WudText -Path $stderrPath -Text $errorDetail
    }
    $ended = [DateTime]::UtcNow
    $succeeded = (-not $timedOut) -and ($null -ne $exitCode) -and ($SuccessExitCodes -contains [int]$exitCode)
    $artifactRecords = @($ExpectedArtifacts | ForEach-Object {
        $after = Get-WudArtifactObservation -Path $_
        $before = $artifactBefore[$_]
        [pscustomobject][ordered]@{
            Path = $_
            Present = $after.Present
            ChangedDuringProcess = $after.Present -and $after.Fingerprint -ne $before.Fingerprint
            FileCount = $after.FileCount
            Length = $after.Length
            LastWriteUtc = $after.LastWriteUtc
            Sha256 = $after.Sha256
        }
    })
    $artifactsCaptured = @($artifactRecords).Count -gt 0 -and @($artifactRecords | Where-Object { $_.Present -and $_.ChangedDuringProcess }).Count -eq @($artifactRecords).Count
    $executionStatus = if ($timedOut) { 'TimedOut' }
        elseif ($errorMessage) { 'StartFailed' }
        elseif ($null -eq $exitCode) { 'ExitCodeUnavailable' }
        elseif ($succeeded) { 'Succeeded' }
        else { 'ExitedNonzero' }
    if ($executionStatus -ne 'Succeeded' -and $artifactsCaptured) { $executionStatus = 'ArtifactCapturedDespiteProcessUncertainty' }
    $detail = switch ($executionStatus) {
        'Succeeded' { 'Process completed with an accepted exit code.' }
        'TimedOut' { "Process exceeded its $TimeoutSeconds second limit." }
        'StartFailed' { $errorDetail }
        'ExitCodeUnavailable' { 'The process object did not expose an exit code.' }
        'ArtifactCapturedDespiteProcessUncertainty' { 'Every expected artifact was captured, but process completion could not be confirmed.' }
        default { "Process exited with code $exitCode (0x{0:X8})." -f ([long]$exitCode -band 0xFFFFFFFFL) }
    }
    $result = [pscustomobject][ordered]@{
        Name          = $Name
        FilePath      = $FilePath
        Arguments     = $ArgumentList
        StartedUtc    = $started.ToString('o')
        EndedUtc      = $ended.ToString('o')
        DurationMs    = [int]($ended - $started).TotalMilliseconds
        ProcessId     = $processId
        ExitCode      = $exitCode
        ExitCodeHex   = if ($null -ne $exitCode) { '0x{0:X8}' -f ([long]$exitCode -band 0xFFFFFFFFL) } else { $null }
        TimedOut      = $timedOut
        Succeeded     = $succeeded
        ExecutionStatus = $executionStatus
        ExitCodeAvailable = $null -ne $exitCode
        Detail        = $detail
        ExpectedArtifacts = @($artifactRecords)
        StandardOut  = $stdoutPath
        StandardError = $stderrPath
        Error         = $errorMessage
        ErrorDetail   = $errorDetail
    }
    Write-WudJsonAtomic -Path (Join-Path $commandPath ($safeName + '.result.json')) -InputObject $result
    if ($Context.PSObject.Properties['ProcessRecords']) { $null = $Context.ProcessRecords.Add($result) }
    if ($executionStatus -eq 'TimedOut') { Write-WudLog -Context $Context -Level WARN -Message "$Name exceeded its $TimeoutSeconds second limit and was stopped." }
    elseif ($executionStatus -eq 'StartFailed') { Write-WudLog -Context $Context -Level WARN -Message "$Name could not start: $errorDetail" }
    elseif ($executionStatus -eq 'ArtifactCapturedDespiteProcessUncertainty') { Write-WudLog -Context $Context -Level WARN -Message "$Name produced every expected artifact, but process completion was uncertain." }
    elseif (-not $succeeded) { Write-WudLog -Context $Context -Level WARN -Message ("{0} returned an explicit status of {1}: {2}" -f $Name, $executionStatus, $detail) }
    return $result
}

function Invoke-WudCollector {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [bool]$Required = $false
    )
    $started = [DateTime]::UtcNow
    $processRecordStart = if ($Context.PSObject.Properties['ProcessRecords']) { @($Context.ProcessRecords).Count } else { 0 }
    $collectionGapStart = if ($Context.PSObject.Properties['CollectionGaps']) { @($Context.CollectionGaps).Count } else { 0 }
    $status = 'Succeeded'
    $detail = $null
    Write-WudLog -Context $Context -Level INFO -Message ("Collector {0}: {1}" -f $Id, $Description)
    try {
        & $ScriptBlock
    }
    catch {
        $status = 'Failed'
        $detail = Get-WudErrorDetail -ErrorRecord $_
        if ($Required) { $Context.CollectionComplete = $false }
        Write-WudLog -Context $Context -Level WARN -Message ("Collector {0} failed: {1}" -f $Id, $detail)
    }
    if ($status -eq 'Succeeded' -and $Context.PSObject.Properties['ProcessRecords']) {
        $newProcessRecords = @($Context.ProcessRecords | Select-Object -Skip $processRecordStart)
        $timedOut = @($newProcessRecords | Where-Object TimedOut)
        $unsuccessful = @($newProcessRecords | Where-Object { -not $_.Succeeded -and -not $_.TimedOut })
        if (@($timedOut).Count -gt 0) {
            $status = 'TimedOut'
            $detail = 'Timed out: ' + (@($timedOut | ForEach-Object Name) -join ', ')
            if ($Required) { $Context.CollectionComplete = $false }
            $null = Add-WudCollectionGap -Context $Context -Collector $Id -Source (@($timedOut | ForEach-Object FilePath) -join '; ') -Status 'TimedOut' -Detail $detail -Impact $(if ($Required) { 'Material' } else { 'Optional' })
        }
        elseif (@($unsuccessful).Count -gt 0) {
            $status = 'CompletedWithWarnings'
            $detail = 'Explicit non-success process result: ' + (@($unsuccessful | ForEach-Object {
                '{0} [{1}] {2}' -f (Get-WudObjectPropertyValue $_ 'Name' '<unnamed-process>'), (Get-WudObjectPropertyValue $_ 'ExecutionStatus' 'UnknownStatus'), (Get-WudObjectPropertyValue $_ 'Detail' (Get-WudObjectPropertyValue $_ 'ExitCodeHex' '<no-exit-code>'))
            }) -join ', ')
        }
    }
    if ($status -in @('Succeeded', 'CompletedWithWarnings') -and $Context.PSObject.Properties['CollectionGaps']) {
        $newGaps = @($Context.CollectionGaps | Select-Object -Skip $collectionGapStart)
        if ($newGaps.Count -gt 0) {
            $gapDetail = 'Recorded evidence/provider status: ' + (@($newGaps | ForEach-Object {
                '{0} [{1}]' -f (Get-WudObjectPropertyValue $_ 'Source' '<unknown-source>'), (Get-WudObjectPropertyValue $_ 'Status' 'UnknownStatus')
            }) -join ', ')
            if ($status -eq 'Succeeded') { $status = 'CompletedWithWarnings'; $detail = $gapDetail }
            else { $detail = (@($detail, $gapDetail) | Where-Object { $_ }) -join ' | ' }
        }
    }
    $ended = [DateTime]::UtcNow
    $record = [pscustomobject][ordered]@{
        Id          = $Id
        Version     = $Context.ToolVersion
        Description = $Description
        Required    = $Required
        Status      = $status
        Detail      = $detail
        StartedUtc  = $started.ToString('o')
        EndedUtc    = $ended.ToString('o')
        DurationMs  = [int]($ended - $started).TotalMilliseconds
    }
    $null = $Context.CollectorRecords.Add($record)
    return $record
}

function Add-WudFinding {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Finding)
    $existing = @($Context.Findings | Where-Object { $_.Id -eq $Finding.Id -and $_.InstanceKey -eq $Finding.InstanceKey }) | Select-Object -First 1
    if ($existing) {
        foreach ($evidence in @($Finding.Evidence)) {
            if (-not (@($existing.Evidence | Where-Object { $_.Reference -eq $evidence.Reference }).Count)) {
                $null = $existing.Evidence.Add($evidence)
            }
        }
        return $existing
    }
    if (-not $Finding.PSObject.Properties['Evidence']) {
        $Finding | Add-Member -NotePropertyName Evidence -NotePropertyValue (New-Object Collections.ArrayList)
    }
    $null = $Context.Findings.Add($Finding)
    return $Finding
}

function Add-WudTimelineEvent {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)]$Event)
    $null = $Context.Timeline.Add($Event)
}

function Get-WudRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Path
    )
    try {
        $baseFull = [IO.Path]::GetFullPath($BasePath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $pathFull = [IO.Path]::GetFullPath($Path)
        $baseUri = New-Object Uri($baseFull)
        $pathUri = New-Object Uri($pathFull)
        return [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('/', [IO.Path]::DirectorySeparatorChar)
    }
    catch { return $Path }
}

function ConvertTo-WudExtendedLengthPath {
    <#
        Windows PowerShell 5.1 can enumerate a staged file and still fail to
        open it when its absolute path crosses the legacy Win32 path limit.
        The extended-length prefix keeps the same local/UNC target while
        bypassing that normalization limit for System.IO stream operations.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$ForceWindows
    )
    $isWindowsPath = $ForceWindows -or (Test-WudIsWindows)
    $fullPath = if ($ForceWindows) { $Path } else { [IO.Path]::GetFullPath($Path) }
    if (-not $isWindowsPath -or $fullPath.StartsWith('\\?\', [StringComparison]::Ordinal)) { return $fullPath }
    if ($fullPath.StartsWith('\\', [StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $fullPath.Substring(2)
    }
    return '\\?\' + $fullPath
}

function ConvertFrom-WudExtendedLengthPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\', [StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring(4) }
    return $Path
}

function Get-WudFileTreeSafe {
    <#
        Enumerate staged evidence without the Windows PowerShell 5.1 / Win32
        MAX_PATH recursion boundary. Directory reparse points are never followed.
        Returned records expose only the file properties used by inventory and
        archive generation, keeping their paths in normal operator-readable form.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        $Context,
        [string]$Collector = 'filesystem-enumeration'
    )
    $records = New-Object Collections.ArrayList
    if (-not (Test-Path -LiteralPath $RootPath)) { return @() }
    if (-not (Test-WudIsWindows)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $RootPath -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            $null = $records.Add($file)
        }
        return @($records)
    }

    $rootFullPath = [IO.Path]::GetFullPath($RootPath)
    $rootIoPath = ConvertTo-WudExtendedLengthPath -Path $rootFullPath
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push($rootIoPath)
    while ($pending.Count -gt 0) {
        $directoryIoPath = $pending.Pop()
        try { $filePaths = @([IO.Directory]::GetFiles($directoryIoPath) | Sort-Object) }
        catch {
            if ($Context) {
                $source = ConvertFrom-WudExtendedLengthPath -Path $directoryIoPath
                $null = Add-WudCollectionGap -Context $Context -Collector $Collector -Source $source -Status 'ArchiveEnumerationFailed' -Detail (Get-WudErrorDetail -ErrorRecord $_)
            }
            continue
        }
        foreach ($fileIoPath in $filePaths) {
            try {
                $fileInfo = New-Object IO.FileInfo($fileIoPath)
                $normalPath = ConvertFrom-WudExtendedLengthPath -Path $fileIoPath
                $null = $records.Add([pscustomobject][ordered]@{
                    Name = $fileInfo.Name
                    FullName = $normalPath
                    Attributes = $fileInfo.Attributes
                    Length = [long]$fileInfo.Length
                    LastWriteTime = $fileInfo.LastWriteTime
                    LastWriteTimeUtc = $fileInfo.LastWriteTimeUtc
                })
            }
            catch {
                if ($Context) {
                    $source = ConvertFrom-WudExtendedLengthPath -Path $fileIoPath
                    $null = Add-WudCollectionGap -Context $Context -Collector $Collector -Source $source -Status 'ArchiveEnumerationFailed' -Detail (Get-WudErrorDetail -ErrorRecord $_)
                }
            }
        }

        try { $directoryPaths = @([IO.Directory]::GetDirectories($directoryIoPath) | Sort-Object) }
        catch {
            if ($Context) {
                $source = ConvertFrom-WudExtendedLengthPath -Path $directoryIoPath
                $null = Add-WudCollectionGap -Context $Context -Collector $Collector -Source $source -Status 'ArchiveEnumerationFailed' -Detail (Get-WudErrorDetail -ErrorRecord $_)
            }
            continue
        }
        for ($index = $directoryPaths.Count - 1; $index -ge 0; $index--) {
            $childIoPath = $directoryPaths[$index]
            try {
                $attributes = [IO.File]::GetAttributes($childIoPath)
                if (([int]$attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                    if ($Context) {
                        $source = ConvertFrom-WudExtendedLengthPath -Path $childIoPath
                        $null = Add-WudCollectionGap -Context $Context -Collector $Collector -Source $source -Status 'ArchiveReparsePointSkipped' -Detail 'The staged directory is a filesystem reparse point. Its target was not followed.'
                    }
                    continue
                }
                $pending.Push($childIoPath)
            }
            catch {
                if ($Context) {
                    $source = ConvertFrom-WudExtendedLengthPath -Path $childIoPath
                    $null = Add-WudCollectionGap -Context $Context -Collector $Collector -Source $source -Status 'ArchiveEnumerationFailed' -Detail (Get-WudErrorDetail -ErrorRecord $_)
                }
            }
        }
    }
    return @($records)
}

function Open-WudFileReadStream {
    param([Parameter(Mandatory = $true)][string]$Path)
    $readShare = [IO.FileShare]([int][IO.FileShare]::ReadWrite -bor [int][IO.FileShare]::Delete)
    try {
        return [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $readShare)
    }
    catch {
        if (-not (Test-WudIsWindows)) { throw }
        $extendedPath = ConvertTo-WudExtendedLengthPath -Path $Path
        if ($extendedPath -eq $Path) { throw }
        return [IO.File]::Open($extendedPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $readShare)
    }
}

function Get-WudNativeTraceSources {
    param([string]$WindowsRoot = $env:SystemRoot, [string]$SystemDrive = $env:SystemDrive, [string]$ProgramDataRoot = $env:ProgramData, [string]$RunPath)
    $sources = @(
        @{ Name = 'WindowsUpdate-ETL'; Path = (Join-Path $WindowsRoot 'Logs/WindowsUpdate') },
        @{ Name = 'USOShared-Logs'; Path = (Join-Path $ProgramDataRoot 'USOShared/Logs') },
        @{ Name = 'USOPrivate-ETL'; Path = (Join-Path $ProgramDataRoot 'USOPrivate') },
        @{ Name = 'DeliveryOptimization-Logs'; Path = (Join-Path $ProgramDataRoot 'Microsoft/Windows/DeliveryOptimization/Logs') },
        @{ Name = 'DeliveryOptimization-NetworkService-Logs'; Path = (Join-Path $WindowsRoot 'ServiceProfiles/NetworkService/AppData/Local/Microsoft/Windows/DeliveryOptimization/Logs') },
        @{ Name = 'WindowsBT-Panther'; Path = (Join-Path $SystemDrive '$WINDOWS.~BT/Sources/Panther') },
        @{ Name = 'WindowsBT-Rollback'; Path = (Join-Path $SystemDrive '$WINDOWS.~BT/Sources/Rollback') },
        @{ Name = 'WindowsBT-NewOS-ETL'; Path = (Join-Path $SystemDrive '$WINDOWS.~BT/NewOS/Windows/Panther') },
        @{ Name = 'WindowsBT-SafeOS-ETL'; Path = (Join-Path $SystemDrive '$WINDOWS.~BT/Sources/SafeOS') },
        @{ Name = 'Windows-Panther-ETL-Context'; Path = (Join-Path $WindowsRoot 'Panther') },
        @{ Name = 'Windows-MoSetup'; Path = (Join-Path $WindowsRoot 'Logs/MoSetup') },
        @{ Name = 'WindowsOld-Panther'; Path = (Join-Path $SystemDrive 'Windows.old/Windows/Panther') },
        @{ Name = 'WindowsOld-WindowsUpdate-ETL'; Path = (Join-Path $SystemDrive 'Windows.old/Windows/Logs/WindowsUpdate') }
    )
    if ($RunPath) { $sources += @{ Name = 'WUPA-SetupCopyLogs'; Path = (Join-Path $RunPath 'SetupCopyLogs') } }
    return $sources
}

function Copy-WudNativeTraceFile {
    param([Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Destination)
    $inputStream = $null; $outputStream = $null; $bytes = 0L; $initial = $null
    try {
        $initial = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        $inputStream = Open-WudFileReadStream -Path $Source
        # Bound the snapshot to the length at open: an active writer must not
        # keep this copy running indefinitely. Never stop a service to flush.
        $remaining = $inputStream.Length
        $null = New-WudDirectory -Path (Split-Path -Parent $Destination)
        $outputStream = [IO.File]::Open((ConvertTo-WudExtendedLengthPath $Destination), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $buffer = New-Object byte[] 1048576
        while ($remaining -gt 0) {
            $count = $inputStream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
            if ($count -eq 0) { break }
            $outputStream.Write($buffer, 0, $count); $bytes += $count; $remaining -= $count
        }
        $outputStream.Dispose(); $outputStream = $null
        $inputStream.Dispose(); $inputStream = $null
        $after = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        $status = if ($remaining -gt 0) { 'PartialCapture' } elseif ($initial.Length -ne $after.Length -or $initial.LastWriteTimeUtc -ne $after.LastWriteTimeUtc) { 'ChangedDuringCapture' } else { 'CapturedUnflushed' }
        return [pscustomobject][ordered]@{ Source = $Source; Destination = $Destination; Status = $status; SourceLength = $initial.Length; CapturedLength = $bytes; SourceLastWriteUtc = $initial.LastWriteTimeUtc.ToString('o'); Sha256 = Get-WudFileHashSafe $Destination; Error = $null }
    }
    catch {
        return [pscustomobject][ordered]@{ Source = $Source; Destination = $Destination; Status = 'CopyFailed'; SourceLength = if ($initial) { $initial.Length } else { $null }; CapturedLength = $bytes; SourceLastWriteUtc = $null; Sha256 = if (Test-Path -LiteralPath $Destination) { Get-WudFileHashSafe $Destination } else { $null }; Error = Get-WudErrorDetail $_ }
    }
    finally { if ($inputStream) { $inputStream.Dispose() }; if ($outputStream) { $outputStream.Dispose() } }
}

function Get-WudFileHashSafe {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = $null
    $sha = $null
    try {
        $stream = Open-WudFileReadStream -Path $Path
        $sha = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
    }
    catch { return $null }
    finally {
        if ($sha) { $sha.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Get-WudFileInventory {
    param(
        [Parameter(Mandatory = $true)][string]$RootPath,
        $Context
    )
    $items = New-Object Collections.ArrayList
    if (-not (Test-Path -LiteralPath $RootPath)) { return @() }
    foreach ($file in @(Get-WudFileTreeSafe -RootPath $RootPath -Context $Context -Collector 'report-manifest')) {
        $isReparsePoint = ([int]$file.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0
        $length = $null
        $lastWriteUtc = $null
        try { $length = [long]$file.Length } catch { }
        try { $lastWriteUtc = $file.LastWriteTimeUtc.ToString('o') } catch { }
        $item = [pscustomobject][ordered]@{
            RelativePath = Get-WudRelativePath -BasePath $RootPath -Path $file.FullName
            StagedPath   = $file.FullName
            Length       = $length
            LastWriteUtc = $lastWriteUtc
            Sha256       = if ($isReparsePoint) { $null } else { Get-WudFileHashSafe -Path $file.FullName }
            IsReparsePoint = $isReparsePoint
            ArchiveEligible = (-not $isReparsePoint)
        }
        $null = $items.Add($item)
    }
    return @($items)
}

function Export-WudRegistryTree {
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [int]$MaximumDepth = 8
    )
    $records = New-Object Collections.ArrayList
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        Write-WudJsonAtomic -Path $OutputPath -InputObject @()
        return @()
    }
    $rootDepth = ($RegistryPath -split '[\\/]').Count
    $keys = @((Get-Item -LiteralPath $RegistryPath -ErrorAction Stop)) + @(Get-ChildItem -LiteralPath $RegistryPath -Recurse -ErrorAction SilentlyContinue)
    foreach ($key in $keys) {
        $depth = (($key.PSPath -split '[\\/]').Count - $rootDepth)
        if ($depth -gt $MaximumDepth) { continue }
        $values = [ordered]@{}
        try {
            $properties = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            foreach ($property in $properties.PSObject.Properties) {
                if ($property.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') {
                    $value = $property.Value
                    if ($value -is [byte[]]) { $value = [Convert]::ToBase64String($value) }
                    $values[$property.Name] = $value
                }
            }
        }
        catch { }
        $null = $records.Add([pscustomobject][ordered]@{ Path = $key.Name; Values = $values })
    }
    Write-WudJsonAtomic -Path $OutputPath -InputObject @($records)
    return @($records)
}

function ConvertTo-WudByteSize {
    param([long]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-WudSeverityRank {
    param([string]$Severity)
    switch ($Severity) {
        'Blocker' { return 4 }
        'Error' { return 3 }
        'Warning' { return 2 }
        default { return 1 }
    }
}

function Get-WudConfidenceRank {
    param([string]$Confidence)
    switch ($Confidence) {
        'High' { return 3 }
        'Medium' { return 2 }
        default { return 1 }
    }
}

function Resolve-WudExitCode {
    param([Parameter(Mandatory = $true)]$Context)
    if (-not $Context.CollectionComplete) { return 30 }
    if (@($Context.Findings | Where-Object { $_.Status -ne 'Historical' -and $_.Severity -in @('Blocker', 'Error') }).Count -gt 0 -or $Context.Outcome -in @('Blocked', 'Rolled Back', 'Failed')) { return 20 }
    if (@($Context.Findings | Where-Object { $_.Status -ne 'Historical' -and $_.Severity -eq 'Warning' }).Count -gt 0 -or $Context.Outcome -eq 'Attention Required') { return 10 }
    return 0
}

Export-ModuleMember -Function @(
    'Test-WudIsWindows', 'Test-WudAdministrator', 'Test-WudInteractiveUser', 'Get-WudCurrentUserSid',
    'Get-WudPublicDocumentsPath',
    'New-WudDirectory', 'Read-WudJson', 'ConvertFrom-WudJsonText', 'Write-WudJsonAtomic', 'Write-WudText', 'Get-WudTargetDefinition',
    'New-WudRunContext', 'Write-WudLog', 'Invoke-WudProcess', 'Invoke-WudCollector', 'Add-WudFinding',
    'Add-WudTimelineEvent', 'Get-WudRelativePath', 'Get-WudFileHashSafe', 'Get-WudFileInventory',
    'ConvertTo-WudExtendedLengthPath', 'ConvertFrom-WudExtendedLengthPath', 'Get-WudFileTreeSafe', 'Open-WudFileReadStream',
    'Export-WudRegistryTree', 'ConvertTo-WudByteSize', 'Get-WudSeverityRank', 'Get-WudConfidenceRank',
    'Resolve-WudExitCode', 'ConvertTo-WudCommandLineArgument', 'ConvertTo-WudCsvCell', 'Add-WudCollectionGap',
    'Get-WudObjectPropertyValue', 'Get-WudErrorDetail', 'ConvertTo-WudUtcDateTime',
    'Get-WudNativeTraceSources', 'Copy-WudNativeTraceFile'
)
