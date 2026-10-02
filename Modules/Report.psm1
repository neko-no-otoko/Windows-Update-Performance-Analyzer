Set-StrictMode -Version 2.0

function ConvertTo-WudHtmlText {
    param($Value)
    if ($null -eq $Value) { return '' }
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-WudProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Get-WudAllCollectorRecords {
    param($Context)
    $records = New-Object Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $Context.EvidencePath -File -Recurse -Filter 'collector-records.json' -ErrorAction SilentlyContinue)) {
        $snapshot = Split-Path -Leaf (Split-Path -Parent $file.FullName)
        # PS5 ConvertFrom-Json emits a root array as one pipeline object;
        # wrapping that pipeline in @() nests it and hides every record's Id.
        # Assign first, then foreach enumerates the JSON array on PS5 and PS7.
        try { $snapshotRecords = Read-WudJson -Path $file.FullName }
        catch {
            $null = Add-WudCollectionGap -Context $Context -Collector 'report-collector-records' -Source $file.FullName -Status 'MetadataUnreadable' -Detail $_.Exception.Message -Impact 'Material'
            continue
        }
        foreach ($record in $snapshotRecords) {
            if (-not $record) { continue }
            $null = $records.Add([pscustomobject][ordered]@{
                Snapshot    = $snapshot
                Id          = Get-WudProperty $record 'Id' 'unknown'
                Version     = Get-WudProperty $record 'Version' $Context.ToolVersion
                Description = Get-WudProperty $record 'Description'
                Required    = Get-WudProperty $record 'Required' $false
                Status      = Get-WudProperty $record 'Status' 'Unknown'
                Detail      = Get-WudProperty $record 'Detail'
                StartedUtc  = Get-WudProperty $record 'StartedUtc'
                EndedUtc    = Get-WudProperty $record 'EndedUtc'
                DurationMs  = Get-WudProperty $record 'DurationMs'
            })
        }
    }
    if (@($records).Count -eq 0) {
        foreach ($record in @($Context.CollectorRecords)) {
            $null = $records.Add([pscustomobject][ordered]@{
                Snapshot = $Context.PhaseLabel; Id = $record.Id; Version = Get-WudProperty $record 'Version' $Context.ToolVersion
                Description = $record.Description; Required = $record.Required; Status = $record.Status; Detail = $record.Detail
                StartedUtc = $record.StartedUtc; EndedUtc = $record.EndedUtc; DurationMs = $record.DurationMs
            })
        }
    }
    return @($records)
}

function New-WudEvidenceArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        $Context
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $DestinationPath) { Remove-Item -LiteralPath $DestinationPath -Force }
    $destinationParent = Split-Path -Parent $DestinationPath
    if ($destinationParent) { $null = New-WudDirectory -Path $destinationParent }
    $zipStream = [IO.File]::Open($DestinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = $null
    try {
        $archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        foreach ($file in @(Get-WudFileTreeSafe -RootPath $SourcePath -Context $Context -Collector 'report-archive')) {
            $relative = (Get-WudRelativePath -BasePath $SourcePath -Path $file.FullName).Replace('\', '/')
            $isReparsePoint = ([int]$file.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0
            if ($isReparsePoint) {
                if ($Context) {
                    $detail = 'The staged item is a filesystem reparse point. Its target was not followed or duplicated into the ZIP.'
                    $null = Add-WudCollectionGap -Context $Context -Collector 'report-archive' -Source $file.FullName -Status 'ArchiveReparsePointSkipped' -Detail $detail
                    Write-WudLog -Context $Context -Level INFO -Message ("Indexed reparse point was intentionally excluded from the evidence archive: {0}" -f $file.FullName)
                }
                continue
            }
            $sourceStream = $null
            $entryStream = $null
            try {
                # Open the source before creating its entry. A missing, broken,
                # or unreadable source must not leave a misleading empty entry.
                $sourceStream = Open-WudFileReadStream -Path $file.FullName
                $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                if ($file.LastWriteTime.Year -ge 1980 -and $file.LastWriteTime.Year -le 2107) {
                    $entry.LastWriteTime = $file.LastWriteTime
                }
                $entryStream = $entry.Open()
                $sourceStream.CopyTo($entryStream)
            }
            catch {
                if ($Context) {
                    $archiveException = $_.Exception
                    while ($archiveException.InnerException) { $archiveException = $archiveException.InnerException }
                    $probePath = if (Test-WudIsWindows) { ConvertTo-WudExtendedLengthPath -Path $file.FullName } else { $file.FullName }
                    $existsAtFailure = [IO.File]::Exists($probePath)
                    $status = if (-not $existsAtFailure) { 'ArchiveSourceMissing' } elseif ($file.FullName.Length -ge 248) { 'ArchiveLongPathReadFailed' } else { 'ArchiveReadFailed' }
                    $detail = '{0}: {1} PathLength={2}; ExistsAtFailure={3}; ReparsePoint=False' -f $archiveException.GetType().FullName, $archiveException.Message, $file.FullName.Length, $existsAtFailure
                    $null = Add-WudCollectionGap -Context $Context -Collector 'report-archive' -Source $file.FullName -Status $status -Detail $detail
                    Write-WudLog -Context $Context -Level WARN -Message ("Evidence could not be added to the archive: {0}: {1}" -f $file.FullName, $detail)
                }
            }
            finally {
                if ($entryStream) { $entryStream.Dispose() }
                if ($sourceStream) { $sourceStream.Dispose() }
            }
        }
    }
    finally {
        if ($archive) { $archive.Dispose() }
        else { $zipStream.Dispose() }
    }
}

function Test-WudEvidenceArchiveIntegrity {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$EvidenceManifest
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $missing = New-Object Collections.ArrayList
    $mismatched = New-Object Collections.ArrayList
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entries = @{}
        foreach ($entry in $archive.Entries) { $entries[$entry.FullName.ToLowerInvariant()] = $entry }
        $expectedEvidence = @($EvidenceManifest | Where-Object {
            -not $_.PSObject.Properties['ArchiveEligible'] -or [bool]$_.ArchiveEligible
        })
        foreach ($item in $expectedEvidence) {
            $name = ([string]$item.RelativePath).Replace('\', '/').ToLowerInvariant()
            if (-not $entries.ContainsKey($name)) { $null = $missing.Add($item.RelativePath); continue }
            if (-not $item.Sha256) { continue }
            $stream = $null
            $sha = $null
            try {
                $stream = $entries[$name].Open()
                $sha = [Security.Cryptography.SHA256]::Create()
                $actual = ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
                if ($actual -ne [string]$item.Sha256) { $null = $mismatched.Add($item.RelativePath) }
            }
            finally {
                if ($sha) { $sha.Dispose() }
                if ($stream) { $stream.Dispose() }
            }
        }
        return [pscustomobject][ordered]@{
            Verified       = (@($missing).Count -eq 0 -and @($mismatched).Count -eq 0)
            ExpectedFiles  = @($expectedEvidence).Count
            ArchiveEntries = $archive.Entries.Count
            Missing        = @($missing)
            HashMismatches = @($mismatched)
            VerifiedUtc    = [DateTime]::UtcNow.ToString('o')
        }
    }
    finally { $archive.Dispose() }
}

function Get-WudArtifactRecord {
    param([string]$Path, [string]$BasePath)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $file = Get-Item -LiteralPath $Path
    return [pscustomobject][ordered]@{
        Name         = Get-WudRelativePath -BasePath $BasePath -Path $file.FullName
        Length       = $file.Length
        LastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
        Sha256       = Get-WudFileHashSafe -Path $file.FullName
    }
}

function Export-WudCsvContract {
    param(
        [Parameter(Mandatory = $true)]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $rowArray = @($Rows)
    if ($rowArray.Count -gt 0) {
        @($rowArray | Select-Object -Property $Headers) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
        return
    }
    $headerLine = (@($Headers | ForEach-Object { '"' + ([string]$_).Replace('"', '""') + '"' }) -join ',') + [Environment]::NewLine
    Write-WudText -Path $Path -Text $headerLine
}

function Get-WudEvidenceSourceMappings {
    param($Context)
    $mappings = New-Object Collections.ArrayList
    foreach ($file in @(Get-ChildItem -LiteralPath $Context.EvidencePath -File -Recurse -Filter 'raw-copy-results.json' -ErrorAction SilentlyContinue)) {
        $relativeRecord = (Get-WudRelativePath -BasePath $Context.EvidencePath -Path $file.FullName).Replace('\', '/')
        $snapshot = @($relativeRecord -split '/')[0]
        try { $record = Read-WudJson -Path $file.FullName }
        catch {
            $null = Add-WudCollectionGap -Context $Context -Collector 'report-source-mappings' -Source $file.FullName -Status 'MetadataUnreadable' -Detail $_.Exception.Message -Impact 'Material'
            continue
        }
        if (-not $record) {
            $null = Add-WudCollectionGap -Context $Context -Collector 'report-source-mappings' -Source $file.FullName -Status 'MetadataUnreadable' -Detail 'Raw-copy metadata was empty or unavailable.' -Impact 'Material'
            continue
        }
        foreach ($source in @(Get-WudProperty $record 'Sources' @())) {
            if (-not $source) { continue }
            $sourcePath = Get-WudProperty $source 'Source'
            $destination = Get-WudProperty $source 'Destination'
            $present = Get-WudProperty $source 'Present'
            $copied = Get-WudProperty $source 'Copied'
            if ($null -eq $present -or $null -eq $copied -or -not $sourcePath -or -not $destination) { $null = Add-WudCollectionGap -Context $Context -Collector 'report-source-mappings' -Source $file.FullName -Status 'MetadataIncomplete' -Detail 'A raw source record is missing required source/copy-state fields.' -Impact 'Material' }
            $null = $mappings.Add([pscustomobject][ordered]@{
                Snapshot      = $snapshot
                SourcePath    = $sourcePath
                ArchivePrefix = if ($destination) { ('{0}/Raw/{1}' -f $snapshot, $destination) } else { $null }
                Present       = $present
                Copied        = [bool]$copied
                State         = if ($null -eq $present -or $null -eq $copied -or -not $sourcePath -or -not $destination) { 'MetadataIncomplete' } elseif (-not $present) { 'Missing' } elseif ($copied) { 'Copied' } else { 'CopyFailedOrEmpty' }
            })
        }
        $dump = Get-WudProperty $record 'MemoryDump'
        if ($dump) {
            $dumpPath = Get-WudProperty $dump 'Path'
            $copied = [bool](Get-WudProperty $dump 'Copied' $false)
            $excluded = (Get-WudProperty $dump 'CollectionStatus') -eq 'ExcludedByDesign'
            if (-not $excluded -and -not $dumpPath) { $null = Add-WudCollectionGap -Context $Context -Collector 'report-source-mappings' -Source $file.FullName -Status 'MetadataIncomplete' -Detail 'Legacy dump metadata does not identify a source path.' -Impact 'Material' }
            $null = $mappings.Add([pscustomobject][ordered]@{
                Snapshot      = $snapshot
                SourcePath    = $dumpPath
                ArchivePrefix = if (-not $excluded -and $copied -and $dumpPath) { "$snapshot/Raw/Windows-MEMORY.DMP" } else { $null }
                Present       = if ($excluded -or -not $dumpPath) { $null } else { Get-WudProperty $dump 'Present' $true }
                Copied        = if ($excluded) { $false } else { $copied }
                State         = if ($excluded) { 'ExcludedByDesign' } elseif (-not $dumpPath) { 'MetadataIncomplete' } elseif ($copied) { 'Copied' } else { 'MetadataOnly' }
                Length        = Get-WudProperty $dump 'Length'
                LastWriteUtc  = Get-WudProperty $dump 'LastWriteUtc'
                Sha256        = Get-WudProperty $dump 'Sha256'
                Detail        = if ($excluded) { Get-WudProperty $dump 'Reason' } else { Get-WudProperty $dump 'CopyReason' }
            })
        }
    }
    return @($mappings)
}

function New-WudSummaryObject {
    param($Context, $CollectorRecords, $ArtifactRecords)
    $current = Get-WudProperty -Object $Context.Inventory -Name 'Current'
    $baseline = Get-WudProperty -Object $Context.Inventory -Name 'Baseline'
    $currentIdentity = Get-WudProperty -Object $current -Name 'Identity'
    if (-not $currentIdentity) { $currentIdentity = Get-WudProperty -Object $baseline -Name 'Identity' }
    $baselineIdentity = Get-WudProperty -Object $baseline -Name 'Identity'
    if (-not $baselineIdentity) { $baselineIdentity = $currentIdentity }
    if ($baselineIdentity -eq $currentIdentity) {
        $history = @(Get-WudProperty -Object $currentIdentity -Name 'SourceOsHistory' -Default @())
        $historicalSource = @($history | Where-Object { $_.DisplayVersion -and $_.DisplayVersion -ne $currentIdentity.DisplayVersion } | Select-Object -First 1)
        if (@($historicalSource).Count -gt 0) {
            $baselineIdentity = [pscustomobject][ordered]@{
                ProductName    = $historicalSource[0].ProductName
                EditionId      = $currentIdentity.EditionId
                DisplayVersion = $historicalSource[0].DisplayVersion
                CurrentBuild   = $historicalSource[0].CurrentBuild
                UBR            = $historicalSource[0].UBR
            }
        }
    }
    $primary = $Context.PrimaryFinding
    $ruleCatalog = Read-WudJson -Path (Join-Path $Context.ToolRoot 'Data/rules.json')
    $targetCatalog = Read-WudJson -Path (Join-Path $Context.ToolRoot 'Data/targets.json')
    $analysisMode = if ($Context.ReviewData -and (Get-WudProperty $Context.ReviewData 'AnalysisMode')) { [string](Get-WudProperty $Context.ReviewData 'AnalysisMode') } else { 'DeterministicLegacy' }
    $summaryObject = [pscustomobject][ordered]@{
        SchemaVersion      = 2
        SchemaSemanticVersion = '2.0.0'
        ToolVersion        = $Context.ToolVersion
        AnalysisMode       = $analysisMode
        RuleCatalogVersion = Get-WudProperty $ruleCatalog 'catalogVersion' '1'
        TargetMapVersion   = Get-WudProperty $targetCatalog 'mapVersion' '1'
        RunId              = $Context.RunId
        Mode               = $Context.Mode
        PhaseLabel         = $Context.PhaseLabel
        StartedUtc         = $Context.StartedUtc
        CompletedUtc       = $Context.CompletedUtc
        Run                = [pscustomobject][ordered]@{
            RunId = $Context.RunId; Mode = $Context.Mode; PhaseLabel = $Context.PhaseLabel
            ComputerName = Get-WudProperty $currentIdentity 'ComputerName'
            StartedUtc = $Context.StartedUtc; CompletedUtc = $Context.CompletedUtc
        }
        Timestamps         = [pscustomobject][ordered]@{ StartedUtc = $Context.StartedUtc; CompletedUtc = $Context.CompletedUtc }
        Sensitive          = $true
        Outcome            = $Context.Outcome
        StatusModel        = $Context.StatusModel
        Recorder           = $Context.Recorder
        UpgradeIdentity    = Get-WudProperty $Context.UpgradeTracking 'Identity'
        UpgradeTiming      = $Context.UpgradeTiming
        WindowsUpdateLogCoverage = Get-WudProperty $Context.UpgradeTracking 'LogCoverage' @()
        UpdateActivity     = $Context.UpdateActivity
        ExitCode           = $Context.ExitCode
        Device             = [pscustomobject][ordered]@{
            ComputerName = Get-WudProperty $currentIdentity 'ComputerName'
            Domain       = Get-WudProperty $currentIdentity 'Domain'
            Manufacturer = Get-WudProperty $currentIdentity 'Manufacturer'
            Model        = Get-WudProperty $currentIdentity 'Model'
            SerialNumber = Get-WudProperty $currentIdentity 'SerialNumber'
            UUID         = Get-WudProperty $currentIdentity 'UUID'
        }
        SourceOs           = [pscustomobject][ordered]@{
            Product        = Get-WudProperty $baselineIdentity 'ProductName'
            Edition        = Get-WudProperty $baselineIdentity 'EditionId'
            DisplayVersion = Get-WudProperty $baselineIdentity 'DisplayVersion'
            Build          = Get-WudProperty $baselineIdentity 'CurrentBuild'
            UBR            = Get-WudProperty $baselineIdentity 'UBR'
        }
        CurrentOs          = [pscustomobject][ordered]@{
            Product        = Get-WudProperty $currentIdentity 'ProductName'
            Edition        = Get-WudProperty $currentIdentity 'EditionId'
            DisplayVersion = Get-WudProperty $currentIdentity 'DisplayVersion'
            Build          = Get-WudProperty $currentIdentity 'CurrentBuild'
            UBR            = Get-WudProperty $currentIdentity 'UBR'
        }
        TargetOs           = [pscustomobject][ordered]@{
            Product        = $Context.Target.product
            DisplayVersion = $Context.Target.displayVersion
            BuildFamily    = $Context.Target.buildFamily
        }
        PrimaryFinding     = $primary
        Findings           = @($Context.Findings)
        FindingCounts      = [pscustomobject][ordered]@{
            Blocker     = @($Context.Findings | Where-Object { $_.Status -ne 'Historical' -and $_.Severity -eq 'Blocker' }).Count
            Error       = @($Context.Findings | Where-Object { $_.Status -ne 'Historical' -and $_.Severity -eq 'Error' }).Count
            Warning     = @($Context.Findings | Where-Object { $_.Status -ne 'Historical' -and $_.Severity -eq 'Warning' }).Count
            Information = @($Context.Findings | Where-Object { $_.Status -ne 'Historical' -and $_.Severity -eq 'Information' }).Count
            Historical  = @($Context.Findings | Where-Object Status -eq 'Historical').Count
            Total       = @($Context.Findings).Count
        }
        Attempts            = @($Context.Attempts)
        CollectionCoverage  = @($CollectorRecords)
        CollectionGaps      = @($Context.CollectionGaps)
        CollectionComplete  = $Context.CollectionComplete
        ArtifactHashes       = @($ArtifactRecords)
        Persistence          = Get-WudProperty $Context.Inventory 'Persistence'
    }
    $summaryObject | Add-Member -NotePropertyName Facts -NotePropertyValue @($Context.Facts)
    $summaryObject | Add-Member -NotePropertyName FactCounts -NotePropertyValue ([pscustomobject][ordered]@{
        Observed       = @($Context.Facts | Where-Object FactType -eq 'Observed').Count
        SourceReported = @($Context.Facts | Where-Object FactType -eq 'SourceReported').Count
        Decoded        = @($Context.Facts | Where-Object FactType -eq 'Decoded').Count
        Computed       = @($Context.Facts | Where-Object FactType -eq 'Computed').Count
        Included       = @($Context.Facts | Where-Object ScopeStatus -eq 'Included').Count
        ContextOnly    = @($Context.Facts | Where-Object ScopeStatus -eq 'ContextOnly').Count
        Excluded       = @($Context.Facts | Where-Object ScopeStatus -eq 'Excluded').Count
        Total          = @($Context.Facts).Count
    })
    $summaryObject | Add-Member -NotePropertyName AttemptScope -NotePropertyValue ([pscustomobject][ordered]@{
        ValidatedWindowsUpdate = @($Context.Attempts | Where-Object { [bool](Get-WudProperty $_ 'IncludedForUpgradeReview' $false) }).Count
        Excluded = @($Context.Attempts | Where-Object { -not [bool](Get-WudProperty $_ 'IncludedForUpgradeReview' $false) }).Count
        Classifications = @($Context.Attempts | Group-Object { [string](Get-WudProperty $_ 'Classification' 'LegacyUnclassified') } | ForEach-Object { [pscustomobject]@{ Classification = $_.Name; Count = $_.Count } })
    })
    $summaryObject | Add-Member -NotePropertyName ExcludedEvidence -NotePropertyValue @($Context.ExcludedEvidence)
    $summaryObject | Add-Member -NotePropertyName ReviewBundle -NotePropertyValue $Context.ReviewBundle
    return $summaryObject
}

function Add-WudHtmlLine {
    param([Text.StringBuilder]$Builder, [string]$Text)
    $null = $Builder.AppendLine($Text)
}

function Get-WudOutcomeCssClass {
    param([string]$Outcome)
    return 'outcome-' + (($Outcome.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-'))
}

function Build-WudReportHtml {
    param($Context, $Summary, $EvidenceManifest, $CollectorRecords)
    $css = Get-Content -LiteralPath (Join-Path $Context.ToolRoot 'Assets/report.css') -Raw -Encoding UTF8
    $javascript = Get-Content -LiteralPath (Join-Path $Context.ToolRoot 'Assets/report.js') -Raw -Encoding UTF8
    $builder = New-Object Text.StringBuilder
    $outcomeClass = Get-WudOutcomeCssClass -Outcome $Summary.Outcome
    $sourceDisplay = '{0} ({1}.{2})' -f $Summary.SourceOs.DisplayVersion, $Summary.SourceOs.Build, $Summary.SourceOs.UBR
    $currentDisplay = '{0} ({1}.{2})' -f $Summary.CurrentOs.DisplayVersion, $Summary.CurrentOs.Build, $Summary.CurrentOs.UBR
    $targetDisplay = '{0} (build family {1})' -f $Summary.TargetOs.DisplayVersion, $Summary.TargetOs.BuildFamily
    $coverageTotal = @($CollectorRecords).Count
    $coverageGood = @($CollectorRecords | Where-Object Status -in @('Succeeded', 'CompletedWithWarnings')).Count
    $coverageText = if (-not $Summary.CollectionComplete) { 'Materially incomplete - review collection gaps' } elseif ($coverageTotal -gt 0) { '{0}/{1} collectors completed' -f $coverageGood, $coverageTotal } else { 'No collector records' }
    $nonceBytes = New-Object byte[] 18
    $random = New-Object Security.Cryptography.RNGCryptoServiceProvider
    try { $random.GetBytes($nonceBytes) } finally { $random.Dispose() }
    $nonce = [Convert]::ToBase64String($nonceBytes)

    Add-WudHtmlLine $builder '<!doctype html>'
    Add-WudHtmlLine $builder '<html lang="en"><head><meta charset="utf-8">'
    Add-WudHtmlLine $builder '<meta name="viewport" content="width=device-width,initial-scale=1">'
    Add-WudHtmlLine $builder ('<meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; base-uri &#39;none&#39;; object-src &#39;none&#39;; form-action &#39;none&#39;; style-src &#39;nonce-{0}&#39;; script-src &#39;nonce-{0}&#39;; img-src data:; font-src data:">' -f $nonce)
    Add-WudHtmlLine $builder ('<title>WUPA - {0} - {1}</title>' -f (ConvertTo-WudHtmlText $Summary.Device.ComputerName), (ConvertTo-WudHtmlText $Summary.Outcome))
    Add-WudHtmlLine $builder ('<style nonce="{0}">{1}</style></head><body>' -f $nonce, $css)
    Add-WudHtmlLine $builder '<div class="sensitive-banner">FULL-FIDELITY DIAGNOSTIC DATA - Contains device, user, domain, network, software, and log identifiers. Handle as sensitive.</div>'
    Add-WudHtmlLine $builder '<nav class="topbar" aria-label="Report controls"><div class="brand"><span class="brand-mark">W</span><span>WUPA</span></div><div class="top-actions"><button id="theme-toggle" type="button" aria-label="Toggle theme">Theme</button><button id="print-report" type="button">Print / PDF</button></div></nav>'
    Add-WudHtmlLine $builder '<main>'
    Add-WudHtmlLine $builder ('<header class="hero {0}"><div class="eyebrow">Windows feature-update diagnostic companion</div><h1>{1}</h1><span class="outcome-pill {0}">{2}</span><div class="hero-meta"><span><strong>Device:</strong> {3}</span><span><strong>Run:</strong> <code>{4}</code></span><span><strong>Completed:</strong> {5}</span></div></header>' -f $outcomeClass, (ConvertTo-WudHtmlText $Summary.Outcome), (ConvertTo-WudHtmlText $coverageText), (ConvertTo-WudHtmlText $Summary.Device.ComputerName), (ConvertTo-WudHtmlText $Summary.RunId), (ConvertTo-WudHtmlText $Summary.CompletedUtc))
    Add-WudHtmlLine $builder '<section class="summary-grid" aria-label="Upgrade summary">'
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Source OS</div><div class="metric-value">{0}</div><div class="metric-detail">{1}</div></div>' -f (ConvertTo-WudHtmlText $sourceDisplay), (ConvertTo-WudHtmlText $Summary.SourceOs.Edition))
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Current OS</div><div class="metric-value">{0}</div><div class="metric-detail">{1}</div></div>' -f (ConvertTo-WudHtmlText $currentDisplay), (ConvertTo-WudHtmlText $Summary.CurrentOs.Edition))
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Diagnostic target</div><div class="metric-value">{0}</div><div class="metric-detail">{1}</div></div>' -f (ConvertTo-WudHtmlText $targetDisplay), (ConvertTo-WudHtmlText $Summary.TargetOs.Product))
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Findings</div><div class="metric-value">{0} blocker &middot; {1} error</div><div class="metric-detail">{2} warning &middot; {3} informational &middot; {4} historical</div></div>' -f $Summary.FindingCounts.Blocker, $Summary.FindingCounts.Error, $Summary.FindingCounts.Warning, $Summary.FindingCounts.Information, $Summary.FindingCounts.Historical)
    Add-WudHtmlLine $builder '</section>'

    if ($Summary.Persistence) {
        $persistence = $Summary.Persistence
        $setupConfigState = if ($persistence.NoSetupHooks) { 'Setup hooks disabled by operator' } elseif ($persistence.SetupConfig.InvalidFormat) { 'SetupConfig invalid; hooks skipped' } elseif (@($persistence.SetupConfig.Conflicts).Count -gt 0) { '{0} SetupConfig conflicts retained' -f @($persistence.SetupConfig.Conflicts).Count } else { 'Guarded SetupConfig hooks installed' }
        Add-WudHtmlLine $builder ('<section class="panel"><h2>Cross-reboot capture</h2><div class="summary-grid"><div class="metric"><div class="metric-label">State</div><div class="metric-value">{0}</div></div><div class="metric"><div class="metric-label">Expires UTC</div><div class="metric-value">{1}</div></div><div class="metric"><div class="metric-label">Scheduled task</div><div class="metric-value">{2}</div></div><div class="metric"><div class="metric-label">Setup integration</div><div class="metric-value">{3}</div></div></div></section>' -f (ConvertTo-WudHtmlText $persistence.Status), (ConvertTo-WudHtmlText $persistence.ExpiresUtc), (ConvertTo-WudHtmlText $persistence.Task.FullName), (ConvertTo-WudHtmlText $setupConfigState))
    }

    if ($Summary.PrimaryFinding) {
        $primary = $Summary.PrimaryFinding
        Add-WudHtmlLine $builder '<section class="panel primary-finding"><div class="eyebrow">Primary finding</div>'
        Add-WudHtmlLine $builder ('<div class="finding-title-row"><h2>{0}</h2><div class="badges"><span class="badge {1}">{2}</span><span class="badge {3}">{4} confidence</span></div></div>' -f (ConvertTo-WudHtmlText $primary.Title), $primary.Severity.ToLowerInvariant(), (ConvertTo-WudHtmlText $primary.Severity), $primary.Confidence.ToLowerInvariant(), (ConvertTo-WudHtmlText $primary.Confidence))
        Add-WudHtmlLine $builder ('<p>{0}</p><h3>Recommended next action</h3><p><span id="primary-recommendation">{1}</span> <button class="copy-inline" type="button" data-copy-target="primary-recommendation">Copy recommendation</button></p>' -f (ConvertTo-WudHtmlText $primary.Explanation), (ConvertTo-WudHtmlText $primary.Recommendation))
        Add-WudHtmlLine $builder '</section>'
    }
    else {
        Add-WudHtmlLine $builder '<section class="panel primary-finding empty"><div class="eyebrow">Primary finding</div><h2>No blocker or error was identified</h2><p>Review warnings, collection coverage, and any evidence not available before treating this as a guarantee of upgrade success.</p></section>'
    }

    $detectedPhases = @($Context.Findings | Where-Object { $_.Phase } | ForEach-Object Phase) + @($Context.Attempts | ForEach-Object PhaseHint)
    Add-WudHtmlLine $builder '<section class="panel"><h2>Upgrade phase map</h2><p class="section-note">Detected phases are highlighted; an unhighlighted phase means no direct phase evidence was parsed, not necessarily that Setup never entered it.</p><div class="phase-track">'
    foreach ($phase in @('Downlevel', 'SafeOS', 'First Boot', 'OOBE Boot', 'Rollback')) {
        $detected = @($detectedPhases | Where-Object { $_ -match [Regex]::Escape($phase) }).Count -gt 0
        Add-WudHtmlLine $builder ('<div class="phase{0}">{1}</div>' -f $(if ($detected) { ' detected' } else { '' }), (ConvertTo-WudHtmlText $phase))
    }
    Add-WudHtmlLine $builder '</div></section>'

    $domains = @(
        [pscustomobject]@{ Id = 'domain-compatibility'; Title = 'Compatibility'; Categories = @('Compatibility'); Pattern = '(?i)Compatibility|AppCompat|CompatData|Appraiser|MediaScan'; Description = 'Appraiser, safeguard, system-requirement, application, and optional target-media scan evidence.' },
        [pscustomobject]@{ Id = 'domain-update'; Title = 'Update delivery and orchestration'; Categories = @('Update Delivery'); Pattern = '(?i)WindowsUpdate|USO|DeliveryOptimization|BITS'; Description = 'Offer, scan, download, proxy, source reachability, Delivery Optimization, and orchestrator evidence.' },
        [pscustomobject]@{ Id = 'domain-setup'; Title = 'Setup, migration, and rollback'; Categories = @('Setup', 'Migration'); Pattern = '(?i)Panther|Rollback|SetupDiag|MoSetup|Unattend|SetupCopyLogs'; Description = 'Setup phases, operations, result/extend codes, migration, fatal termination, and rollback evidence.' },
        [pscustomobject]@{ Id = 'domain-servicing'; Title = 'Servicing health'; Categories = @('Servicing'); Pattern = '(?i)Servicing|CBS|DISM|sfc|dism'; Description = 'Packages, update history, component store, pending state, DISM ScanHealth, and SFC verify-only.' },
        [pscustomobject]@{ Id = 'domain-drivers'; Title = 'Drivers and devices'; Categories = @('Drivers'); Pattern = '(?i)drivers|PnP|setupapi|pnputil|DeviceSetup'; Description = 'Signed drivers, driver store, problem devices, SetupAPI, and device installation evidence.' },
        [pscustomobject]@{ Id = 'domain-storage'; Title = 'Disks, WinRE, boot, and encryption'; Categories = @('Storage', 'Security', 'Hardware'); Pattern = '(?i)hardware|reagentc|bcdedit|manage-bde|mountvol|BitLocker|Storage'; Description = 'Capacity, partitions, storage health, BCD/boot state, WinRE, TPM, Secure Boot, and BitLocker status.' },
        [pscustomobject]@{ Id = 'domain-apps'; Title = 'Setup-reported application compatibility'; Categories = @('Applications', 'Compatibility'); Pattern = '(?i)CompatData|Appraiser|Compatibility|AppCompat'; Description = 'Application names and blocks reported directly by Windows Setup or Compatibility Appraiser. Broad installed-software inventory is disabled by design.' },
        [pscustomobject]@{ Id = 'domain-policy'; Title = 'Management and policy'; Categories = @('Policy'); Pattern = '(?i)Management|policy|gpresult|dsregcmd|MDM|ConfigMgr|Intune'; Description = 'WUfB, WSUS, Group Policy, MDM, enrollment, co-management, source selection, and target policy.' },
        [pscustomobject]@{ Id = 'domain-crash'; Title = 'Crashes and hardware symptoms'; Categories = @('Crash'); Pattern = '(?i)Events|WER|Minidump|MEMORY|setupmem|reliability|dxdiag|msinfo'; Description = 'Bug checks, WER, setup/minidumps, reliability, WHEA, storage, and unexpected-reboot symptoms.' }
    )
    Add-WudHtmlLine $builder '<section class="panel"><h2>Diagnostic domains</h2><p class="section-note">Each domain links the normalized findings to the relevant files in the evidence archive.</p><div class="domain-grid">'
    foreach ($domain in $domains) {
        $domainFindings = @($Context.Findings | Where-Object { $domain.Categories -contains $_.Category })
        $domainEvidence = @($EvidenceManifest | Where-Object { $_.RelativePath -match $domain.Pattern })
        Add-WudHtmlLine $builder ('<a class="domain-card" href="#{0}"><strong>{1}</strong><span>{2} findings &middot; {3} evidence files</span></a>' -f $domain.Id, (ConvertTo-WudHtmlText $domain.Title), @($domainFindings).Count, @($domainEvidence).Count)
    }
    Add-WudHtmlLine $builder '</div></section>'
    foreach ($domain in $domains) {
        $domainFindings = @($Context.Findings | Where-Object { $domain.Categories -contains $_.Category })
        $domainEvidence = @($EvidenceManifest | Where-Object { $_.RelativePath -match $domain.Pattern })
        Add-WudHtmlLine $builder ('<section class="panel domain-section" id="{0}"><h2>{1}</h2><p>{2}</p>' -f $domain.Id, (ConvertTo-WudHtmlText $domain.Title), (ConvertTo-WudHtmlText $domain.Description))
        if (@($domainFindings).Count -gt 0) {
            Add-WudHtmlLine $builder '<ul class="compact-list">'
            foreach ($finding in @($domainFindings | Select-Object -First 8)) { Add-WudHtmlLine $builder ('<li><span class="badge {0}">{1}</span> {2} <span class="muted">({3}, {4})</span></li>' -f (ConvertTo-WudHtmlText $finding.Severity.ToLowerInvariant()), (ConvertTo-WudHtmlText $finding.Severity), (ConvertTo-WudHtmlText $finding.Title), (ConvertTo-WudHtmlText $finding.Confidence), (ConvertTo-WudHtmlText $finding.Status)) }
            Add-WudHtmlLine $builder '</ul>'
        }
        else { Add-WudHtmlLine $builder '<p class="muted">No domain-specific finding was emitted. This is not proof that all evidence was available or clean.</p>' }
        if (@($domainEvidence).Count -gt 0) { Add-WudHtmlLine $builder ('<p class="evidence-ref"><strong>Representative evidence:</strong> {0}</p>' -f (ConvertTo-WudHtmlText (@($domainEvidence | Select-Object -First 8 | ForEach-Object RelativePath) -join '; '))) }
        else { Add-WudHtmlLine $builder '<p class="evidence-ref"><strong>Representative evidence:</strong> none indexed.</p>' }
        Add-WudHtmlLine $builder '</section>'
    }

    $categories = @($Context.Findings | ForEach-Object Category | Sort-Object -Unique)
    Add-WudHtmlLine $builder '<section class="panel"><h2>Findings and evidence chains</h2><div class="toolbar"><input id="finding-search" type="search" placeholder="Search findings, codes, drivers, applications, or evidence" aria-label="Search findings"><select id="severity-filter" aria-label="Filter by severity"><option value="">All severities</option><option value="blocker">Blocker</option><option value="error">Error</option><option value="warning">Warning</option><option value="information">Information</option></select><select id="status-filter" aria-label="Filter by status"><option value="">All statuses</option><option value="active">Active</option><option value="historical">Historical</option></select><select id="category-filter" aria-label="Filter by category"><option value="">All categories</option>'
    foreach ($category in $categories) { Add-WudHtmlLine $builder ('<option value="{0}">{1}</option>' -f (ConvertTo-WudHtmlText $category.ToLowerInvariant()), (ConvertTo-WudHtmlText $category)) }
    Add-WudHtmlLine $builder '</select></div><div id="finding-cards">'
    $findingIndex = 0
    foreach ($finding in @($Context.Findings | Sort-Object @{ Expression = { Get-WudSeverityRank $_.Severity }; Descending = $true }, @{ Expression = { Get-WudConfidenceRank $_.Confidence }; Descending = $true }, Title)) {
        $findingIndex++
        $severityClass = $finding.Severity.ToLowerInvariant()
        $categoryClass = $finding.Category.ToLowerInvariant()
        $findingAnchor = 'finding-' + (([string]$finding.FindingId) -replace '[^A-Za-z0-9_.-]', '-')
        Add-WudHtmlLine $builder ('<details id="{4}" class="finding-card {0}" data-severity="{0}" data-category="{1}" data-status="{2}"{3}><summary>{5}<span class="badges align-right"><span class="badge {0}">{6}</span><span class="badge neutral">{7}</span><span class="badge neutral">{8}</span></span></summary><div class="finding-body">' -f (ConvertTo-WudHtmlText $severityClass), (ConvertTo-WudHtmlText $categoryClass), (ConvertTo-WudHtmlText $finding.Status.ToLowerInvariant()), $(if ($findingIndex -le 3) { ' open' } else { '' }), (ConvertTo-WudHtmlText $findingAnchor), (ConvertTo-WudHtmlText $finding.Title), (ConvertTo-WudHtmlText $finding.Severity), (ConvertTo-WudHtmlText $finding.Confidence), (ConvertTo-WudHtmlText $finding.Status))
        $recommendationId = "recommendation-$findingIndex"
        Add-WudHtmlLine $builder ('<p><strong>Why it matters:</strong> {0}</p><p><strong>Recommended action:</strong> <span id="{1}">{2}</span> <button class="copy-inline" type="button" data-copy-target="{1}">Copy recommendation</button></p>' -f (ConvertTo-WudHtmlText $finding.Explanation), $recommendationId, (ConvertTo-WudHtmlText $finding.Recommendation))
        if ($finding.AffectedEntity) { Add-WudHtmlLine $builder ('<p><strong>Affected entity:</strong> <code>{0}</code></p>' -f (ConvertTo-WudHtmlText $finding.AffectedEntity)) }
        if ($finding.DispositionReason) { Add-WudHtmlLine $builder ('<p class="muted"><strong>Disposition:</strong> {0}</p>' -f (ConvertTo-WudHtmlText $finding.DispositionReason)) }
        if ($finding.ResultCode -or $finding.ExtendCode -or $finding.Phase) {
            Add-WudHtmlLine $builder ('<p class="muted"><strong>Codes/phase:</strong> {0} {1} &middot; {2} / {3}</p>' -f (ConvertTo-WudHtmlText $finding.ResultCode), (ConvertTo-WudHtmlText $finding.ExtendCode), (ConvertTo-WudHtmlText $finding.Phase), (ConvertTo-WudHtmlText $finding.Operation))
        }
        Add-WudHtmlLine $builder '<div class="evidence-list">'
        $evidenceIndex = 0
        foreach ($evidence in @($finding.Evidence)) {
            $evidenceIndex++
            $copyId = "evidence-$findingIndex-$evidenceIndex"
            $evidenceLabel = if ($evidence.TimestampUtc) { '{0} | {1}' -f $evidence.Reference, $evidence.TimestampUtc } else { [string]$evidence.Reference }
            Add-WudHtmlLine $builder ('<div class="evidence"><button class="copy-inline" type="button" data-copy-target="{0}">Copy excerpt</button><div class="evidence-ref">{1}</div><pre id="{0}">{2}</pre></div>' -f $copyId, (ConvertTo-WudHtmlText $evidenceLabel), (ConvertTo-WudHtmlText $evidence.Excerpt))
        }
        Add-WudHtmlLine $builder '</div>'
        if (@($finding.References).Count -gt 0) {
            Add-WudHtmlLine $builder '<p><strong>Microsoft references:</strong> '
            $links = @($finding.References | ForEach-Object { '<a href="{0}">{1}</a>' -f (ConvertTo-WudHtmlText $_), (ConvertTo-WudHtmlText $_) })
            Add-WudHtmlLine $builder (($links -join ' | ') + '</p>')
        }
        Add-WudHtmlLine $builder '</div></details>'
    }
    if (@($Context.Findings).Count -eq 0) { Add-WudHtmlLine $builder '<p class="muted">No findings were emitted.</p>' }
    Add-WudHtmlLine $builder '</div>'
    Add-WudHtmlLine $builder '<div class="table-wrap"><table id="finding-table"><thead><tr><th data-sort>Severity</th><th data-sort>Category</th><th data-sort>Confidence</th><th data-sort>Status</th><th data-sort>Finding</th><th>Codes / phase</th><th>Evidence</th></tr></thead><tbody>'
    foreach ($finding in $Context.Findings) {
        $findingAnchor = 'finding-' + (([string]$finding.FindingId) -replace '[^A-Za-z0-9_.-]', '-')
        $refs = @($finding.Evidence | ForEach-Object Reference) -join '; '
        Add-WudHtmlLine $builder ('<tr data-severity="{0}" data-category="{1}" data-status="{2}"><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td><a href="#{7}">{8}</a></td><td><code>{9}</code><br>{10} {11}</td><td>{12}</td></tr>' -f (ConvertTo-WudHtmlText $finding.Severity.ToLowerInvariant()), (ConvertTo-WudHtmlText $finding.Category.ToLowerInvariant()), (ConvertTo-WudHtmlText $finding.Status.ToLowerInvariant()), (ConvertTo-WudHtmlText $finding.Severity), (ConvertTo-WudHtmlText $finding.Category), (ConvertTo-WudHtmlText $finding.Confidence), (ConvertTo-WudHtmlText $finding.Status), (ConvertTo-WudHtmlText $findingAnchor), (ConvertTo-WudHtmlText $finding.Title), (ConvertTo-WudHtmlText (@($finding.Codes) -join ' ')), (ConvertTo-WudHtmlText $finding.Phase), (ConvertTo-WudHtmlText $finding.Operation), (ConvertTo-WudHtmlText $refs))
    }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    Add-WudHtmlLine $builder '<section class="panel"><h2>Attempt inventory</h2><div class="table-wrap"><table><thead><tr><th>Attempt</th><th>Phase hint</th><th>Last write (UTC)</th><th>Codes</th><th>Source</th></tr></thead><tbody>'
    foreach ($attempt in $Context.Attempts) {
        Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><code>{3}</code></td><td>{4}</td></tr>' -f (ConvertTo-WudHtmlText $attempt.AttemptId), (ConvertTo-WudHtmlText $attempt.PhaseHint), (ConvertTo-WudHtmlText $attempt.LastWriteUtc), (ConvertTo-WudHtmlText (@($attempt.Codes) -join ', ')), (ConvertTo-WudHtmlText $attempt.Source))
    }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    Add-WudHtmlLine $builder '<section class="panel"><h2>Correlated timeline</h2><p class="section-note">The report displays up to the latest 500 normalized events. Timeline entries are evidence, not automatically causal.</p><div class="table-wrap"><table class="timeline-table"><thead><tr><th data-sort>UTC timestamp</th><th>Attempt</th><th>Phase / operation</th><th>Code</th><th>Severity</th><th>Component</th><th>Event</th><th>Source</th></tr></thead><tbody>'
    foreach ($event in @($Context.Timeline | Select-Object -Last 500)) {
        Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}</td><td>{2}<br>{3}</td><td><code>{4}</code></td><td>{5}</td><td>{6}</td><td>{7}</td><td>{8}</td></tr>' -f (ConvertTo-WudHtmlText $event.TimestampUtc), (ConvertTo-WudHtmlText $event.AttemptId), (ConvertTo-WudHtmlText $event.Phase), (ConvertTo-WudHtmlText $event.Operation), (ConvertTo-WudHtmlText $event.Code), (ConvertTo-WudHtmlText $event.Severity), (ConvertTo-WudHtmlText $event.Component), (ConvertTo-WudHtmlText $event.Event), (ConvertTo-WudHtmlText $event.SourceRef))
    }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    $diff = Get-WudProperty -Object $Context.Inventory -Name 'Diff'
    Add-WudHtmlLine $builder '<section class="panel"><h2>Pre/post comparison</h2>'
    if ($diff -and $diff.Available) {
        $driverAdded = @($diff.Drivers.Added).Count; $driverRemoved = @($diff.Drivers.Removed).Count; $driverChanged = @($diff.Drivers.Changed).Count
        Add-WudHtmlLine $builder ('<div class="summary-grid"><div class="metric"><div class="metric-label">Software inventory</div><div class="metric-value">Not collected</div><div class="metric-detail">Disabled by design</div></div><div class="metric"><div class="metric-label">Drivers</div><div class="metric-value">+{0} / -{1}</div><div class="metric-detail">{2} version changes</div></div><div class="metric"><div class="metric-label">Source build</div><div class="metric-value">{3}</div></div><div class="metric"><div class="metric-label">Current build</div><div class="metric-value">{4}</div></div></div>' -f $driverAdded, $driverRemoved, $driverChanged, (ConvertTo-WudHtmlText $diff.SourceBuild), (ConvertTo-WudHtmlText $diff.CurrentBuild))
        Add-WudHtmlLine $builder '<div class="table-wrap"><table><thead><tr><th>Snapshot family</th><th>Added</th><th>Removed</th><th>Changed</th></tr></thead><tbody>'
        foreach ($groupName in @('Packages', 'Devices', 'Policies', 'Security', 'Disks', 'Networks')) {
            $group = Get-WudProperty $diff $groupName
            Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f $groupName, @($group.Added).Count, @($group.Removed).Count, @($group.Changed).Count)
        }
        Add-WudHtmlLine $builder '</tbody></table></div>'
    }
    else { Add-WudHtmlLine $builder '<p class="muted">No matching preflight/current snapshot pair was available. Inventory.json still contains the current snapshot.</p>' }
    Add-WudHtmlLine $builder '</section>'

    Add-WudHtmlLine $builder '<section class="panel"><h2>Collection coverage</h2><p class="section-note">A failed optional collector can reduce confidence without changing the report to incomplete; required collector failures set exit code 30.</p><div class="table-wrap"><table><thead><tr><th>Snapshot</th><th>Collector</th><th>Version</th><th>Status</th><th>Duration</th><th>Detail</th></tr></thead><tbody>'
    foreach ($record in $CollectorRecords) {
        $statusClass = 'coverage-' + $record.Status.ToLowerInvariant()
        Add-WudHtmlLine $builder ('<tr><td>{0}</td><td><strong>{1}</strong><br><span class="muted">{2}</span></td><td>{3}</td><td class="{4}">{5}</td><td>{6:N1}s</td><td>{7}</td></tr>' -f (ConvertTo-WudHtmlText $record.Snapshot), (ConvertTo-WudHtmlText $record.Id), (ConvertTo-WudHtmlText $record.Description), (ConvertTo-WudHtmlText $record.Version), $statusClass, (ConvertTo-WudHtmlText $record.Status), ([double]$record.DurationMs / 1000), (ConvertTo-WudHtmlText $record.Detail))
    }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    Add-WudHtmlLine $builder '<section class="panel"><h2>Collection gaps</h2><p class="section-note">Missing, locked, skipped, timed-out, capacity-limited, or archive-mismatched evidence is listed explicitly.</p><div class="table-wrap"><table><thead><tr><th>Impact</th><th>Collector</th><th>Status</th><th>Source</th><th>Detail</th></tr></thead><tbody>'
    foreach ($gap in @($Summary.CollectionGaps)) {
        Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td></tr>' -f (ConvertTo-WudHtmlText $gap.Impact), (ConvertTo-WudHtmlText $gap.Collector), (ConvertTo-WudHtmlText $gap.Status), (ConvertTo-WudHtmlText $gap.Source), (ConvertTo-WudHtmlText $gap.Detail))
    }
    if (@($Summary.CollectionGaps).Count -eq 0) { Add-WudHtmlLine $builder '<tr><td colspan="5">No explicit collection gaps were recorded.</td></tr>' }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    [long]$totalBytes = 0
    foreach ($item in @($EvidenceManifest)) { if ($item) { $totalBytes += [long]$item.Length } }
    Add-WudHtmlLine $builder ('<section class="panel"><h2>Evidence index</h2><p class="section-note">{0} files &middot; {1}. Full paths and SHA-256 values are in Manifest.json; raw content is in Evidence.zip.</p><div class="table-wrap"><table><thead><tr><th>Path</th><th>Size</th><th>Modified UTC</th><th>SHA-256</th></tr></thead><tbody>' -f @($EvidenceManifest).Count, (ConvertTo-WudHtmlText (ConvertTo-WudByteSize $totalBytes)))
    foreach ($item in @($EvidenceManifest | Select-Object -First 500)) {
        Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><code>{3}</code></td></tr>' -f (ConvertTo-WudHtmlText $item.RelativePath), (ConvertTo-WudHtmlText (ConvertTo-WudByteSize ([long]$item.Length))), (ConvertTo-WudHtmlText $item.LastWriteUtc), (ConvertTo-WudHtmlText $item.Sha256))
    }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'
    Add-WudHtmlLine $builder ('<div class="footer">Generated by WUPA {0} &middot; Run <code>{1}</code> &middot; No remediation was executed.</div>' -f (ConvertTo-WudHtmlText $Context.ToolVersion), (ConvertTo-WudHtmlText $Context.RunId))
    Add-WudHtmlLine $builder '</main>'
    $json = ($Summary | ConvertTo-Json -Depth 40 -Compress).Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
    Add-WudHtmlLine $builder ('<script nonce="{0}" type="application/json" id="report-data">{1}</script><script nonce="{0}">{2}</script></body></html>' -f $nonce, $json, $javascript)
    return $builder.ToString()
}

function ConvertTo-WudFactDisplay {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return [string]$Value }
    try { return ($Value | ConvertTo-Json -Compress -Depth 12) }
    catch { return [string]$Value }
}

function Build-WudFactReportHtml {
    param($Context, $Summary, $EvidenceManifest, $CollectorRecords)
    $css = Get-Content -LiteralPath (Join-Path $Context.ToolRoot 'Assets/report.css') -Raw -Encoding UTF8
    $javascript = Get-Content -LiteralPath (Join-Path $Context.ToolRoot 'Assets/report.js') -Raw -Encoding UTF8
    $builder = New-Object Text.StringBuilder
    $nonceBytes = New-Object byte[] 18
    $random = New-Object Security.Cryptography.RNGCryptoServiceProvider
    try { $random.GetBytes($nonceBytes) } finally { $random.Dispose() }
    $nonce = [Convert]::ToBase64String($nonceBytes)
    $outcomeClass = Get-WudOutcomeCssClass -Outcome $Summary.Outcome
    $coverageTotal = @($CollectorRecords).Count
    $coverageGood = @($CollectorRecords | Where-Object Status -in @('Succeeded', 'CompletedWithWarnings')).Count
    $coverageText = if (-not $Summary.CollectionComplete) { 'Materially incomplete' } else { '{0}/{1} collectors completed' -f $coverageGood, $coverageTotal }
    $validatedAttempts = @($Context.Attempts | Where-Object { [bool](Get-WudProperty $_ 'IncludedForUpgradeReview' $false) })
    $excludedAttempts = @($Context.Attempts | Where-Object { -not [bool](Get-WudProperty $_ 'IncludedForUpgradeReview' $false) })

    Add-WudHtmlLine $builder '<!doctype html>'
    Add-WudHtmlLine $builder '<html lang="en"><head><meta charset="utf-8">'
    Add-WudHtmlLine $builder '<meta name="viewport" content="width=device-width,initial-scale=1">'
    Add-WudHtmlLine $builder ('<meta http-equiv="Content-Security-Policy" content="default-src &#39;none&#39;; base-uri &#39;none&#39;; object-src &#39;none&#39;; form-action &#39;none&#39;; style-src &#39;nonce-{0}&#39;; script-src &#39;nonce-{0}&#39;; img-src data:; font-src data:">' -f $nonce)
    Add-WudHtmlLine $builder ('<title>WUPA &mdash; {0} &mdash; {1}</title>' -f (ConvertTo-WudHtmlText $Summary.Device.ComputerName), (ConvertTo-WudHtmlText $Summary.Outcome))
    Add-WudHtmlLine $builder ('<style nonce="{0}">{1}</style></head><body>' -f $nonce, $css)
    Add-WudHtmlLine $builder '<div class="sensitive-banner">SENSITIVE DIAGNOSTIC DATA &mdash; Contains device, user, domain, network, path, and native log identifiers.</div>'
    Add-WudHtmlLine $builder '<nav class="topbar" aria-label="Report controls"><div class="brand"><span class="brand-mark">W</span><span>WUPA</span></div><div class="top-actions"><button id="theme-toggle" type="button">Theme</button><button id="print-report" type="button">Print / PDF</button></div></nav><main>'
    Add-WudHtmlLine $builder ('<header class="hero {0}"><div class="eyebrow">Windows Update Performance Analyzer &middot; fact-only evidence</div><h1>{1}</h1><span class="outcome-pill {0}">{2}</span><div class="hero-meta"><span><strong>Device:</strong> {3}</span><span><strong>Run:</strong> <code>{4}</code></span><span><strong>Completed:</strong> {5}</span></div></header>' -f $outcomeClass, (ConvertTo-WudHtmlText $Summary.Outcome), (ConvertTo-WudHtmlText $coverageText), (ConvertTo-WudHtmlText $Summary.Device.ComputerName), (ConvertTo-WudHtmlText $Summary.RunId), (ConvertTo-WudHtmlText $Summary.CompletedUtc))
    Add-WudHtmlLine $builder '<section class="panel scope-notice"><h2>Interpretation boundary</h2><p>This report presents direct observations, source-reported results, deterministic code decodes, and transparent scope computations. It does <strong>not</strong> name a root cause or treat temporal proximity as causation.</p><p><strong>Scope rule:</strong> Update lifecycle events must match the locked target GUID/revision. Setup content must pass ownership, build, window, complete-parse, and contamination gates; setup linked only by build/time remains context. Recorder state changes do not prove why an interval was quiet or delayed.</p></section>'
    Add-WudHtmlLine $builder '<section class="summary-grid" aria-label="Case summary">'
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Current OS</div><div class="metric-value">{0} ({1}.{2})</div><div class="metric-detail">{3}</div></div>' -f (ConvertTo-WudHtmlText $Summary.CurrentOs.DisplayVersion), (ConvertTo-WudHtmlText $Summary.CurrentOs.Build), (ConvertTo-WudHtmlText $Summary.CurrentOs.UBR), (ConvertTo-WudHtmlText $Summary.CurrentOs.Edition))
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Diagnostic target</div><div class="metric-value">{0}</div><div class="metric-detail">Build family {1}</div></div>' -f (ConvertTo-WudHtmlText $Summary.TargetOs.DisplayVersion), (ConvertTo-WudHtmlText $Summary.TargetOs.BuildFamily))
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Attempt scope</div><div class="metric-value">{0} validated</div><div class="metric-detail">{1} setup candidates excluded</div></div>' -f @($validatedAttempts).Count, @($excludedAttempts).Count)
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Direct facts</div><div class="metric-value">{0}</div><div class="metric-detail">{1} included &middot; {2} context &middot; {3} excluded</div></div>' -f $Summary.FactCounts.Total, $Summary.FactCounts.Included, $Summary.FactCounts.ContextOnly, $Summary.FactCounts.Excluded)
    Add-WudHtmlLine $builder '</section>'

    Add-WudHtmlLine $builder '<section class="panel"><h2>Outcome and provenance contract</h2><p class="section-note">These fields are intentionally separate. A target build can be present even when this run did not observe its transition or confirm its deployment source.</p><div class="table-wrap"><table><thead><tr><th>Current OS</th><th>Build transition</th><th>Attempt outcome</th><th>Deployment source</th></tr></thead><tbody>'
    Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f (ConvertTo-WudHtmlText (Get-WudProperty $Summary.StatusModel 'CurrentOsState')), (ConvertTo-WudHtmlText (Get-WudProperty $Summary.StatusModel 'BuildTransition')), (ConvertTo-WudHtmlText (Get-WudProperty $Summary.StatusModel 'AttemptOutcome')), (ConvertTo-WudHtmlText (Get-WudProperty $Summary.StatusModel 'DeploymentSource')))
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    $recorder = Get-WudProperty $Summary 'Recorder'
    Add-WudHtmlLine $builder '<section class="panel"><h2>Windows Update reported results</h2><p>Source-reported success is separate from a live-observed build transition. A result/query timestamp is not an exact installation or reboot completion boundary.</p>'
    $successEvidence = @(Get-WudProperty $Summary.StatusModel 'SuccessEvidence' @())
    if ($successEvidence.Count -eq 0) { Add-WudHtmlLine $builder '<p>No exact-identity success result was retained.</p>' }
    foreach ($result in $successEvidence) { Add-WudHtmlLine $builder ('<p><strong>Reported success:</strong> {0} UTC<br><code>{1}</code><br>{2}</p>' -f (ConvertTo-WudHtmlText $result.TimestampUtc), (ConvertTo-WudHtmlText $result.SourceRef), (ConvertTo-WudHtmlText $result.Meaning)) }
    Add-WudHtmlLine $builder '<h3>Decoded Windows Update log coverage</h3><p>Current and Windows.old streams are decoded separately. Source-local timestamps use the captured device time zone; historical time-zone changes cannot be inferred. Unknown grammars, missing timestamps and ambiguous local times cannot supply phase durations. No records in live event channels does not mean no retained ETL evidence.</p>'
    foreach ($coverage in @(Get-WudProperty $Summary 'WindowsUpdateLogCoverage' @())) { Add-WudHtmlLine $builder ('<p><code>{0}</code>: {1}; {2} exact-identity records; {3} unresolved timestamps; time zone: {4}<br>{5}</p>' -f (ConvertTo-WudHtmlText $coverage.SourceRef), (ConvertTo-WudHtmlText $coverage.Status), $coverage.ExactIdentityRecords, $coverage.UnresolvedTimestamps, (ConvertTo-WudHtmlText $coverage.TimeZoneId), (ConvertTo-WudHtmlText (Get-WudProperty $coverage 'Error'))) }
    Add-WudHtmlLine $builder '</section>'
    $upgradeIdentity = Get-WudProperty $Summary 'UpgradeIdentity'
    $upgradeTiming = Get-WudProperty $Summary 'UpgradeTiming'
    Add-WudHtmlLine $builder '<section class="panel"><h2>Target upgrade identity and phase timing</h2><p class="section-note">Only matching update GUIDs and revisions enter this phase table. Times from source events are exact log timestamps; observation bounds describe uncertainty. Elapsed time includes waits and pauses. A missing historical end boundary does not mean the upgrade is still running. Successful history results are listed separately and are not substituted for exact installation or reboot end times.</p>'
    Add-WudHtmlLine $builder ('<p><strong>Identity status:</strong> {0} &middot; <strong>UpdateID:</strong> <code>{1}</code> &middot; <strong>Revision:</strong> {2}</p><p>{3}</p><div class="table-wrap"><table><thead><tr><th>Operation</th><th>Start UTC / type</th><th>End UTC / type</th><th>Elapsed seconds</th><th>Result</th><th>Evidence</th></tr></thead><tbody>' -f (ConvertTo-WudHtmlText (Get-WudProperty $upgradeIdentity 'Status' 'NotObserved')), (ConvertTo-WudHtmlText (Get-WudProperty $upgradeIdentity 'UpdateID')), (ConvertTo-WudHtmlText (Get-WudProperty $upgradeIdentity 'RevisionNumber')), (ConvertTo-WudHtmlText (Get-WudProperty $upgradeIdentity 'Reason')))
    foreach ($session in @(Get-WudProperty $upgradeTiming 'Sessions' @())) {
        $endDisplay = if ($session.EndUtc) { $session.EndUtc } else { 'Not retained' }
        $elapsedDisplay = if ($null -ne $session.ElapsedSeconds) { $session.ElapsedSeconds } else { 'Not calculable' }
        Add-WudHtmlLine $builder ('<tr><td>{0} / {1}</td><td>{2}<br>{3}</td><td>{4}<br>{5}</td><td>{6}</td><td>{7}</td><td><code>{8}</code><br><code>{9}</code></td></tr>' -f (ConvertTo-WudHtmlText $session.Phase), (ConvertTo-WudHtmlText $session.SessionId), (ConvertTo-WudHtmlText $session.StartUtc), (ConvertTo-WudHtmlText $session.StartKind), (ConvertTo-WudHtmlText $endDisplay), (ConvertTo-WudHtmlText $session.EndKind), (ConvertTo-WudHtmlText $elapsedDisplay), (ConvertTo-WudHtmlText $session.Result), (ConvertTo-WudHtmlText $session.StartEvidenceRef), (ConvertTo-WudHtmlText $session.EndEvidenceRef))
    }
    if (@(Get-WudProperty $upgradeTiming 'Sessions' @()).Count -eq 0) { Add-WudHtmlLine $builder '<tr><td colspan="6">No identity-matched phase boundary was available. Missing timestamps are unknown.</td></tr>' }
    $targetObserved = Get-WudProperty $upgradeTiming 'TargetOsFirstObserved'
    Add-WudHtmlLine $builder ('</tbody></table></div><p><strong>Target OS first observed:</strong> {0} &middot; <strong>transition bounds:</strong> {1} to {2}</p><p>Windows Update install success is an applied-operation result. The target OS observation is the separate post-reboot boundary. Device-wide DO counters below include unrelated transfers unless an explicit UpdateID mapping exists.</p></section>' -f (ConvertTo-WudHtmlText (Get-WudProperty $targetObserved 'FirstObservedUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $targetObserved 'LowerBoundUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $targetObserved 'UpperBoundUtc')))
    $activity = Get-WudProperty $Summary 'UpdateActivity'
    Add-WudHtmlLine $builder '<section class="panel"><h2>Activity by UpdateID</h2><p class="section-note">Each GUID and revision has independent download/install operations and results. Other update failures do not change the 25H2 outcome. Expand an update to inspect its boundaries and evidence.</p>'
    foreach ($update in @(Get-WudProperty $activity 'Updates' @())) {
        Add-WudHtmlLine $builder ('<details class="finding-card"{0}><summary>{1} &mdash; {2}</summary><div class="finding-body"><p><strong>UpdateID:</strong> <code>{3}</code> &middot; <strong>Revision:</strong> {4} &middot; <strong>Service:</strong> <code>{5}</code></p><p>Latest source boundary: {6} &middot; latest history result: {7} (operation {8}) &middot; {9} native events / {10} decoded log records</p><div class="table-wrap"><table><thead><tr><th>Phase</th><th>Start UTC / type</th><th>End UTC / type</th><th>Elapsed seconds</th><th>Result</th><th>Evidence</th></tr></thead><tbody>' -f $(if ($update.Role -eq 'TargetUpgrade') { ' open' } else { '' }), (ConvertTo-WudHtmlText $update.Title), (ConvertTo-WudHtmlText $update.Role), (ConvertTo-WudHtmlText $update.UpdateID), (ConvertTo-WudHtmlText $update.RevisionNumber), (ConvertTo-WudHtmlText $update.ServiceID), (ConvertTo-WudHtmlText $update.LatestBoundary), (ConvertTo-WudHtmlText $update.HistoryResult), (ConvertTo-WudHtmlText $update.HistoryOperation), (Get-WudProperty $update 'NativeEventCount' $update.EventCount), (Get-WudProperty $update 'LogRecordCount' 0))
        foreach ($session in @($update.Timing.Sessions)) {
            $endDisplay = if ($session.EndUtc) { $session.EndUtc } else { 'Not retained' }
            $elapsedDisplay = if ($null -ne $session.ElapsedSeconds) { $session.ElapsedSeconds } else { 'Not calculable' }
            Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}<br>{2}</td><td>{3}<br>{4}</td><td>{5}</td><td>{6}</td><td><code>{7}</code><br><code>{8}</code></td></tr>' -f (ConvertTo-WudHtmlText $session.Phase), (ConvertTo-WudHtmlText $session.StartUtc), (ConvertTo-WudHtmlText $session.StartKind), (ConvertTo-WudHtmlText $endDisplay), (ConvertTo-WudHtmlText $session.EndKind), (ConvertTo-WudHtmlText $elapsedDisplay), (ConvertTo-WudHtmlText $session.Result), (ConvertTo-WudHtmlText $session.StartEvidenceRef), (ConvertTo-WudHtmlText $session.EndEvidenceRef))
        }
        if (@($update.Timing.Sessions).Count -eq 0) { Add-WudHtmlLine $builder '<tr><td colspan="6">No download/install boundaries retained for this update.</td></tr>' }
        Add-WudHtmlLine $builder '</tbody></table></div><ul class="compact-list">'
        foreach ($event in @($update.Events)) {
            Add-WudHtmlLine $builder ('<li>{0}: {1} &mdash; <code>{2}</code></li>' -f (ConvertTo-WudHtmlText $event.TimestampUtc), (ConvertTo-WudHtmlText $event.Boundary), (ConvertTo-WudHtmlText $event.SourceRef))
        }
        foreach ($entry in @($update.History)) {
            Add-WudHtmlLine $builder ('<li>{0}: history operation {1}, result {2}, HRESULT {3} &mdash; <code>{4}</code></li>' -f (ConvertTo-WudHtmlText $entry.DateUtc), (ConvertTo-WudHtmlText $entry.Operation), (ConvertTo-WudHtmlText $entry.ResultCode), (ConvertTo-WudHtmlText $entry.HResultHex), (ConvertTo-WudHtmlText $entry.SourceRef))
        }
        Add-WudHtmlLine $builder '</ul></div></details>'
    }
    if (@(Get-WudProperty $activity 'Updates' @()).Count -eq 0) { Add-WudHtmlLine $builder '<p>No update identities were retained in this observation window.</p>' }
    Add-WudHtmlLine $builder ('<p>Lifecycle events without an UpdateID: {0}. Unidentified events and unmapped DO transfers remain device context, not assigned to an update.</p></section>' -f (ConvertTo-WudHtmlText (Get-WudProperty $activity 'UnattributedEventCount' 0)))
    $delivery = Get-WudProperty $recorder 'DeliveryOptimization'
    Add-WudHtmlLine $builder '<section class="panel"><h2>Persistent progress record</h2><p class="section-note">Samples are taken every 60 seconds by default. Timestamps and byte counters are observations; unobserved intervals remain unclassified.</p><section class="summary-grid">'
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Samples</div><div class="metric-value">{0}</div><div class="metric-detail">{1} to {2}</div></div>' -f (ConvertTo-WudHtmlText (Get-WudProperty $recorder 'SampleCount' 0)), (ConvertTo-WudHtmlText (Get-WudProperty $recorder 'FirstSampleUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $recorder 'LastSampleUtc')))
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Device-wide DO download delta (context)</div><div class="metric-value">{0}</div><div class="metric-detail">Average {1}/s &middot; max reported {2}/s</div></div>' -f (ConvertTo-WudHtmlText (ConvertTo-WudByteSize ([long](Get-WudProperty $delivery 'DownloadedBytesDelta' 0)))), (ConvertTo-WudHtmlText (ConvertTo-WudByteSize ([long](Get-WudProperty $delivery 'AverageObservedBytesPerSecond' 0)))), (ConvertTo-WudHtmlText (ConvertTo-WudByteSize ([long](Get-WudProperty $delivery 'MaximumReportedDownloadRateBps' 0)))))
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">Latest delivery counters</div><div class="metric-value">HTTP {0}</div><div class="metric-detail">Peers {1} &middot; Connected Cache {2} &middot; peer/cache share {3}%</div></div>' -f (ConvertTo-WudHtmlText (ConvertTo-WudByteSize ([long](Get-WudProperty $delivery 'LatestHttpBytes' 0)))), (ConvertTo-WudHtmlText (ConvertTo-WudByteSize ([long](Get-WudProperty $delivery 'LatestPeerBytes' 0)))), (ConvertTo-WudHtmlText (ConvertTo-WudByteSize ([long](Get-WudProperty $delivery 'LatestConnectedCacheBytes' 0)))), (ConvertTo-WudHtmlText (Get-WudProperty $delivery 'PeerAndConnectedCacheSharePercent')))
    Add-WudHtmlLine $builder ('<div class="metric"><div class="metric-label">States observed</div><div class="metric-value">{0}</div><div class="metric-detail">State boundaries create native checkpoints</div></div>' -f (ConvertTo-WudHtmlText (@(Get-WudProperty $recorder 'StatesObserved' @()) -join ', ')))
    Add-WudHtmlLine $builder ('</section><p><strong>Transfer first observed:</strong> {0} &middot; <strong>completion first observed:</strong> {1} &middot; <strong>sampling resolution:</strong> {2}s</p><div class="table-wrap"><table><thead><tr><th>Timestamp UTC</th><th>Previous state</th><th>Observed state</th><th>Boot identity</th></tr></thead><tbody>' -f (ConvertTo-WudHtmlText (Get-WudProperty $delivery 'TransferStartObservedUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $delivery 'TransferCompletionObservedUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $delivery 'SamplingResolutionSeconds')))
    foreach ($transition in @((Get-WudProperty $recorder 'StateTransitions' @()))) {
        Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><code>{3}</code></td></tr>' -f (ConvertTo-WudHtmlText (Get-WudProperty $transition 'TimestampUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $transition 'PreviousState')), (ConvertTo-WudHtmlText (Get-WudProperty $transition 'State')), (ConvertTo-WudHtmlText (Get-WudProperty $transition 'BootId')))
    }
    if (@((Get-WudProperty $recorder 'StateTransitions' @())).Count -eq 0) { Add-WudHtmlLine $builder '<tr><td colspan="4">No recorder state boundary was available.</td></tr>' }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    Add-WudHtmlLine $builder '<section class="panel review-bundle"><h2>External review package</h2><p><code>ReviewBundle.zip</code> is the compact, provider-neutral package intended for drag-and-drop review. Start with <code>READ_ME_FIRST.md</code>, <code>Case.json</code>, and <code>RecorderSummary.json</code>. Full-fidelity raw evidence remains in <code>Evidence.zip</code>.</p>'
    if ($Context.ReviewBundle) {
        Add-WudHtmlLine $builder ('<p><strong>SHA-256:</strong> <code>{0}</code></p>' -f (ConvertTo-WudHtmlText (Get-WudProperty $Context.ReviewBundle 'Sha256')))
    }
    Add-WudHtmlLine $builder '</section>'

    Add-WudHtmlLine $builder '<section class="panel"><h2>Setup evidence scope</h2><div class="table-wrap"><table><thead><tr><th>Included</th><th>Classification</th><th>Window UTC</th><th>Build path</th><th>Gate results</th><th>Evidence</th></tr></thead><tbody>'
    foreach ($attempt in @($Context.Attempts)) {
        $included = [bool](Get-WudProperty $attempt 'IncludedForUpgradeReview' $false)
        $gates = Get-WudProperty $attempt 'Gates'
        $gateText = if ($gates) { @($gates.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, $_.Value }) -join '; ' } else { 'No scope-gate record' }
        $classification = [string](Get-WudProperty $attempt 'Classification' 'Unclassified')
        $reason = [string](Get-WudProperty $attempt 'ExclusionReason')
        Add-WudHtmlLine $builder ('<tr><td><span class="badge {0}">{1}</span></td><td>{2}{3}</td><td>{4}<br>{5}</td><td>{6} &rarr; {7}</td><td>{8}</td><td><code>{9}</code></td></tr>' -f $(if ($included) { 'information' } else { 'neutral' }), $(if ($included) { 'YES' } else { 'NO' }), (ConvertTo-WudHtmlText $classification), $(if ($reason) { '<div class="muted">' + (ConvertTo-WudHtmlText $reason) + '</div>' } else { '' }), (ConvertTo-WudHtmlText (Get-WudProperty $attempt 'StartedUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $attempt 'EndedUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $attempt 'SourceBuild')), (ConvertTo-WudHtmlText (Get-WudProperty $attempt 'TargetBuild')), (ConvertTo-WudHtmlText $gateText), (ConvertTo-WudHtmlText (Get-WudProperty $attempt 'SourcePath')))
    }
    if (@($Context.Attempts).Count -eq 0) { Add-WudHtmlLine $builder '<tr><td colspan="6">No setupact candidate was available.</td></tr>' }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    $factCategories = @($Context.Facts | ForEach-Object Category | Sort-Object -Unique)
    Add-WudHtmlLine $builder '<section class="panel"><h2>Direct fact record</h2><div class="toolbar"><input id="fact-search" type="search" placeholder="Search facts, codes, values, or evidence" aria-label="Search facts"><select id="fact-type-filter" aria-label="Filter by fact type"><option value="">All fact types</option><option value="observed">Observed</option><option value="sourcereported">Source-reported</option><option value="decoded">Decoded</option><option value="computed">Computed</option></select><select id="fact-scope-filter" aria-label="Filter by scope"><option value="">All scopes</option><option value="included">Included</option><option value="contextonly">Context only</option><option value="excluded">Excluded</option></select><select id="fact-category-filter" aria-label="Filter by category"><option value="">All categories</option>'
    foreach ($category in $factCategories) { Add-WudHtmlLine $builder ('<option value="{0}">{1}</option>' -f (ConvertTo-WudHtmlText $category.ToLowerInvariant()), (ConvertTo-WudHtmlText $category)) }
    Add-WudHtmlLine $builder '</select></div><div id="fact-cards">'
    $index = 0
    foreach ($fact in @($Context.Facts)) {
        $index++
        $type = [string](Get-WudProperty $fact 'FactType' 'Observed')
        $scope = [string](Get-WudProperty $fact 'ScopeStatus' 'Included')
        $category = [string](Get-WudProperty $fact 'Category' 'Other')
        $valueText = ConvertTo-WudFactDisplay (Get-WudProperty $fact 'Value')
        Add-WudHtmlLine $builder ('<details class="finding-card fact-card" data-fact-type="{0}" data-fact-scope="{1}" data-fact-category="{2}"{3}><summary>{4}<span class="badges align-right"><span class="badge information">{5}</span><span class="badge neutral">{6}</span></span></summary><div class="finding-body">' -f (ConvertTo-WudHtmlText $type.ToLowerInvariant()), (ConvertTo-WudHtmlText $scope.ToLowerInvariant()), (ConvertTo-WudHtmlText $category.ToLowerInvariant()), $(if ($index -le 5) { ' open' } else { '' }), (ConvertTo-WudHtmlText (Get-WudProperty $fact 'Statement')), (ConvertTo-WudHtmlText $type), (ConvertTo-WudHtmlText $scope))
        if ($valueText) { Add-WudHtmlLine $builder ('<p><strong>Value:</strong></p><pre>{0}</pre>' -f (ConvertTo-WudHtmlText $valueText)) }
        Add-WudHtmlLine $builder ('<p class="evidence-ref"><strong>Evidence:</strong> <code>{0}</code></p>' -f (ConvertTo-WudHtmlText (Get-WudProperty $fact 'EvidenceRef')))
        if (Get-WudProperty $fact 'AttemptId') { Add-WudHtmlLine $builder ('<p><strong>Attempt:</strong> <code>{0}</code></p>' -f (ConvertTo-WudHtmlText (Get-WudProperty $fact 'AttemptId'))) }
        if (Get-WudProperty $fact 'Code') { Add-WudHtmlLine $builder ('<p><strong>Code / phase:</strong> <code>{0}</code> &middot; {1} / {2}</p>' -f (ConvertTo-WudHtmlText (Get-WudProperty $fact 'Code')), (ConvertTo-WudHtmlText (Get-WudProperty $fact 'Phase')), (ConvertTo-WudHtmlText (Get-WudProperty $fact 'Operation'))) }
        if (Get-WudProperty $fact 'Excerpt') { Add-WudHtmlLine $builder ('<pre>{0}</pre>' -f (ConvertTo-WudHtmlText (Get-WudProperty $fact 'Excerpt'))) }
        Add-WudHtmlLine $builder '</div></details>'
    }
    if (@($Context.Facts).Count -eq 0) { Add-WudHtmlLine $builder '<p class="muted">No direct facts were emitted.</p>' }
    Add-WudHtmlLine $builder '</div><div class="table-wrap"><table id="fact-table"><thead><tr><th data-sort>Type</th><th data-sort>Scope</th><th data-sort>Category</th><th data-sort>Timestamp UTC</th><th>Statement</th><th>Code</th><th>Evidence</th></tr></thead><tbody>'
    foreach ($fact in @($Context.Facts)) {
        $type = [string](Get-WudProperty $fact 'FactType' 'Observed'); $scope = [string](Get-WudProperty $fact 'ScopeStatus' 'Included'); $category = [string](Get-WudProperty $fact 'Category' 'Other')
        Add-WudHtmlLine $builder ('<tr class="fact-row" data-fact-type="{0}" data-fact-scope="{1}" data-fact-category="{2}"><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td>{7}</td><td><code>{8}</code></td><td><code>{9}</code></td></tr>' -f (ConvertTo-WudHtmlText $type.ToLowerInvariant()), (ConvertTo-WudHtmlText $scope.ToLowerInvariant()), (ConvertTo-WudHtmlText $category.ToLowerInvariant()), (ConvertTo-WudHtmlText $type), (ConvertTo-WudHtmlText $scope), (ConvertTo-WudHtmlText $category), (ConvertTo-WudHtmlText (Get-WudProperty $fact 'TimestampUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $fact 'Statement')), (ConvertTo-WudHtmlText (Get-WudProperty $fact 'Code')), (ConvertTo-WudHtmlText (Get-WudProperty $fact 'EvidenceRef')))
    }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    Add-WudHtmlLine $builder '<section class="panel"><h2>Observed upgrade timeline</h2><p class="section-note">Included lifecycle rows match the target identity. ContextOnly rows retain setup or recorder observations without asserting a direct upgrade link.</p><div class="table-wrap"><table><thead><tr><th>Timestamp UTC</th><th>Attempt</th><th>Type / scope / timing</th><th>Code / phase</th><th>Message</th><th>Evidence</th></tr></thead><tbody>'
    foreach ($event in @($Context.Timeline)) {
        Add-WudHtmlLine $builder ('<tr><td>{0}</td><td><code>{1}</code></td><td>{2}<br>{8}<br>{9}</td><td><code>{3}</code><br>{4} / {5}</td><td>{6}</td><td><code>{7}</code></td></tr>' -f (ConvertTo-WudHtmlText (Get-WudProperty $event 'TimestampUtc')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'AttemptId')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'EventType')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'Code')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'Phase')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'Operation')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'Message')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'EvidenceReference')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'ScopeStatus')), (ConvertTo-WudHtmlText (Get-WudProperty $event 'TimingKind')))
    }
    if (@($Context.Timeline).Count -eq 0) { Add-WudHtmlLine $builder '<tr><td colspan="6">No timeline rows were emitted.</td></tr>' }
    Add-WudHtmlLine $builder '</tbody></table></div></section>'

    Add-WudHtmlLine $builder '<section class="panel"><h2>Collection coverage</h2><div class="table-wrap"><table><thead><tr><th>Collector</th><th>Status</th><th>Required</th><th>Duration</th><th>Detail</th></tr></thead><tbody>'
    foreach ($record in @($CollectorRecords)) {
        Add-WudHtmlLine $builder ('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3} ms</td><td>{4}</td></tr>' -f (ConvertTo-WudHtmlText (Get-WudProperty $record 'Id')), (ConvertTo-WudHtmlText (Get-WudProperty $record 'Status')), (ConvertTo-WudHtmlText (Get-WudProperty $record 'Required')), (ConvertTo-WudHtmlText (Get-WudProperty $record 'DurationMs')), (ConvertTo-WudHtmlText (Get-WudProperty $record 'Detail')))
    }
    Add-WudHtmlLine $builder '</tbody></table></div><h3>Recorded gaps</h3><ul class="compact-list">'
    foreach ($gap in @($Context.CollectionGaps)) { Add-WudHtmlLine $builder ('<li><strong>{0}</strong> &mdash; {1}: {2}</li>' -f (ConvertTo-WudHtmlText (Get-WudProperty $gap 'Status')), (ConvertTo-WudHtmlText (Get-WudProperty $gap 'Source')), (ConvertTo-WudHtmlText (Get-WudProperty $gap 'Detail'))) }
    if (@($Context.CollectionGaps).Count -eq 0) { Add-WudHtmlLine $builder '<li>No collection gaps were recorded.</li>' }
    Add-WudHtmlLine $builder '</ul></section>'

    Add-WudHtmlLine $builder ('<section class="panel"><h2>Evidence integrity</h2><p><strong>{0}</strong> staged evidence files were indexed and archived in <code>Evidence.zip</code>. File-level paths, timestamps, sizes, and SHA-256 hashes are available in <code>Manifest.json</code> and <code>ReviewBundle.zip/EvidenceIndex.jsonl</code>.</p></section>' -f @($EvidenceManifest).Count)
    Add-WudHtmlLine $builder '<footer><p>WUPA is an independent, diagnostic-only utility. It does not start an upgrade, apply a repair, bypass a safeguard, or upload evidence.</p></footer></main>'
    $json = ($Summary | ConvertTo-Json -Depth 50 -Compress).Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
    Add-WudHtmlLine $builder ('<script nonce="{0}" type="application/json" id="report-data">{1}</script><script nonce="{0}">{2}</script></body></html>' -f $nonce, $json, $javascript)
    return $builder.ToString()
}

function Copy-WudOutputToShare {
    param($Context)
    if ([string]::IsNullOrWhiteSpace($Context.CopyTo)) { return [pscustomobject]@{ Requested = $false; Deferred = $false; Succeeded = $true; Destination = $null; Error = $null } }
    if (-not (Test-WudInteractiveUser)) {
        Write-WudLog -Context $Context -Level WARN -Message 'UNC copy was deferred because this phase is running without an interactive technician token.'
        return [pscustomobject]@{ Requested = $true; Deferred = $true; Succeeded = $false; Destination = $null; Error = 'No interactive technician token.' }
    }
    $destination = $null
    try {
        $destination = Join-Path $Context.CopyTo (Split-Path -Leaf $Context.OutputPath)
        $null = New-WudDirectory -Path $destination
        $arguments = @($Context.OutputPath, $destination, '/E', '/COPY:DAT', '/DCOPY:T', '/R:2', '/W:2', '/XJ', '/NP')
        $argumentLine = (@($arguments | ForEach-Object { ConvertTo-WudCommandLineArgument -Value ([string]$_) }) -join ' ')
        $process = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argumentLine -PassThru
        $timeoutSeconds = [int]$Context.Settings.timeoutsSeconds.copyToShare
        $deadline = [DateTime]::UtcNow.AddSeconds($timeoutSeconds)
        while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $process.Refresh()
        }
        if (-not $process.HasExited) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
            throw "robocopy exceeded its $timeoutSeconds second share-copy limit. A partial destination may remain and is safe to retry."
        }
        try { $process.WaitForExit() } catch { }
        if ($process.ExitCode -gt 7) { throw "robocopy returned $($process.ExitCode)." }
        Write-WudLog -Context $Context -Level INFO -Message "Copied finalized artifacts to $destination."
        return [pscustomobject]@{ Requested = $true; Deferred = $false; Succeeded = $true; Destination = $destination; Error = $null }
    }
    catch {
        Write-WudLog -Context $Context -Level WARN -Message ("Could not copy finalized artifacts to the UNC destination: {0}" -f $_.Exception.Message)
        return [pscustomobject]@{ Requested = $true; Deferred = $false; Succeeded = $false; Destination = $destination; Error = $_.Exception.Message }
    }
}

function Copy-WudToolStateForArchive {
    param($Context)
    $stateRoot = Join-Path $Context.RunPath 'State'
    if (-not (Test-Path -LiteralPath $stateRoot)) { return }
    $destinationRoot = New-WudDirectory -Path (Join-Path $Context.SnapshotPath 'ToolState')
    foreach ($file in @(Get-ChildItem -LiteralPath $stateRoot -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object Name -ne 'run.lock')) {
        try {
            $relative = Get-WudRelativePath -BasePath $stateRoot -Path $file.FullName
            $destination = Join-Path $destinationRoot $relative
            $null = New-WudDirectory -Path (Split-Path -Parent $destination)
            Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction Stop
        }
        catch {
            $null = Add-WudCollectionGap -Context $Context -Collector 'report-state' -Source $file.FullName -Status 'CopyFailed' -Detail $_.Exception.Message
        }
    }
}

function Export-WudReportArtifacts {
    param([Parameter(Mandatory = $true)]$Context)
    Write-WudLog -Context $Context -Level INFO -Message "Finalizing report artifacts in $($Context.OutputPath)."
    $null = New-WudDirectory -Path $Context.OutputPath
    $pendingPath = Join-Path $Context.OutputPath 'Report.pending'
    Write-WudText -Path $pendingPath -Text ([DateTime]::UtcNow.ToString('o'))
    Copy-WudToolStateForArchive -Context $Context
    $recorderRoot = Join-Path $Context.RunPath 'Evidence\Recorder'
    $recorderSummary = if ($Context.Recorder) { $Context.Recorder } else { [pscustomobject][ordered]@{ SampleCount = 0; FirstSampleUtc = $null; LastSampleUtc = $null; StatesObserved = @(); StateTransitions = @(); DeliveryOptimization = $null } }
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'RecorderSummary.json') -InputObject $recorderSummary -Depth 30
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'UpgradeIdentity.json') -InputObject (Get-WudProperty $Context.UpgradeTracking 'Identity') -Depth 20
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'UpgradeTiming.json') -InputObject $Context.UpgradeTiming -Depth 25
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'UpdateActivity.json') -InputObject $Context.UpdateActivity -Depth 30
    $allUpdateHeaders = @('TimestampUtc', 'ActivityKey', 'UpdateID', 'RevisionNumber', 'ServiceID', 'Role', 'Boundary', 'EventId', 'Title', 'EvidenceReference', 'TimingKind')
    $allUpdateRows = @(Get-WudProperty $Context.UpdateActivity 'Timeline' @() | ForEach-Object {
        $event = $_; $row = [ordered]@{}
        foreach ($header in $allUpdateHeaders) { $row[$header] = ConvertTo-WudCsvCell (Get-WudProperty $event $header) }
        [pscustomobject]$row
    })
    Export-WudCsvContract -Rows $allUpdateRows -Headers $allUpdateHeaders -Path (Join-Path $Context.OutputPath 'AllUpdatesTimeline.csv')
    foreach ($name in @('ProgressSamples.jsonl', 'StateTransitions.jsonl')) {
        $source = Join-Path $recorderRoot $name
        if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination (Join-Path $Context.OutputPath $name) -Force }
        else { Write-WudText -Path (Join-Path $Context.OutputPath $name) -Text '' }
    }
    $checkpointManifests = @(Get-ChildItem -LiteralPath (Join-Path $recorderRoot 'Checkpoints') -File -Recurse -Filter 'checkpoint-manifest.json' -ErrorAction SilentlyContinue | ForEach-Object { Read-WudJson -Path $_.FullName })
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'Checkpoints.json') -InputObject @($checkpointManifests) -Depth 30
    foreach ($journalFile in @(Get-ChildItem -LiteralPath (Join-Path $Context.RunPath 'State/Updates') -Filter 'journal.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        try {
            $journal = Read-WudJson $journalFile.FullName
            $paused = Get-WudProperty $journal 'PauseStartedUtc'
            if ($paused) {
                $end = Get-WudProperty $journal 'ResumeVerifiedUtc' (Get-WudProperty $journal 'RecoveredUtc')
                $null = Add-WudCollectionGap -Context $Context -Collector 'recorder-runtime-update' -Source $journalFile.FullName -Status 'SamplingInterrupted' -Detail ("Recorder runtime update paused observation from {0} until {1}; this is a collection gap, not Windows installation duration." -f $paused, $(if ($end) { $end } else { 'an unverified restart' }))
            }
            if ((Get-WudProperty $journal 'Status') -eq 'Pending') { $null = Add-WudCollectionGap -Context $Context -Collector 'recorder-runtime-update' -Source $journalFile.FullName -Status 'RuntimeUpdatePendingRecovery' -Detail 'An interrupted runtime update has not been recovered.' -Impact 'Material' }
        }
        catch { $null = Add-WudCollectionGap -Context $Context -Collector 'recorder-runtime-update' -Source $journalFile.FullName -Status 'MetadataUnreadable' -Detail $_.Exception.Message -Impact 'Material' }
    }
    # Metadata parsing must precede the summary so its coverage gaps are
    # included, rather than being discovered after Report.html is written.
    $sourceMappings = Get-WudEvidenceSourceMappings -Context $Context
    $collectorRecords = @(Get-WudAllCollectorRecords -Context $Context)
    $evidenceManifest = @(Get-WudFileInventory -RootPath $Context.EvidencePath -Context $Context)
    foreach ($unhashed in @($evidenceManifest | Where-Object {
        (-not $_.Sha256) -and (-not $_.PSObject.Properties['ArchiveEligible'] -or [bool]$_.ArchiveEligible)
    })) {
        $null = Add-WudCollectionGap -Context $Context -Collector 'report-manifest' -Source $unhashed.StagedPath -Status 'HashUnavailable' -Detail 'The staged evidence file was indexed, but SHA-256 calculation did not complete.'
    }
    $evidenceZip = Join-Path $Context.OutputPath 'Evidence.zip'
    New-WudEvidenceArchive -SourcePath $Context.EvidencePath -DestinationPath $evidenceZip -Context $Context
    $archiveVerification = Test-WudEvidenceArchiveIntegrity -ArchivePath $evidenceZip -EvidenceManifest $evidenceManifest
    if (-not $archiveVerification.Verified) {
        $Context.CollectionComplete = $false
        $Context.ExitCode = Resolve-WudExitCode -Context $Context
        $null = Add-WudCollectionGap -Context $Context -Collector 'report-archive' -Source $evidenceZip -Status 'IntegrityMismatch' -Detail ((@($archiveVerification.Missing) + @($archiveVerification.HashMismatches)) -join '; ') -Impact 'Material'
    }
    # Build the reviewer package only after metadata, state journals and archive
    # validation have contributed their coverage gaps. A reviewer must see the
    # same completeness limits as the HTML/JSON report.
    if ($Context.ReviewData) { $null = Export-WudReviewBundle -Context $Context }
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'Inventory.json') -InputObject $Context.Inventory -Depth 40
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'Attempts.json') -InputObject @($Context.Attempts) -Depth 40
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'ExcludedEvidence.json') -InputObject @($Context.ExcludedEvidence) -Depth 30
    $factRows = foreach ($fact in $Context.Facts) {
        [pscustomobject][ordered]@{
            FactId        = Get-WudProperty $fact 'FactId'
            FactType      = Get-WudProperty $fact 'FactType'
            Category      = Get-WudProperty $fact 'Category'
            ScopeStatus   = Get-WudProperty $fact 'ScopeStatus'
            TimestampUtc  = Get-WudProperty $fact 'TimestampUtc'
            AttemptId     = Get-WudProperty $fact 'AttemptId'
            Statement     = ConvertTo-WudCsvCell (Get-WudProperty $fact 'Statement')
            Value         = ConvertTo-WudCsvCell (ConvertTo-WudFactDisplay (Get-WudProperty $fact 'Value'))
            Code          = Get-WudProperty $fact 'Code'
            Phase         = Get-WudProperty $fact 'Phase'
            Operation     = Get-WudProperty $fact 'Operation'
            EvidenceRef   = ConvertTo-WudCsvCell (Get-WudProperty $fact 'EvidenceRef')
            ExcerptFile   = Get-WudProperty $fact 'ExcerptFile'
        }
    }
    Export-WudCsvContract -Rows @($factRows) -Headers @('FactId', 'FactType', 'Category', 'ScopeStatus', 'TimestampUtc', 'AttemptId', 'Statement', 'Value', 'Code', 'Phase', 'Operation', 'EvidenceRef', 'ExcerptFile') -Path (Join-Path $Context.OutputPath 'Facts.csv')
    $findingRows = foreach ($finding in $Context.Findings) {
        [pscustomobject][ordered]@{
            FindingId      = $finding.FindingId
            RuleId         = $finding.RuleId
            Severity       = $finding.Severity
            Category       = $finding.Category
            Confidence     = $finding.Confidence
            Status         = $finding.Status
            DispositionReason = ConvertTo-WudCsvCell $finding.DispositionReason
            Title          = ConvertTo-WudCsvCell $finding.Title
            ResultCode     = $finding.ResultCode
            ExtendCode     = $finding.ExtendCode
            Codes          = ConvertTo-WudCsvCell (@($finding.Codes) -join '; ')
            Phase          = $finding.Phase
            Operation      = $finding.Operation
            AffectedEntity = ConvertTo-WudCsvCell $finding.AffectedEntity
            Evidence       = ConvertTo-WudCsvCell (@($finding.Evidence | ForEach-Object Reference) -join '; ')
            Recommendation = ConvertTo-WudCsvCell $finding.Recommendation
            References     = ConvertTo-WudCsvCell (@($finding.References) -join '; ')
        }
    }
    $findingHeaders = @('FindingId', 'RuleId', 'Severity', 'Category', 'Confidence', 'Status', 'DispositionReason', 'Title', 'ResultCode', 'ExtendCode', 'Codes', 'Phase', 'Operation', 'AffectedEntity', 'Evidence', 'Recommendation', 'References')
    Export-WudCsvContract -Rows @($findingRows) -Headers $findingHeaders -Path (Join-Path $Context.OutputPath 'Findings.csv')
    $timelineHeaders = if ($Context.ReviewData -and (Get-WudProperty $Context.ReviewData 'AnalysisMode') -eq 'FactOnly') {
        @('TimestampUtc', 'AttemptId', 'FactId', 'EventType', 'Code', 'Phase', 'Operation', 'Message', 'EvidenceReference', 'UpdateID', 'RevisionNumber', 'ScopeStatus', 'TimingKind')
    }
    else { @('TimestampUtc', 'LocalOffset', 'TimestampAmbiguous', 'AttemptId', 'Phase', 'Operation', 'Code', 'Component', 'Event', 'Message', 'Severity', 'SourceRef', 'EvidenceReference', 'Entity', 'CorrelationId') }
    $timelineRows = @($Context.Timeline | ForEach-Object {
        $sourceEvent = $_
        $row = [ordered]@{}
        foreach ($header in $timelineHeaders) { $row[$header] = ConvertTo-WudCsvCell (Get-WudProperty -Object $sourceEvent -Name $header) }
        [pscustomobject]$row
    })
    Export-WudCsvContract -Rows $timelineRows -Headers $timelineHeaders -Path (Join-Path $Context.OutputPath 'Timeline.csv')
    if (Test-Path -LiteralPath $Context.LogPath) { Copy-Item -LiteralPath $Context.LogPath -Destination (Join-Path $Context.OutputPath 'Collector.log') -Force }
    $preSummaryArtifacts = @('Evidence.zip', 'ReviewBundle.zip', 'Inventory.json', 'Attempts.json', 'ExcludedEvidence.json', 'Facts.csv', 'Findings.csv', 'Timeline.csv', 'RecorderSummary.json', 'ProgressSamples.jsonl', 'StateTransitions.jsonl', 'Checkpoints.json', 'UpgradeIdentity.json', 'UpgradeTiming.json', 'UpdateActivity.json', 'AllUpdatesTimeline.csv', 'Collector.log') | ForEach-Object { Get-WudArtifactRecord -Path (Join-Path $Context.OutputPath $_) -BasePath $Context.OutputPath } | Where-Object { $_ }
    $Context.ExitCode = Resolve-WudExitCode -Context $Context
    $summary = New-WudSummaryObject -Context $Context -CollectorRecords $collectorRecords -ArtifactRecords $preSummaryArtifacts
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'Summary.json') -InputObject $summary -Depth 40
    $html = if ($summary.AnalysisMode -eq 'FactOnly') { Build-WudFactReportHtml -Context $Context -Summary $summary -EvidenceManifest $evidenceManifest -CollectorRecords $collectorRecords } else { Build-WudReportHtml -Context $Context -Summary $summary -EvidenceManifest $evidenceManifest -CollectorRecords $collectorRecords }
    Write-WudText -Path (Join-Path $Context.OutputPath 'Report.html') -Text $html
    $artifactFiles = @('Report.html', 'Summary.json', 'Facts.csv', 'Findings.csv', 'Timeline.csv', 'Attempts.json', 'ExcludedEvidence.json', 'Inventory.json', 'RecorderSummary.json', 'ProgressSamples.jsonl', 'StateTransitions.jsonl', 'Checkpoints.json', 'UpgradeIdentity.json', 'UpgradeTiming.json', 'UpdateActivity.json', 'AllUpdatesTimeline.csv', 'ReviewBundle.zip', 'Evidence.zip', 'Collector.log')
    $artifactManifest = @($artifactFiles | ForEach-Object { Get-WudArtifactRecord -Path (Join-Path $Context.OutputPath $_) -BasePath $Context.OutputPath } | Where-Object { $_ })
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion = 2
        ToolVersion   = $Context.ToolVersion
        RunId         = $Context.RunId
        Sensitive     = $true
        CreatedUtc    = [DateTime]::UtcNow.ToString('o')
        Artifacts     = $artifactManifest
        Evidence     = $evidenceManifest
        SourceMappings = $sourceMappings
        CollectionGaps = @($Context.CollectionGaps)
        ArchiveVerification = $archiveVerification
    }
    Write-WudJsonAtomic -Path (Join-Path $Context.OutputPath 'Manifest.json') -InputObject $manifest -Depth 20
    $checksumLines = New-Object Collections.ArrayList
    foreach ($file in Get-ChildItem -LiteralPath $Context.OutputPath -File | Where-Object { $_.Name -notin @('Checksums.sha256', 'Report.pending') } | Sort-Object Name) {
        $hash = Get-WudFileHashSafe -Path $file.FullName
        if ($hash) { $null = $checksumLines.Add("$hash  $($file.Name)") }
    }
    Write-WudText -Path (Join-Path $Context.OutputPath 'Checksums.sha256') -Text ((@($checksumLines) -join [Environment]::NewLine) + [Environment]::NewLine)
    Remove-Item -LiteralPath $pendingPath -Force -ErrorAction Stop
    $Context.LastCopyResult = Copy-WudOutputToShare -Context $Context
    return (Join-Path $Context.OutputPath 'Report.html')
}

Export-ModuleMember -Function @('Export-WudReportArtifacts', 'New-WudEvidenceArchive', 'Build-WudReportHtml', 'ConvertTo-WudHtmlText', 'Copy-WudOutputToShare')
