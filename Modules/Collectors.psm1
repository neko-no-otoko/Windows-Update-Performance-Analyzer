Set-StrictMode -Version 2.0

function Invoke-WudOptionalProvider {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$Collector,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )
    try { return @(& $ScriptBlock) }
    catch {
        $null = Add-WudCollectionGap -Context $Context -Collector $Collector -Source $Source -Status 'ProviderFailed' -Detail (Get-WudErrorDetail -ErrorRecord $_)
        return @()
    }
}

function ConvertTo-WudCimRecord {
    param($InputObject, [string[]]$Properties)
    if ($null -eq $InputObject) { return $null }
    $record = [ordered]@{}
    foreach ($name in $Properties) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($property) { $record[$name] = $property.Value }
    }
    return [pscustomobject]$record
}

function Get-WudCimRecords {
    param([string]$ClassName, [string]$Namespace = 'root\cimv2', [string[]]$Properties)
    $records = New-Object Collections.ArrayList
    foreach ($item in @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)) {
        $null = $records.Add((ConvertTo-WudCimRecord -InputObject $item -Properties $Properties))
    }
    return @($records)
}

function Get-WudPendingRebootState {
    $componentBasedServicing = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
    $windowsUpdate = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $pendingRename = $false
    $pendingRenameValues = $null
    try {
        $pendingRenameValues = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
        $pendingRename = @($pendingRenameValues).Count -gt 0
    }
    catch { }
    $computerRename = $false
    try {
        $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName').ComputerName
        $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName').ComputerName
        $computerRename = $active -ne $pending
    }
    catch { }
    return [pscustomobject][ordered]@{
        ComponentBasedServicing = $componentBasedServicing
        WindowsUpdate           = $windowsUpdate
        PendingFileRename       = $pendingRename
        PendingFileRenameValues = $pendingRenameValues
        ComputerRename          = $computerRename
        IsPending               = ($componentBasedServicing -or $windowsUpdate -or $pendingRename -or $computerRename)
    }
}

function Invoke-WudIdentityCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Inventory')
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $computer = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $product = Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $currentVersion = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
    $locale = $null
    try { $locale = (Get-WinSystemLocale).Name } catch { }
    $uiLanguage = $null
    try { $uiLanguage = [Globalization.CultureInfo]::InstalledUICulture.Name } catch { }
    $imageState = $null
    try {
        $setupState = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' -ErrorAction Stop
        $imageState = Get-WudObjectPropertyValue $setupState 'ImageState'
    }
    catch { }
    $systemSetupState = $null
    try {
        $systemSetup = Get-ItemProperty 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
        $systemSetupState = [pscustomobject][ordered]@{
            SystemSetupInProgress = Get-WudObjectPropertyValue $systemSetup 'SystemSetupInProgress'
            OOBEInProgress        = Get-WudObjectPropertyValue $systemSetup 'OOBEInProgress'
            SetupType             = Get-WudObjectPropertyValue $systemSetup 'SetupType'
            SetupPhase            = Get-WudObjectPropertyValue $systemSetup 'SetupPhase'
            Upgrade               = Get-WudObjectPropertyValue $systemSetup 'Upgrade'
            CmdLine               = Get-WudObjectPropertyValue $systemSetup 'CmdLine'
        }
    }
    catch { }
    $identity = [pscustomobject][ordered]@{
        ComputerName        = $env:COMPUTERNAME
        Domain              = Get-WudObjectPropertyValue $computer 'Domain'
        Manufacturer        = Get-WudObjectPropertyValue $computer 'Manufacturer'
        Model               = Get-WudObjectPropertyValue $computer 'Model'
        SystemType          = Get-WudObjectPropertyValue $computer 'SystemType'
        TotalPhysicalMemory = Get-WudObjectPropertyValue $computer 'TotalPhysicalMemory'
        HypervisorPresent   = Get-WudObjectPropertyValue $computer 'HypervisorPresent'
        SerialNumber        = Get-WudObjectPropertyValue $product 'IdentifyingNumber'
        UUID                = Get-WudObjectPropertyValue $product 'UUID'
        OsCaption           = Get-WudObjectPropertyValue $os 'Caption'
        EditionId           = Get-WudObjectPropertyValue $currentVersion 'EditionID'
        ProductName         = Get-WudObjectPropertyValue $currentVersion 'ProductName'
        DisplayVersion      = Get-WudObjectPropertyValue $currentVersion 'DisplayVersion'
        CurrentBuild        = Get-WudObjectPropertyValue $currentVersion 'CurrentBuild'
        CurrentBuildNumber  = Get-WudObjectPropertyValue $os 'BuildNumber'
        UBR                 = Get-WudObjectPropertyValue $currentVersion 'UBR'
        BuildLabEx          = Get-WudObjectPropertyValue $currentVersion 'BuildLabEx'
        InstallationType    = Get-WudObjectPropertyValue $currentVersion 'InstallationType'
        ReleaseId           = Get-WudObjectPropertyValue $currentVersion 'ReleaseId'
        InstallDate         = Get-WudObjectPropertyValue $os 'InstallDate'
        LastBootUpTime      = Get-WudObjectPropertyValue $os 'LastBootUpTime'
        OsArchitecture      = Get-WudObjectPropertyValue $os 'OSArchitecture'
        ProcessArchitecture = $env:PROCESSOR_ARCHITECTURE
        FirmwareVersion     = Get-WudObjectPropertyValue $bios 'SMBIOSBIOSVersion'
        SystemLocale        = $locale
        SystemDefaultUiLanguage = $uiLanguage
        TimeZone            = [TimeZoneInfo]::Local.Id
        WindowsImageState   = $imageState
        SystemSetupState    = $systemSetupState
        CapturedUtc         = [DateTime]::UtcNow.ToString('o')
    }
    $sourceOs = New-Object Collections.ArrayList
    foreach ($key in @(Get-ChildItem 'HKLM:\SYSTEM\Setup' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Source OS*' })) {
        try {
            $value = Get-ItemProperty -LiteralPath $key.PSPath
            $null = $sourceOs.Add([pscustomobject][ordered]@{
                Key            = $key.PSChildName
                ProductName    = Get-WudObjectPropertyValue $value 'ProductName'
                ReleaseId      = Get-WudObjectPropertyValue $value 'ReleaseId'
                DisplayVersion = Get-WudObjectPropertyValue $value 'DisplayVersion'
                CurrentBuild   = Get-WudObjectPropertyValue $value 'CurrentBuild'
                UBR            = Get-WudObjectPropertyValue $value 'UBR'
                InstallDate    = Get-WudObjectPropertyValue $value 'InstallDate'
            })
        }
        catch { }
    }
    $identity | Add-Member -NotePropertyName SourceOsHistory -NotePropertyValue @($sourceOs | Sort-Object { try { [long]$_.InstallDate } catch { 0 } } -Descending)
    Write-WudJsonAtomic -Path (Join-Path $path 'identity.json') -InputObject $identity
    $Context.Inventory['Identity'] = $identity
}

function Invoke-WudHardwareCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Inventory')
    $logicalDisks = Get-WudCimRecords Win32_LogicalDisk -Properties @('DeviceID', 'DriveType', 'FileSystem', 'VolumeName', 'Size', 'FreeSpace', 'Status')
    $volumes = @(Invoke-WudOptionalProvider $Context 'hardware' 'Get-Volume' { Get-Volume -ErrorAction Stop | Select-Object DriveLetter, FileSystemLabel, FileSystemType, HealthStatus, OperationalStatus, Size, SizeRemaining, Path })
    $storagePartitions = @(Invoke-WudOptionalProvider $Context 'hardware' 'Get-Partition' { Get-Partition -ErrorAction Stop | Select-Object DiskNumber, PartitionNumber, DriveLetter, Type, GptType, MbrType, Size, Offset, IsSystem, IsBoot, IsActive, IsHidden, IsReadOnly, IsOffline, Guid, AccessPaths })
    $storageDisks = @(Invoke-WudOptionalProvider $Context 'hardware' 'Get-Disk' { Get-Disk -ErrorAction Stop | Select-Object Number, FriendlyName, SerialNumber, Manufacturer, Model, BusType, PartitionStyle, OperationalStatus, HealthStatus, IsSystem, IsBoot, IsOffline, IsReadOnly, Size, AllocatedSize, LargestFreeExtent, NumberOfPartitions, FirmwareVersion })
    $secureBoot = $null
    try { $secureBoot = Confirm-SecureBootUEFI -ErrorAction Stop }
    catch { $secureBoot = "Unavailable: $($_.Exception.Message)" }
    $bios = Get-WudCimRecords Win32_BIOS -Properties @('Manufacturer', 'SMBIOSBIOSVersion', 'ReleaseDate')
    $hardware = [pscustomobject][ordered]@{
        LogicalDisks      = $logicalDisks
        StoragePartitions = $storagePartitions
        StorageDisks      = $storageDisks
        Volumes           = $volumes
        Bios              = $bios
        SecureBoot        = $secureBoot
    }
    Write-WudJsonAtomic -Path (Join-Path $path 'hardware.json') -InputObject $hardware -Depth 20
    $Context.Inventory['Hardware'] = $hardware
    foreach ($command in @(
        @{ File = 'reagentc.exe'; Name = 'reagentc-info'; Args = @('/info') },
        @{ File = 'manage-bde.exe'; Name = 'manage-bde-status'; Args = @('-status') }
    )) {
        $null = Invoke-WudProcess -Context $Context -FilePath $command.File -ArgumentList $command.Args -Name $command.Name -TimeoutSeconds 300 -ExpectedArtifacts @(Get-WudObjectPropertyValue $command 'Expected' @())
    }
}

function Invoke-WudDriverCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Inventory')
    $criticalClasses = @('DISPLAY', 'HDC', 'MEDIA', 'NET', 'SCSIADAPTER', 'SYSTEM')
    $signedDrivers = @(Get-WudCimRecords Win32_PnPSignedDriver -Properties @('DeviceName', 'DeviceID', 'DeviceClass', 'Manufacturer', 'DriverProviderName', 'DriverVersion', 'DriverDate', 'InfName', 'IsSigned', 'Signer') | Where-Object { $_.DeviceClass -in $criticalClasses -or $_.IsSigned -eq $false })
    $devices = @(Get-WudCimRecords Win32_PnPEntity -Properties @('Name', 'DeviceID', 'PNPClass', 'Manufacturer', 'Service', 'Status', 'ConfigManagerErrorCode', 'Present') | Where-Object { [int]$_.ConfigManagerErrorCode -ne 0 })
    $pnp = @(Invoke-WudOptionalProvider $Context 'drivers' 'Get-PnpDevice problems' { Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.Status -ne 'OK' -or [int]$_.Problem -ne 0 } | Select-Object Status, Class, FriendlyName, InstanceId, Problem, Present })
    # Preserve the stable inventory property names while narrowing their content.
    $drivers = [pscustomobject][ordered]@{ SignedDrivers = $signedDrivers; Devices = $devices; PnpDevices = $pnp; Profile = 'UpdateCriticalAndProblemOnly' }
    Write-WudJsonAtomic -Path (Join-Path $path 'drivers.json') -InputObject $drivers -Depth 20
    $Context.Inventory['Drivers'] = $drivers
    $null = Invoke-WudProcess -Context $Context -FilePath 'pnputil.exe' -ArgumentList @('/enum-devices', '/problem') -Name 'pnputil-problem-devices' -TimeoutSeconds 600
}

function Test-WudEndpoint {
    param([string]$Uri)
    $started = [DateTime]::UtcNow
    try {
        $request = [Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'HEAD'
        $request.AllowAutoRedirect = $true
        $request.Timeout = 15000
        $request.ReadWriteTimeout = 15000
        $response = $request.GetResponse()
        $status = [int]$response.StatusCode
        $finalUri = $response.ResponseUri.AbsoluteUri
        $response.Close()
        return [pscustomobject][ordered]@{ Uri = $Uri; Reachable = $true; StatusCode = $status; FinalUri = $finalUri; Error = $null; DurationMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds }
    }
    catch [Net.WebException] {
        $response = $_.Exception.Response
        if ($response) {
            $status = [int]$response.StatusCode
            $finalUri = $response.ResponseUri.AbsoluteUri
            try { $response.Close() } catch { }
            return [pscustomobject][ordered]@{ Uri = $Uri; Reachable = $true; StatusCode = $status; FinalUri = $finalUri; Error = $_.Exception.Message; DurationMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds }
        }
        return [pscustomobject][ordered]@{ Uri = $Uri; Reachable = $false; StatusCode = $null; FinalUri = $null; Error = $_.Exception.Message; DurationMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds }
    }
    catch {
        return [pscustomobject][ordered]@{ Uri = $Uri; Reachable = $false; StatusCode = $null; FinalUri = $null; Error = $_.Exception.Message; DurationMs = [int]([DateTime]::UtcNow - $started).TotalMilliseconds }
    }
}

function Invoke-WudManagementCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Management')
    $registrySets = @(
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'; Name = 'policy-windows-update.json' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Name = 'ux-settings.json' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update'; Name = 'mdm-update-policy.json' },
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'policy-delivery-optimization.json' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\DeliveryOptimization'; Name = 'mdm-delivery-optimization.json' },
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags'; Name = 'appcompat-flags.json' },
        @{ Path = 'HKLM:\SYSTEM\Setup'; Name = 'system-setup.json' }
    )
    $registryExports = [ordered]@{}
    foreach ($set in $registrySets) {
        $registryExports[$set.Name] = @(Export-WudRegistryTree -RegistryPath $set.Path -OutputPath (Join-Path $path $set.Name))
    }
    $services = @()
    foreach ($name in @('wuauserv', 'bits', 'UsoSvc', 'DoSvc', 'WaaSMedicSvc')) {
        try {
            $service = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $name) -ErrorAction Stop
            $services += @(ConvertTo-WudCimRecord $service @('Name', 'DisplayName', 'State', 'StartMode', 'PathName', 'StartName', 'ExitCode', 'ProcessId'))
        }
        catch { }
    }
    $bitsJobs = @(Invoke-WudOptionalProvider $Context 'management' 'Get-BitsTransfer -AllUsers' { Get-BitsTransfer -AllUsers -ErrorAction Stop | Select-Object DisplayName, Description, JobState, JobId, OwnerAccount, TransferType, CreationTime, ModificationTime, BytesTotal, BytesTransferred, ErrorDescription })
    $connectivity = @()
    $configuredUpdateEndpoints = New-Object Collections.ArrayList
    try {
        $wuPolicy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -ErrorAction Stop
        foreach ($propertyName in @('WUServer', 'WUStatusServer')) {
            $uri = [string]$wuPolicy.$propertyName
            if (-not [string]::IsNullOrWhiteSpace($uri) -and -not $configuredUpdateEndpoints.Contains($uri)) { $null = $configuredUpdateEndpoints.Add($uri) }
        }
    }
    catch { }
    foreach ($endpoint in @($configuredUpdateEndpoints)) {
        $result = Test-WudEndpoint -Uri ([string]$endpoint)
        $result | Add-Member -NotePropertyName Kind -NotePropertyValue 'ConfiguredUpdateService'
        $connectivity += @($result)
    }
    if (-not $Context.NoInternet) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        foreach ($endpoint in @($Context.Settings.connectivityEndpoints)) {
            $result = Test-WudEndpoint -Uri ([string]$endpoint)
            $result | Add-Member -NotePropertyName Kind -NotePropertyValue 'MicrosoftPublic'
            $connectivity += @($result)
        }
    }
    $policySummary = [pscustomobject][ordered]@{
        Services     = $services
        BitsJobs     = $bitsJobs
        Connectivity = $connectivity
        ConfiguredUpdateEndpoints = @($configuredUpdateEndpoints)
        RegistryExports = [pscustomobject]$registryExports
    }
    Write-WudJsonAtomic -Path (Join-Path $path 'management-summary.json') -InputObject $policySummary
    $Context.Inventory['Management'] = $policySummary
    foreach ($command in @(
        @{ File = 'netsh.exe'; Name = 'winhttp-proxy'; Args = @('winhttp', 'show', 'proxy') },
        @{ File = 'w32tm.exe'; Name = 'time-status'; Args = @('/query', '/status', '/verbose') }
    )) {
        $null = Invoke-WudProcess -Context $Context -FilePath $command.File -ArgumentList $command.Args -Name $command.Name -TimeoutSeconds 600 -ExpectedArtifacts @(Get-WudObjectPropertyValue $command 'Expected' @())
    }
}

function Get-WudUpdateHistory {
    param($Context)
    $records = New-Object Collections.ArrayList
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            foreach ($entry in @($searcher.QueryHistory(0, [Math]::Min($count, 2000)))) {
                $identity = Get-WudObjectPropertyValue $entry 'UpdateIdentity'
                $hresult = Get-WudObjectPropertyValue $entry 'HResult'
                $hresultHex = $null
                if ($null -ne $hresult) { $hresultHex = '0x{0:X8}' -f ([long]$hresult -band 0xFFFFFFFFL) }
                $null = $records.Add([pscustomobject][ordered]@{
                    Date                = Get-WudObjectPropertyValue $entry 'Date'
                    DateUtc             = [DateTime]::SpecifyKind([DateTime](Get-WudObjectPropertyValue $entry 'Date'), [DateTimeKind]::Utc).ToString('o')
                    Title               = Get-WudObjectPropertyValue $entry 'Title'
                    Description         = Get-WudObjectPropertyValue $entry 'Description'
                    Operation           = [string](Get-WudObjectPropertyValue $entry 'Operation')
                    ResultCode          = [string](Get-WudObjectPropertyValue $entry 'ResultCode')
                    HResult             = $hresult
                    HResultHex          = $hresultHex
                    SupportUrl          = Get-WudObjectPropertyValue $entry 'SupportUrl'
                    UnmappedResultCode  = Get-WudObjectPropertyValue $entry 'UnmappedResultCode'
                    ClientApplicationID = Get-WudObjectPropertyValue $entry 'ClientApplicationID'
                    ServerSelection     = [string](Get-WudObjectPropertyValue $entry 'ServerSelection')
                    ServiceID           = Get-WudObjectPropertyValue $entry 'ServiceID'
                    UpdateID            = Get-WudObjectPropertyValue $identity 'UpdateID'
                    RevisionNumber      = Get-WudObjectPropertyValue $identity 'RevisionNumber'
                })
            }
        }
    }
    catch {
        if ($Context) { $null = Add-WudCollectionGap -Context $Context -Collector 'servicing' -Source 'Microsoft.Update.Session history' -Status 'ProviderFailed' -Detail (Get-WudErrorDetail -ErrorRecord $_) }
    }
    return @($records)
}

function Invoke-WudServicingCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Servicing')
    $pending = Get-WudPendingRebootState
    $history = Get-WudUpdateHistory -Context $Context
    $servicing = [pscustomobject][ordered]@{ PendingReboot = $pending; UpdateHistory = $history }
    Write-WudJsonAtomic -Path (Join-Path $path 'servicing.json') -InputObject $servicing -Depth 20
    $Context.Inventory['Servicing'] = $servicing
}

function Invoke-WudActiveHealthCollector {
    param($Context)
    $dismTimeout = [int]$Context.Settings.timeoutsSeconds.dismScanHealth
    $sfcTimeout = [int]$Context.Settings.timeoutsSeconds.sfcVerifyOnly
    $diagnosticPath = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'CurrentDiagnostics')
    $dismLog = Join-Path $diagnosticPath 'dism-scanhealth.log'
    $null = Invoke-WudProcess -Context $Context -FilePath 'dism.exe' -ArgumentList @('/Online', '/Cleanup-Image', '/ScanHealth', '/English', ("/LogPath:{0}" -f $dismLog)) -Name 'dism-scanhealth' -TimeoutSeconds $dismTimeout -SuccessExitCodes @(0, 3010) -ExpectedArtifacts @($dismLog)
    $null = Invoke-WudProcess -Context $Context -FilePath 'sfc.exe' -ArgumentList @('/verifyonly') -Name 'sfc-verifyonly' -TimeoutSeconds $sfcTimeout -SuccessExitCodes @(0, 1)
}

function Invoke-WudAppraiserCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Compatibility')
    $refreshPath = New-WudDirectory -Path (Join-Path $path 'AppraiserRefresh')
    $taskPath = '\Microsoft\Windows\Application Experience\'
    $taskName = 'Microsoft Compatibility Appraiser'
    $result = [ordered]@{ TaskPath = $taskPath; TaskName = $taskName; StartedUtc = [DateTime]::UtcNow.ToString('o'); Status = 'NotFound'; TimedOut = $false; Before = $null; After = $null; Error = $null }
    try {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
        try { $result.Before = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns }
        catch { }
        Start-ScheduledTask -InputObject $task -ErrorAction Stop
        $result.Status = 'Running'
        $deadline = [DateTime]::UtcNow.AddSeconds([int]$Context.Settings.timeoutsSeconds.appraiser)
        do {
            Start-Sleep -Seconds 5
            $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop
            if ([DateTime]::UtcNow -ge $deadline -and $task.State -eq 'Running') {
                $result.TimedOut = $true
                try { Stop-ScheduledTask -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop } catch { }
                break
            }
        } while ($task.State -eq 'Running')
        try { $result.After = Get-ScheduledTaskInfo -TaskPath $taskPath -TaskName $taskName -ErrorAction Stop | Select-Object LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns }
        catch { }
        $result.Status = if ($result.TimedOut) { 'TimedOut' } else { 'Completed' }
    }
    catch { $result.Error = $_.Exception.Message }
    $result['EndedUtc'] = [DateTime]::UtcNow.ToString('o')
    if ($result.TimedOut) { $null = Add-WudCollectionGap -Context $Context -Collector 'appraiser' -Source "$taskPath$taskName" -Status 'TimedOut' -Detail 'The Compatibility Appraiser task exceeded its configured timeout.' }
    elseif ($result.Error) { $null = Add-WudCollectionGap -Context $Context -Collector 'appraiser' -Source "$taskPath$taskName" -Status 'Unavailable' -Detail $result.Error }
    Write-WudJsonAtomic -Path (Join-Path $path 'appraiser-task.json') -InputObject ([pscustomobject]$result)
    $null = Export-WudRegistryTree -RegistryPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags' -OutputPath (Join-Path $refreshPath 'appcompat-flags-after-refresh.json')
}

function Invoke-WudMediaCompatibilityCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Compatibility\MediaScan')
    $record = [ordered]@{ Requested = -not [string]::IsNullOrWhiteSpace($Context.MediaPath); MediaPath = $Context.MediaPath; EulaAccepted = $Context.AcceptWindowsEula; Validated = $false; Executed = $false; Result = $null; Reason = $null }
    if ([string]::IsNullOrWhiteSpace($Context.MediaPath)) {
        $record.Reason = 'No media path was supplied.'
        Write-WudJsonAtomic -Path (Join-Path $path 'media-scan.json') -InputObject ([pscustomobject]$record)
        return
    }
    if (-not $Context.AcceptWindowsEula) {
        $record.Reason = 'The compatibility scan was not run because -AcceptWindowsEula was not supplied.'
        Write-WudJsonAtomic -Path (Join-Path $path 'media-scan.json') -InputObject ([pscustomobject]$record)
        return
    }
    $setup = Join-Path $Context.MediaPath 'setup.exe'
    if (-not (Test-Path -LiteralPath $setup)) {
        $record.Reason = 'setup.exe was not found at the media root.'
        Write-WudJsonAtomic -Path (Join-Path $path 'media-scan.json') -InputObject ([pscustomobject]$record)
        return
    }
    $images = @(@('sources\install.wim', 'sources\install.esd', 'sources\install.swm') | ForEach-Object { Join-Path $Context.MediaPath $_ } | Where-Object { Test-Path -LiteralPath $_ })
    if (@($images).Count -eq 0) {
        $record.Reason = 'No supported install.wim, install.esd, or first install.swm image was found in the media sources folder.'
        Write-WudJsonAtomic -Path (Join-Path $path 'media-scan.json') -InputObject ([pscustomobject]$record)
        return
    }
    $imageFile = [string]$images[0]
    $wimResult = $null
    $wimResult = Invoke-WudProcess -Context $Context -FilePath 'dism.exe' -ArgumentList @('/Get-WimInfo', ("/WimFile:{0}" -f $imageFile), '/English') -Name 'media-wim-info' -TimeoutSeconds 1200
    $fileVersion = (Get-Item -LiteralPath $setup).VersionInfo.FileVersion
    $record['SetupFileVersion'] = $fileVersion
    $record['ImageFile'] = $imageFile
    $wimText = ''
    if ($wimResult -and (Test-Path -LiteralPath $wimResult.StandardOut)) { $wimText = Get-Content -LiteralPath $wimResult.StandardOut -Raw -ErrorAction SilentlyContinue }
    $expectedBuild = [string]$Context.Target.buildFamily
    $imageDetails = New-Object Collections.ArrayList
    foreach ($match in [Regex]::Matches([string]$wimText, '(?im)^\s*Index\s*:\s*(\d+)\s*$')) {
        if (@($imageDetails).Count -ge 50) { break }
        $index = [int]$match.Groups[1].Value
        $detailResult = Invoke-WudProcess -Context $Context -FilePath 'dism.exe' -ArgumentList @('/Get-WimInfo', ("/WimFile:{0}" -f $imageFile), ("/Index:{0}" -f $index), '/English') -Name ("media-wim-index-{0}" -f $index) -TimeoutSeconds 1200
        $detailText = if ($detailResult -and (Test-Path -LiteralPath $detailResult.StandardOut)) { Get-Content -LiteralPath $detailResult.StandardOut -Raw -ErrorAction SilentlyContinue } else { '' }
        $fields = [ordered]@{ Index = $index; Name = $null; Description = $null; Architecture = $null; Version = $null; Edition = $null; DefaultLanguage = $null }
        foreach ($field in @(
            @{ Name = 'Name'; Pattern = '(?im)^\s*Name\s*:\s*(.+?)\s*$' },
            @{ Name = 'Description'; Pattern = '(?im)^\s*Description\s*:\s*(.+?)\s*$' },
            @{ Name = 'Architecture'; Pattern = '(?im)^\s*Architecture\s*:\s*(.+?)\s*$' },
            @{ Name = 'Version'; Pattern = '(?im)^\s*Version\s*:\s*(.+?)\s*$' },
            @{ Name = 'Edition'; Pattern = '(?im)^\s*Edition\s*:\s*(.+?)\s*$' },
            @{ Name = 'DefaultLanguage'; Pattern = '(?im)^\s*Default Language\s*:\s*(.+?)\s*$' }
        )) {
            $fieldMatch = [Regex]::Match([string]$detailText, $field.Pattern)
            if ($fieldMatch.Success) { $fields[$field.Name] = $fieldMatch.Groups[1].Value.Trim() }
        }
        $null = $imageDetails.Add([pscustomobject]$fields)
    }
    $identity = $Context.Inventory['Identity']
    $currentArchitecture = if ([string]$identity.ProcessArchitecture -match '(?i)ARM64') { 'arm64' } elseif ([string]$identity.ProcessArchitecture -match '(?i)AMD64') { 'x64' } else { ([string]$identity.ProcessArchitecture).ToLowerInvariant() }
    $currentEdition = [string]$identity.EditionId
    $currentLanguage = [string]$identity.SystemDefaultUiLanguage
    if ([string]::IsNullOrWhiteSpace($currentLanguage)) { $currentLanguage = [string]$identity.SystemLocale }
    $matchingImages = @($imageDetails | Where-Object {
        ([string]$_.Version -match ("^10\.0\.{0}(?:\.|$)" -f [Regex]::Escape($expectedBuild))) -and
        ([string]$_.Architecture).ToLowerInvariant() -eq $currentArchitecture -and
        ([string]$_.Edition -ieq $currentEdition) -and
        ([string]$_.DefaultLanguage -ieq $currentLanguage)
    })
    $record['RunningArchitecture'] = $currentArchitecture
    $record['RunningEdition'] = $currentEdition
    $record['RunningSystemDefaultUiLanguage'] = $currentLanguage
    $record['Images'] = @($imageDetails)
    $record['MatchingImages'] = @($matchingImages | ForEach-Object Index)
    $record['BuildMatch'] = (($fileVersion -match ("10\.0\.{0}" -f [Regex]::Escape($expectedBuild))) -or @($imageDetails | Where-Object { [string]$_.Version -match ("^10\.0\.{0}(?:\.|$)" -f [Regex]::Escape($expectedBuild)) }).Count -gt 0)
    $record['ArchitectureMatch'] = @($imageDetails | Where-Object { ([string]$_.Architecture).ToLowerInvariant() -eq $currentArchitecture }).Count -gt 0
    $record['EditionMatch'] = @($imageDetails | Where-Object { [string]$_.Edition -ieq $currentEdition }).Count -gt 0
    $record['LanguageMatch'] = @($imageDetails | Where-Object { [string]$_.DefaultLanguage -ieq $currentLanguage }).Count -gt 0
    $record.Validated = @($matchingImages).Count -gt 0
    if (-not $record.Validated) {
        $record.Reason = "The media does not expose a single image matching build family $expectedBuild, architecture $currentArchitecture, edition $currentEdition, and system default UI language $currentLanguage."
        Write-WudJsonAtomic -Path (Join-Path $path 'media-scan.json') -InputObject ([pscustomobject]$record) -Depth 20
        return
    }
    $copyLogs = New-WudDirectory -Path (Join-Path $path 'CopyLogs')
    # Keep the active diagnostic scan non-installing: Dynamic Update can search,
    # download, and apply Setup updates even when the final operation is scan-only.
    $dynamicUpdate = 'Disable'
    $record['DynamicUpdate'] = $dynamicUpdate
    $args = @('/auto', 'upgrade', '/quiet', '/compat', 'scanonly', '/compat', 'ignorewarning', '/noreboot', '/eula', 'accept', '/copylogs', $copyLogs, '/dynamicupdate', $dynamicUpdate)
    $scan = Invoke-WudProcess -Context $Context -FilePath $setup -ArgumentList $args -Name 'setup-compat-scan' -TimeoutSeconds ([int]$Context.Settings.timeoutsSeconds.compatibilityScan) -SuccessExitCodes @(0, -1047526896)
    $record.Executed = $true
    $record.Result = $scan
    if ($scan.ExitCodeHex -eq '0xC1900210') { $record.Reason = 'Compatibility scan completed without actionable concerns.' }
    elseif ($scan.ExitCodeHex -eq '0xC1900208') { $record.Reason = 'Compatibility scan found an actionable application or driver concern.' }
    else { $record.Reason = "Compatibility scan returned $($scan.ExitCodeHex)." }
    Write-WudJsonAtomic -Path (Join-Path $path 'media-scan.json') -InputObject ([pscustomobject]$record) -Depth 20
}

function Copy-WudEvidenceItem {
    param($Context, [string]$Source, [string]$DestinationName)
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    $root = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Raw')
    $destination = Join-Path $root $DestinationName
    try {
        $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        if ($item.PSIsContainer) {
            $null = New-WudDirectory -Path $destination
            $result = Invoke-WudProcess -Context $Context -FilePath 'robocopy.exe' -ArgumentList @($Source, $destination, '/E', '/COPY:DAT', '/DCOPY:T', '/R:1', '/W:1', '/XJ', '/SL', '/NP') -Name ("copy-{0}" -f $DestinationName) -TimeoutSeconds 3600 -SuccessExitCodes @(0, 1, 2, 3, 4, 5, 6, 7) -ExpectedArtifacts @($destination)
            $usable = $result.Succeeded -or $result.ExecutionStatus -eq 'ArtifactCapturedDespiteProcessUncertainty'
            if (-not $usable) {
                $impact = if ($DestinationName -match '(?i)Panther|Rollback|SetupCopyLogs') { 'Material' } else { 'Optional' }
                $null = Add-WudCollectionGap -Context $Context -Collector 'raw-evidence' -Source $Source -Status $result.ExecutionStatus -Detail $result.Detail -Impact $impact
            }
            elseif (-not $result.Succeeded) {
                $null = Add-WudCollectionGap -Context $Context -Collector 'raw-evidence' -Source $Source -Status 'ArtifactCapturedDespiteProcessUncertainty' -Detail $result.Detail
            }
            return $usable
        }
        $null = New-WudDirectory -Path (Split-Path -Parent $destination)
        Copy-Item -LiteralPath $Source -Destination $destination -Force -ErrorAction Stop
        return $true
    }
    catch {
        Write-WudLog -Context $Context -Level WARN -Message ("Could not copy evidence '{0}': {1}" -f $Source, $_.Exception.Message)
        $null = Add-WudCollectionGap -Context $Context -Collector 'raw-evidence' -Source $Source -Status 'CopyFailed' -Detail $_.Exception.Message
        return $false
    }
}

function Invoke-WudNativeTraceCollector {
    param($Context, $Sources = @(Get-WudNativeTraceSources -RunPath $Context.RunPath))
    $roots = New-Object Collections.ArrayList
    $files = New-Object Collections.ArrayList
    foreach ($source in $Sources) {
        try { $null = Get-Item -LiteralPath $source.Path -Force -ErrorAction Stop }
        catch {
            $status = if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { 'SourceAbsent' } else { 'SourceUnavailable' }
            $null = $roots.Add([pscustomobject]@{ Source = $source.Path; Status = $status; ObservedFiles = 0; Error = Get-WudErrorDetail $_ })
            $null = Add-WudCollectionGap -Context $Context -Collector 'native-etl' -Source $source.Path -Status $status -Detail (Get-WudErrorDetail $_)
            continue
        }
        $gapsBefore = @($Context.CollectionGaps).Count
        $nativeFiles = @(Get-WudFileTreeSafe -RootPath $source.Path -Context $Context -Collector 'native-etl' | Where-Object { $_.Name -match '(?i)\.etl(?:\.(?:old|bak|\d+))?$' })
        $rootStatus = if (@($Context.CollectionGaps).Count -gt $gapsBefore) { 'EnumerationIncomplete' } elseif ($nativeFiles.Count) { 'Enumerated' } else { 'NoRetainedETL' }
        $null = $roots.Add([pscustomobject]@{ Source = $source.Path; Status = $rootStatus; ObservedFiles = $nativeFiles.Count; Error = $null })
        foreach ($file in $nativeFiles) {
            $relative = Get-WudRelativePath -BasePath $source.Path -Path $file.FullName
            $destination = Join-Path (Join-Path $Context.SnapshotPath ('Raw/' + $source.Name)) $relative
            $record = Copy-WudNativeTraceFile -Source $file.FullName -Destination $destination
            $record | Add-Member -NotePropertyName EvidenceRef -NotePropertyValue (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $destination).Replace('\', '/')
            $null = $files.Add($record)
            if ($record.Status -in @('CopyFailed', 'PartialCapture', 'ChangedDuringCapture') -or -not $record.Sha256) {
                $null = Add-WudCollectionGap -Context $Context -Collector 'native-etl' -Source $file.FullName -Status $record.Status -Detail $(if ($record.Error) { $record.Error } else { 'The source changed while capturing, the captured stream is partial, or its hash could not be calculated. Retained bytes are preserved.' })
            }
        }
    }
    Write-WudJsonAtomic -Path (Join-Path $Context.SnapshotPath 'ETLCoverage.json') -InputObject ([pscustomobject][ordered]@{
        CapturedUtc = [DateTime]::UtcNow.ToString('o'); Roots = @($roots); Files = @($files)
        Interpretation = 'All retained ETL/ETL.old/ETL.bak/ETL.numeric files in the listed update and setup roots are attempted recursively without timestamp or per-file-size filters. Raw traces may span multiple updates or imaging. CapturedUnflushed does not guarantee ETW buffers were committed or the trace is parseable. Deleted logs cannot be recovered. Services, ACLs and trace sessions are not changed.'
    }) -Depth 20
}

function Invoke-WudRawEvidenceCollector {
    param($Context)
    $drive = $env:SystemDrive
    $windows = $env:SystemRoot
    $sources = @(
        @{ Name = 'WindowsBT-Panther'; Path = (Join-Path $drive '$WINDOWS.~BT\Sources\Panther') },
        @{ Name = 'WindowsBT-Rollback'; Path = (Join-Path $drive '$WINDOWS.~BT\Sources\Rollback') },
        @{ Name = 'Windows-MoSetup'; Path = (Join-Path $windows 'Logs\MoSetup') },
        @{ Name = 'Windows-SetupDiag'; Path = (Join-Path $windows 'Logs\SetupDiag') },
        @{ Name = 'WindowsUpdate-ETL'; Path = (Join-Path $windows 'Logs\WindowsUpdate') },
        @{ Name = 'USOShared-Logs'; Path = (Join-Path $env:ProgramData 'USOShared\Logs') },
        @{ Name = 'DeliveryOptimization-Logs'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\DeliveryOptimization\Logs') },
        @{ Name = 'WindowsOld-Panther'; Path = (Join-Path $drive 'Windows.old\Windows\Panther') },
        @{ Name = 'WindowsOld-System.evtx'; Path = (Join-Path $drive 'Windows.old\Windows\System32\winevt\Logs\System.evtx') },
        @{ Name = 'WindowsOld-WindowsUpdateClient.evtx'; Path = (Join-Path $drive 'Windows.old\Windows\System32\winevt\Logs\Microsoft-Windows-WindowsUpdateClient%4Operational.evtx') },
        @{ Name = 'WUPA-SetupCopyLogs'; Path = (Join-Path $Context.RunPath 'SetupCopyLogs') },
        @{ Name = 'WUPA-Persistence-State'; Path = (Join-Path $Context.RunPath 'State\Persistence') },
        @{ Name = 'WUPA-Outcome-Markers'; Path = (Join-Path $Context.RunPath 'State\Markers') }
    )
    # Post-upgrade Panther can contain the retained setup activity after ~BT
    # is removed. Capture only known diagnostic files; strict scope analysis
    # still rejects imaging/history. Do not sweep unattend answer files.
    foreach ($relative in @('setupact.log', 'setuperr.log', 'miglog.xml', 'diagerr.xml', 'diagwrn.xml', 'UnattendGC/setupact.log', 'UnattendGC/setuperr.log')) {
        $sources += @{ Name = 'Windows-Panther-Context/' + $relative; Path = Join-Path $windows ('Panther/' + $relative) }
    }
    $operatorFinalizationPath = Join-Path $Context.RunPath 'State\operator-finalize.json'
    if ($Context.Mode -eq 'Finalize' -or (Test-Path -LiteralPath $operatorFinalizationPath)) {
        $sources += @{ Name = 'WUPA-Operator-Finalization'; Path = $operatorFinalizationPath }
    }
    $copyResults = New-Object Collections.ArrayList
    foreach ($source in $sources) {
        $present = Test-Path -LiteralPath $source.Path
        $copied = Copy-WudEvidenceItem -Context $Context -Source $source.Path -DestinationName $source.Name
        if (-not $present) { $null = Add-WudCollectionGap -Context $Context -Collector 'raw-evidence' -Source $source.Path -Status 'Missing' -Detail 'The configured evidence source was not present at collection time.' }
        $null = $copyResults.Add([pscustomobject][ordered]@{ Source = $source.Path; Destination = $source.Name; Present = $present; Copied = $copied })
    }
    # Native ETLs are preserved before readable conversions. This also covers
    # NetworkService DO, retained NewOS traces and Panther performance ETLs.
    Invoke-WudNativeTraceCollector -Context $Context
    if ($Context.Mode -in @('Resume', 'Finalize', 'Forensic')) {
        $rawRoot = Join-Path $Context.SnapshotPath 'Raw'
        $coreSetupFiles = @(Get-ChildItem -LiteralPath $rawRoot -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.FullName -match '(?i)WindowsBT-Panther|WindowsBT-Rollback|WindowsOld-Panther|Windows-Panther-Context|SetupCopyLogs' -and
            $_.Name -match '(?i)^setup(?:act|err)|CompatData|CompatReport|BlueBox|setupmem|miglog|setuperr'
        })
        if (@($coreSetupFiles).Count -eq 0) {
            $null = Add-WudCollectionGap -Context $Context -Collector 'raw-evidence' -Source 'Windows Setup Panther/Rollback evidence set' -Status 'CoreSetupEvidenceMissing' -Detail 'No core Setup activity/error, compatibility, migration, or setup crash file was available in the copied post-attempt sources.' -Impact 'Material'
        }
    }
    Write-WudJsonAtomic -Path (Join-Path $Context.SnapshotPath 'raw-copy-results.json') -InputObject ([pscustomobject]@{ Sources = @($copyResults); MemoryDump = [pscustomobject]@{ CollectionStatus = 'ExcludedByDesign'; Reason = 'Full memory dumps are outside the focused Windows Update performance evidence profile.' } })
}

function Invoke-WudWindowsUpdateLogDecode {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'WindowsUpdate')
    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $conversions = New-Object Collections.ArrayList
    foreach ($plan in @(Get-WudWindowsUpdateConversionPlan $Context)) {
        $record = [pscustomobject]@{ Provider = 'Get-WindowsUpdateLog'; Source = 'CapturedSnapshot'; Origin = $plan.Name; InputRoot = $plan.InputRoot; Files = @($plan.Files | ForEach-Object { Get-WudRelativePath $Context.EvidencePath $_.FullName }); InputMappings = @(); Output = Get-WudRelativePath $Context.EvidencePath $plan.LogPath; Status = 'NoCapturedInputs'; ProcessStatus = $null; ExitCode = $null; OutputValidation = $null; StandardError = $null; StandardOut = $null; Error = $null }
        $null = $conversions.Add($record)
        if (-not $plan.Files.Count) { continue }
        # Owned scratch copies give rotated ETLs unique .etl names without
        # changing native evidence or mixing source-OS and current-OS streams.
        $scratch = New-WudDirectory (Join-Path $Context.RunPath ('DecodeScratch/' + [Guid]::NewGuid().ToString('N')))
        try {
            $inputs = New-Object Collections.ArrayList; $mappings = New-Object Collections.ArrayList; $index = 0
            foreach ($file in $plan.Files) {
                # Modern Get-WindowsUpdateLog checks WindowsUpdate filename
                # filters even for explicitly supplied files. Generic 00001.etl
                # is rejected with the misleading "ETL File not found" message.
                $index++; $inputPath = Join-Path $scratch ('WindowsUpdate.{0:D5}.etl' -f $index)
                Copy-Item -LiteralPath $file.FullName -Destination $inputPath -ErrorAction Stop
                $copy = Get-Item -LiteralPath $inputPath -ErrorAction Stop
                if ($copy.Length -ne $file.Length) { throw "Staged ETL length mismatch: $($file.FullName)" }
                $null = $inputs.Add($inputPath)
                $null = $mappings.Add([pscustomobject]@{ SourceRef = Get-WudRelativePath $Context.EvidencePath $file.FullName; StagedName = $copy.Name; Length = $copy.Length })
            }
            $record.InputMappings = @($mappings)
            $inputsPath = Join-Path $scratch 'inputs.json'
            Write-WudJsonAtomic $inputsPath @($inputs)
            $escapedInputs = $inputsPath.Replace("'", "''"); $escaped = $plan.LogPath.Replace("'", "''")
            $script = "`$ErrorActionPreference = 'Stop'; try { [string[]]`$etlFiles = Get-Content -LiteralPath '$escapedInputs' -Raw -Encoding UTF8 | ConvertFrom-Json; foreach (`$etlFile in `$etlFiles) { if (-not (Test-Path -LiteralPath `$etlFile -PathType Leaf)) { throw ('Staged ETL missing before decoding: ' + `$etlFile) } }; Get-WindowsUpdateLog -ETLPath `$etlFiles -LogPath '$escaped' -ErrorAction Stop | Out-Null } catch { [Console]::Error.WriteLine((`$_ | Format-List * -Force | Out-String)); exit 1 }"
            $result = Invoke-WudProcess -Context $Context -FilePath $powerShell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $script) -Name ('convert-windows-update-log-' + $plan.Name) -TimeoutSeconds ([int]$Context.Settings.timeoutsSeconds.windowsUpdateLog) -ExpectedArtifacts @($plan.LogPath)
            $record.ProcessStatus = $result.ExecutionStatus; $record.ExitCode = Get-WudObjectPropertyValue $result 'ExitCode'
            $record.Status = $result.ExecutionStatus
            foreach ($streamName in @('StandardError', 'StandardOut')) {
                $streamPath = Get-WudObjectPropertyValue $result $streamName
                if ($streamPath) { $record.$streamName = Get-WudRelativePath $Context.EvidencePath $streamPath }
            }
            $record.OutputValidation = Test-WudDecodedWindowsUpdateLog -Path $plan.LogPath
            if (-not $result.Succeeded) {
                $record.Error = $result.Detail
                $stderrPath = Get-WudObjectPropertyValue $result 'StandardError'
                if ($stderrPath -and (Test-Path -LiteralPath $stderrPath)) {
                    $errorReader = New-Object IO.StreamReader($stderrPath, [Text.Encoding]::UTF8, $true)
                    try { $buffer = New-Object char[] 8192; $read = $errorReader.Read($buffer, 0, $buffer.Length); if ($read) { $record.Error += ' ' + (New-Object string($buffer, 0, $read)).Trim() } } finally { $errorReader.Dispose() }
                }
            } elseif (-not $record.OutputValidation.Valid) {
                $record.Status = 'InvalidDecodedOutput'; $record.Error = $record.OutputValidation.Detail
            }
            if ($record.Error) { $null = Add-WudCollectionGap -Context $Context -Collector 'windows-update-decode' -Source $plan.InputRoot -Status $record.Status -Detail $record.Error -Impact 'Material' }
        } catch {
            $record.Status = 'Failed'; $record.Error = $_.Exception.Message
            $null = Add-WudCollectionGap -Context $Context -Collector 'windows-update-decode' -Source $plan.InputRoot -Status 'Failed' -Detail $record.Error -Impact 'Material'
        } finally {
            # This exact UUID folder was created by this pass, not a user path.
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-WudJsonAtomic (Join-Path $path 'conversion-inputs.json') ([pscustomobject]@{ Sets = @($conversions); Note = 'Current and Windows.old are decoded separately from staged evidence, including rotated ETLs. Originals are untouched; no flush or service changes are requested.' }) -Depth 15
}

function Invoke-WudWindowsUpdateLogCollector {
    param($Context)
    Invoke-WudWindowsUpdateLogDecode $Context
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'WindowsUpdate')
    $do = $null
    if (Get-Command -Name 'Get-WudProgressSample' -ErrorAction SilentlyContinue) {
        $probe = Get-WudProgressSample -RunPath $Context.RunPath -TargetVersion $Context.TargetVersion -TargetBuild ([int]$Context.Target.buildFamily) -IncludeStaticDeliveryData
        $do = $probe.DeliveryOptimization
    }
    else {
        $do = [pscustomobject][ordered]@{
            Status = [pscustomobject]@{ Provider = 'Get-DeliveryOptimizationStatus'; Status = 'Unavailable'; Records = @(); Error = 'RecorderModuleNotLoaded' }
            PeerInfo = [pscustomobject]@{ Provider = 'Get-DeliveryOptimizationStatus -PeerInfo'; Status = 'Unavailable'; Records = @(); Error = 'RecorderModuleNotLoaded' }
            Performance = [pscustomobject]@{ Provider = 'Get-DeliveryOptimizationPerfSnap'; Status = 'Unavailable'; Records = @(); Error = 'RecorderModuleNotLoaded' }
            PerformanceThisMonth = [pscustomobject]@{ Provider = 'Get-DeliveryOptimizationPerfSnapThisMonth'; Status = 'Unavailable'; Records = @(); Error = 'RecorderModuleNotLoaded' }
            Configuration = [pscustomobject]@{ Provider = 'Get-DOConfig'; Status = 'Unavailable'; Records = @(); Error = 'RecorderModuleNotLoaded' }
        }
    }
    $logProvider = [ordered]@{ Provider = 'Get-DeliveryOptimizationLog'; Status = 'Unavailable'; Records = @(); Error = 'CommandNotFound'; CapturedUtc = [DateTime]::UtcNow.ToString('o') }
    if (Get-Command -Name 'Get-DeliveryOptimizationLog' -ErrorAction SilentlyContinue) {
        try {
            $logProvider.Status = 'Available'
            $logProvider.Error = $null
            $doFiles = @(@('DeliveryOptimization-Logs', 'DeliveryOptimization-NetworkService-Logs') | ForEach-Object {
                Get-ChildItem -LiteralPath (Join-Path $Context.SnapshotPath ('Raw/' + $_)) -File -Recurse -Filter '*.etl' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
            })
            if ($doFiles.Count -eq 0) { throw 'No captured Delivery Optimization ETL inputs are available.' }
            $logProvider['InputFiles'] = @($doFiles | ForEach-Object { Get-WudRelativePath -BasePath $Context.EvidencePath -Path $_ })
            $logProvider.Records = @(Get-DeliveryOptimizationLog -Path $doFiles -ErrorAction Stop | Select-Object -First 5000)
        }
        catch {
            $logProvider.Status = 'Failed'
            $logProvider.Error = Get-WudErrorDetail -ErrorRecord $_
        }
    }
    $do | Add-Member -NotePropertyName ReadableLog -NotePropertyValue ([pscustomobject]$logProvider) -Force
    Write-WudJsonAtomic -Path (Join-Path $path 'DeliveryOptimization.json') -InputObject $do -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $path 'DeliveryOptimizationStatus.json') -InputObject $do.Status -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $path 'DeliveryOptimizationPeerInfo.json') -InputObject $do.PeerInfo -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $path 'DeliveryOptimizationPerformance.json') -InputObject ([pscustomobject]@{ Current = $do.Performance; ThisMonth = $do.PerformanceThisMonth }) -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $path 'DeliveryOptimizationConfig.json') -InputObject $do.Configuration -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $path 'DeliveryOptimizationLog.json') -InputObject ([pscustomobject]$logProvider) -Depth 20
    foreach ($provider in @($do.Status, $do.PeerInfo, $do.Performance, $do.PerformanceThisMonth, $do.Configuration, ([pscustomobject]$logProvider))) {
        if ([string]$provider.Status -eq 'Failed') {
            $null = Add-WudCollectionGap -Context $Context -Collector 'windows-update' -Source ([string]$provider.Provider) -Status 'ProviderFailed' -Detail ([string]$provider.Error)
        }
    }
}

function Get-WudEventQueryErrorDisposition {
    param($ErrorRecord)
    # Use the provider's locale-neutral error identifier, not message text.
    if ($ErrorRecord.FullyQualifiedErrorId -match '^NoMatchingEventsFound(?:,|$)') { return 'Empty' }
    return 'Failed'
}

function Invoke-WudEventCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'Events')
    $channels = @(
        'System', 'Setup',
        'Microsoft-Windows-Setup/Operational',
        'Microsoft-Windows-MoSetup/Operational',
        'Microsoft-Windows-WindowsUpdateClient/Operational',
        'Microsoft-Windows-UpdateOrchestrator/Operational',
        'Microsoft-Windows-DeliveryOptimization/Operational'
    )
    $exports = New-Object Collections.ArrayList
    foreach ($channel in $channels) {
        $safe = $channel -replace '[^A-Za-z0-9._-]', '_'
        $target = Join-Path $path ($safe + '.evtx')
        $metadata = Invoke-WudProcess -Context $Context -FilePath 'wevtutil.exe' -ArgumentList @('gl', $channel) -Name ("event-channel-{0}" -f $safe) -TimeoutSeconds 120
        if ($metadata.ExitCode -eq 0) {
            $export = Invoke-WudProcess -Context $Context -FilePath 'wevtutil.exe' -ArgumentList @('epl', $channel, $target, '/ow:true') -Name ("event-export-{0}" -f $safe) -TimeoutSeconds 900 -ExpectedArtifacts @($target)
            $exported = $export.Succeeded -or $export.ExecutionStatus -eq 'ArtifactCapturedDespiteProcessUncertainty'
            $null = $exports.Add([pscustomobject][ordered]@{ Channel = $channel; Exported = $exported; Path = $target; ExecutionStatus = $export.ExecutionStatus; ExitCode = $export.ExitCode; Error = if ($exported) { $null } else { $export.Detail } })
        }
        else {
            $null = Add-WudCollectionGap -Context $Context -Collector 'events' -Source $channel -Status $metadata.ExecutionStatus -Detail $metadata.Detail
            $null = $exports.Add([pscustomobject][ordered]@{ Channel = $channel; Exported = $false; Path = $null; ExecutionStatus = $metadata.ExecutionStatus; ExitCode = $metadata.ExitCode; Error = $metadata.Detail })
        }
    }
    $start = (Get-Date).AddDays(-[int]$Context.Settings.eventLookbackDays)
    $events = New-Object Collections.ArrayList
    $queries = New-Object Collections.ArrayList
    foreach ($log in $channels) {
        $returnedCount = 0
        try {
            foreach ($event in @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $start; Level = @(1, 2, 3) } -ErrorAction Stop | Select-Object -First 5000)) {
                $returnedCount++
                $null = $events.Add([pscustomobject][ordered]@{
                    TimeCreated = $event.TimeCreated
                    LogName     = $event.LogName
                    Provider    = $event.ProviderName
                    Id          = $event.Id
                    Level       = $event.LevelDisplayName
                    RecordId    = $event.RecordId
                    ProcessId   = $event.ProcessId
                    Message     = $event.Message
                })
            }
            $null = $queries.Add([pscustomobject]@{ Channel = $log; Status = 'Available'; WarningErrorCount = $returnedCount; Error = $null })
        }
        catch {
            $disposition = Get-WudEventQueryErrorDisposition $_
            if ($disposition -eq 'Empty') { $null = $queries.Add([pscustomobject]@{ Channel = $log; Status = 'Empty'; WarningErrorCount = 0; Error = $null }) }
            else {
                $detail = Get-WudErrorDetail -ErrorRecord $_
                $null = Add-WudCollectionGap -Context $Context -Collector 'events' -Source $log -Status 'ReadableQueryFailed' -Detail $detail
                $null = $queries.Add([pscustomobject]@{ Channel = $log; Status = 'Failed'; WarningErrorCount = $returnedCount; Error = $detail })
            }
        }
    }
    Write-WudJsonAtomic -Path (Join-Path $path 'event-query-results.json') -InputObject @($queries)
    Write-WudJsonAtomic -Path (Join-Path $path 'event-exports.json') -InputObject @($exports)
    Write-WudJsonAtomic -Path (Join-Path $path 'errors-and-warnings.json') -InputObject @($events) -Depth 10
    # Informational WU events contain download/install boundaries. Preserve
    # their named XML fields instead of matching localized display messages.
    $state = Read-WudJson -Path (Join-Path $Context.RunPath 'State/run-state.json')
    $created = Get-WudObjectPropertyValue $state 'CreatedUtc'
    if ($created) { $start = ([DateTimeOffset]::Parse($created)).UtcDateTime }
    $updateEvents = Get-WudUpdateEventRecords -StartTime $start -MaximumEvents 10000
    $archivedEvents = Get-WudArchivedUpdateEventRecords -Context $Context -StartTime $start -MaximumEvents 10000
    $updateEvents.Records = @($updateEvents.Records) + @($archivedEvents.Records)
    $updateEvents.Providers = @($updateEvents.Providers) + @($archivedEvents.Providers)
    Write-WudJsonAtomic -Path (Join-Path $path 'update-lifecycle-events.json') -InputObject $updateEvents -Depth 15
    foreach ($provider in $updateEvents.Providers) {
        if ($provider.Status -in @('Failed', 'Truncated')) { $null = Add-WudCollectionGap -Context $Context -Collector 'update-events' -Source $provider.Channel -Status $provider.Status -Detail ('Update lifecycle event query: ' + $provider.Error) }
    }
}

function Get-WudSetupDiagExecutable {
    param($Context)
    $candidates = New-Object Collections.ArrayList
    $toolCache = New-WudDirectory -Path (Join-Path $env:ProgramData 'WUPA\Tools')
    $cached = Join-Path $toolCache 'SetupDiag.exe'
    $cacheMetadataPath = Join-Path $toolCache 'SetupDiag.metadata.json'
    if (Test-Path -LiteralPath $cached) { $null = $candidates.Add($cached) }
    foreach ($candidate in @(
        (Join-Path $env:SystemDrive '$WINDOWS.~BT\Sources\SetupDiag.exe'),
        (Join-Path $env:SystemDrive 'Windows.old\$WINDOWS.~BT\Sources\SetupDiag.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { $null = $candidates.Add($candidate) }
    }
    if (-not $Context.NoInternet) {
        $temporary = Join-Path $toolCache ("SetupDiag-{0}.download" -f [Guid]::NewGuid().ToString('N'))
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $request = [Net.HttpWebRequest]::Create([string]$Context.Settings.setupDiagDownloadUrl)
            $request.Method = 'GET'
            $request.AllowAutoRedirect = $true
            $request.MaximumAutomaticRedirections = 10
            $request.Timeout = 120000
            $request.ReadWriteTimeout = 120000
            $request.UserAgent = "WUPA/$($Context.ToolVersion)"
            if ($request.Proxy) { $request.Proxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials }
            $response = $null
            $sourceStream = $null
            $destinationStream = $null
            try {
                $response = $request.GetResponse()
                $finalUri = $response.ResponseUri.AbsoluteUri
                $sourceStream = $response.GetResponseStream()
                $destinationStream = [IO.File]::Open($temporary, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $sourceStream.CopyTo($destinationStream)
            }
            finally {
                if ($destinationStream) { $destinationStream.Dispose() }
                if ($sourceStream) { $sourceStream.Dispose() }
                if ($response) { $response.Close() }
            }
            $finalHost = ([Uri]$finalUri).DnsSafeHost
            if ($finalHost -notmatch '(?i)(^|\.)(microsoft\.com|windowsupdate\.com)$') { throw "SetupDiag redirected to an unapproved host: $finalHost" }
            $signature = Get-AuthenticodeSignature -FilePath $temporary
            $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
            if ($signature.Status -ne 'Valid' -or $subject -notmatch 'Microsoft') { throw "Downloaded SetupDiag signature was not valid Microsoft code signing (status: $($signature.Status), subject: $subject)." }
            $downloadedItem = Get-Item -LiteralPath $temporary
            if ([string]::IsNullOrWhiteSpace([string]$downloadedItem.VersionInfo.FileVersion) -or [string]$downloadedItem.VersionInfo.FileVersion -notmatch '\d+\.\d+') { throw 'Downloaded SetupDiag did not expose a valid file version.' }
            $downloadIdentity = '{0} {1} {2}' -f $downloadedItem.VersionInfo.OriginalFilename, $downloadedItem.VersionInfo.FileDescription, $downloadedItem.VersionInfo.ProductName
            if ($downloadIdentity -notmatch '(?i)SetupDiag') { throw 'The downloaded Microsoft-signed file did not identify itself as SetupDiag.' }
            Move-Item -LiteralPath $temporary -Destination $cached -Force
            $cachedItem = Get-Item -LiteralPath $cached
            Write-WudJsonAtomic -Path $cacheMetadataPath -InputObject ([pscustomobject][ordered]@{
                RequestedUri = [string]$Context.Settings.setupDiagDownloadUrl
                FinalUri = $finalUri
                DownloadedUtc = [DateTime]::UtcNow.ToString('o')
                Version = $cachedItem.VersionInfo.FileVersion
                Signer = $subject
                Sha256 = Get-WudFileHashSafe -Path $cached
            })
            $null = $candidates.Insert(0, $cached)
        }
        catch {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
            Write-WudLog -Context $Context -Level WARN -Message ("Could not refresh SetupDiag: {0}" -f $_.Exception.Message)
        }
    }
    $verified = New-Object Collections.ArrayList
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        try {
            $signature = Get-AuthenticodeSignature -FilePath $candidate
            $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
            if ($signature.Status -eq 'Valid' -and $subject -match 'Microsoft') {
                $item = Get-Item -LiteralPath $candidate
                if ([string]::IsNullOrWhiteSpace([string]$item.VersionInfo.FileVersion) -or [string]$item.VersionInfo.FileVersion -notmatch '\d+\.\d+') { continue }
                $candidateIdentity = '{0} {1} {2}' -f $item.VersionInfo.OriginalFilename, $item.VersionInfo.FileDescription, $item.VersionInfo.ProductName
                if ($candidateIdentity -notmatch '(?i)SetupDiag') { continue }
                $sourceUri = 'Local system copy'
                if ($candidate -eq $cached -and (Test-Path -LiteralPath $cacheMetadataPath)) {
                    try { $sourceUri = [string](Read-WudJson -Path $cacheMetadataPath).FinalUri } catch { }
                }
                $null = $verified.Add([pscustomobject]@{ Path = $candidate; Version = $item.VersionInfo.FileVersion; SignatureStatus = [string]$signature.Status; Signer = $subject; SourceUri = $sourceUri; Sha256 = Get-WudFileHashSafe $candidate })
            }
        }
        catch { }
    }
    if (@($verified).Count -eq 0) { return $null }
    return @($verified | Sort-Object { try { [Version]$_.Version } catch { [Version]'0.0' } } -Descending)[0]
}

function Invoke-WudSetupDiagCollector {
    param($Context)
    $path = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'SetupDiag')
    if ($Context.Mode -eq 'Preflight') {
        Write-WudJsonAtomic -Path (Join-Path $path 'setupdiag-tool.json') -InputObject ([pscustomobject]@{ Executed = $false; Reason = 'Baseline only. Existing SetupDiag results and setup logs cannot describe the future monitored upgrade.' })
        return
    }
    $history = @(Get-WudFeatureUpdateHistory -Context $Context -CurrentInventory ([pscustomobject]$Context.Inventory))
    $Context.UpgradeTracking = Get-WudUpgradeTrackingModel -Context $Context -FeatureHistory $history
    $candidateRoots = New-Object Collections.ArrayList
    $rejected = New-Object Collections.ArrayList
    foreach ($name in @('WindowsBT-Rollback', 'WindowsBT-Panther', 'WUPA-SetupCopyLogs', 'WindowsOld-Panther')) {
        $candidate = Join-Path (Join-Path $Context.SnapshotPath 'Raw') $name
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $logs = @(Get-ChildItem -LiteralPath $candidate -File -Recurse -Filter 'setupact*.log' -ErrorAction SilentlyContinue)
        if (@($logs).Count -gt 0) {
            $profiles = @($logs | ForEach-Object {
                $profile = Get-WudSetupLogProfile -Context $Context -File $_ -Sequence 0
                Set-WudAttemptScope -Context $Context -Attempt $profile -FeatureHistory $history -Identity $Context.Inventory['Identity']
            })
            # SetupDiag recursively chooses a setup log. A root containing a
            # second, different session is unsafe even if its newest log matches.
            if (@($profiles | Where-Object { -not $_.IncludedForUpgradeReview }).Count -gt 0 -or @($profiles.Sha256 | Select-Object -Unique).Count -ne 1) {
                $null = $rejected.Add([pscustomobject]@{ Path = $candidate; Reason = 'Not all recursive setupact inputs belong to one validated target session.'; Profiles = $profiles })
                continue
            }
            $newest = @($logs | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)[0]
            $null = $candidateRoots.Add([pscustomobject]@{ Path = $candidate; NewestUtc = $newest.LastWriteTimeUtc; SetupAct = $newest.FullName; Profile = $profiles[0] })
        }
    }
    $selectedInput = @($candidateRoots | Sort-Object NewestUtc -Descending | Select-Object -First 1)
    if (@($selectedInput).Count -eq 0) {
        $null = Add-WudCollectionGap -Context $Context -Collector 'setupdiag' -Source 'Scoped feature-upgrade setup logs' -Status 'NoScopedInput' -Detail 'No uncontaminated setup session passed target identity, target build, ownership, and window gates. SetupDiag was not run against unrelated or ambiguous logs.'
        Write-WudJsonAtomic -Path (Join-Path $path 'setupdiag-tool.json') -InputObject ([pscustomobject]@{ Executed = $false; Reason = 'No identity-scoped feature-upgrade input.'; Identity = $Context.UpgradeTracking.Identity; RejectedInputs = @($rejected) }) -Depth 30
        return
    }
    $tool = Get-WudSetupDiagExecutable -Context $Context
    if (-not $tool) {
        $null = Add-WudCollectionGap -Context $Context -Collector 'setupdiag' -Source 'SetupDiag.exe' -Status 'Unavailable' -Detail 'No Microsoft-signed SetupDiag executable was available.'
        Write-WudJsonAtomic -Path (Join-Path $path 'setupdiag-tool.json') -InputObject ([pscustomobject]@{ Available = $false; Executed = $false; Reason = 'No Microsoft-signed SetupDiag executable was available.' })
        return
    }
    $inputMetadata = [pscustomobject][ordered]@{
        Available          = $true
        Tool               = $tool
        Executed           = $true
        InputPath          = $selectedInput[0].Path
        InputSetupAct      = $selectedInput[0].SetupAct
        InputEvidenceRef   = (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $selectedInput[0].SetupAct).Replace('\', '/')
        InputUpdateID      = $Context.UpgradeTracking.Identity.UpdateID
        InputRevisionNumber = $Context.UpgradeTracking.Identity.RevisionNumber
        InputTargetBuild   = $selectedInput[0].Profile.TargetBuild
        InputAttributionBasis = $selectedInput[0].Profile.AttributionBasis
        ExcludedByDesign   = @('Windows\\Panther', 'Commands', 'CurrentDiagnostics', 'Compatibility\\MediaScan')
        ScopingNote        = 'Every recursive setupact input passed target identity/build/window gates and is byte-identical to the selected session. Bounded time association remains context rather than direct GUID attribution.'
    }
    Write-WudJsonAtomic -Path (Join-Path $path 'setupdiag-tool.json') -InputObject $inputMetadata
    $output = Join-Path $path 'SetupDiagResults.json'
    $result = Invoke-WudProcess -Context $Context -FilePath $tool.Path -ArgumentList @(("/Output:{0}" -f $output), ("/LogsPath:{0}" -f $selectedInput[0].Path), '/Format:json', '/ZipLogs:False', '/NoTel', '/Verbose') -Name 'setupdiag' -TimeoutSeconds ([int]$Context.Settings.timeoutsSeconds.setupDiag) -SuccessExitCodes @(0, 1) -WorkingDirectory $path -ExpectedArtifacts @($output)
    Write-WudJsonAtomic -Path (Join-Path $path 'setupdiag-execution.json') -InputObject $result -Depth 20
}

function Invoke-WudAllCollectors {
    param([Parameter(Mandatory = $true)]$Context)
    $null = Invoke-WudCollector $Context 'identity' 'Device, operating system, build, and attempt identity' { Invoke-WudIdentityCollector $Context } $true
    $null = Invoke-WudCollector $Context 'storage-readiness' 'OS volume, partition, WinRE, BitLocker, firmware, and Secure Boot facts' { Invoke-WudHardwareCollector $Context } $true
    $Context.Inventory['Software'] = [pscustomobject][ordered]@{
        CollectionStatus  = 'DisabledByDesign'
        Reason            = 'Installed-software inventory is outside the focused Windows Update performance evidence profile. Setup-reported compatibility blocks remain available in native setup evidence.'
        Applications      = @()
        Services          = @()
        AntivirusProducts = @()
    }
    $null = Invoke-WudCollector $Context 'drivers' 'Problem devices plus boot, storage, display, and network driver facts' { Invoke-WudDriverCollector $Context }
    $null = Invoke-WudCollector $Context 'update-control' 'Windows Update policy, core services, BITS, configured endpoints, proxy, and time' { Invoke-WudManagementCollector $Context }
    $null = Invoke-WudCollector $Context 'update-history' 'Windows Update history and pending-reboot facts' { Invoke-WudServicingCollector $Context } $true
    $null = Invoke-WudCollector $Context 'native-update-evidence' 'Feature-update setup, rollback, Windows Update, USO, and Delivery Optimization evidence' { Invoke-WudRawEvidenceCollector $Context } $true
    $null = Invoke-WudCollector $Context 'update-telemetry' 'Readable Windows Update and Delivery Optimization records' { Invoke-WudWindowsUpdateLogCollector $Context }
    $null = Invoke-WudCollector $Context 'update-events' 'Native update/setup event channels and normalized warnings/errors' { Invoke-WudEventCollector $Context }
    $null = Invoke-WudCollector $Context 'setupdiag' 'Microsoft SetupDiag offline analysis with telemetry disabled' { Invoke-WudSetupDiagCollector $Context }
    $Context.Inventory['Provenance'] = [pscustomobject][ordered]@{ ProcessRecords = @($Context.ProcessRecords); CollectionGaps = @($Context.CollectionGaps) }
    Write-WudJsonAtomic -Path (Join-Path $Context.SnapshotPath 'collector-records.json') -InputObject @($Context.CollectorRecords)
    Write-WudJsonAtomic -Path (Join-Path $Context.SnapshotPath 'inventory.json') -InputObject $Context.Inventory -Depth 30
}

Export-ModuleMember -Function @('Invoke-WudAllCollectors', 'Get-WudPendingRebootState')
