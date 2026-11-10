[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$SourceDir,

    [switch]$DryRun,

    [switch]$Interactive,

    [Alias('Recursive')]
    [switch]$Recurse,

    [string[]]$Extensions = @(
        '*.jpg', '*.jpeg', '*.png', '*.gif', '*.bmp', '*.tif', '*.tiff', '*.heic',
        '*.mp4', '*.mov', '*.avi', '*.mkv', '*.wmv', '*.webm', '*.m4v',
        '*.mp3', '*.wav', '*.aac', '*.flac', '*.ogg'
    )
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$script:LogFilePath = $null

function Normalize-MediaExtension {
    param(
        [string]$Extension
    )

    if ([string]::IsNullOrWhiteSpace($Extension)) {
        return ''
    }

    $normalized = $Extension.Trim().TrimStart('.').ToLowerInvariant()
    if ($normalized -eq 'jpeg') {
        return 'jpg'
    }

    return $normalized
}

function Get-AllowedExtensions {
    param(
        [string[]]$Inputs
    )

    $normalized = @()
    foreach ($input in $Inputs) {
        if ([string]::IsNullOrWhiteSpace($input)) {
            continue
        }

        $trimmed = $input.Trim()
        if ($trimmed.StartsWith('*')) {
            $trimmed = $trimmed.Substring(1)
        }

        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $normalized += Normalize-MediaExtension -Extension $trimmed
    }

    return $normalized | Sort-Object -Unique
}

function Resolve-CanonicalDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$MustExist
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Name is required and must be a valid directory path."
    }

    $trimmed = $Path.Trim()
    $fullPath = if ([System.IO.Path]::IsPathRooted($trimmed)) {
        [System.IO.Path]::GetFullPath($trimmed)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $trimmed))
    }

    if ($MustExist) {
        if (-not (Test-Path -LiteralPath $fullPath)) {
            throw "$Name '$Path' was not found. Provide an existing directory path."
        }

        if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
            throw "$Name '$Path' exists but is not a directory. Provide a directory path."
        }
    }

    return $fullPath
}

function Try-ParseDateTimeValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    $asString = [string]$Value
    if ([string]::IsNullOrWhiteSpace($asString)) {
        return $null
    }

    $trimmed = $asString.Trim().Trim([char]0)
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    $exifToolDateMatch = [regex]::Match($trimmed, '^(?<Date>\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?$')
    if ($exifToolDateMatch.Success) {
        $trimmed = $exifToolDateMatch.Groups['Date'].Value
    }

    $formats = @(
        'yyyy:MM:dd HH:mm:ss',
        'yyyy-MM-dd HH:mm:ss',
        'yyyy/MM/dd HH:mm:ss',
        'yyyy.MM.dd HH:mm:ss',
        'yyyy-MM-ddTHH:mm:ss',
        'yyyy-MM-ddTHH:mm:ss.fff',
        'yyyyMMddHHmmss',
        'yyyy-MM-dd_HH-mm-ss',
        'yyyy_MM_dd_HH_mm_ss'
    )

    foreach ($format in $formats) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($trimmed, $format, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$parsed)) {
            return $parsed
        }
    }

    return $null
}

function Get-EmbeddedFilenameTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $baseName = $File.BaseName
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        return $null
    }

    $match = [regex]::Match($baseName, '(?i)(20\d{2})(?:[^\d]?)(\d{2})(?:[^\d]?)(\d{2})(?:[^\d]?)(\d{2})(?:[^\d]?)(\d{2})(?:[^\d]?)(\d{2})')
    if (-not $match.Success) {
        return $null
    }

    $digits = [regex]::Replace($match.Value, '[^\d]', '')
    if ($digits.Length -ne 14) {
        return $null
    }

    try {
        $year = [int]::Parse($digits.Substring(0, 4))
        $month = [int]::Parse($digits.Substring(4, 2))
        $day = [int]::Parse($digits.Substring(6, 2))
        $hour = [int]::Parse($digits.Substring(8, 2))
        $minute = [int]::Parse($digits.Substring(10, 2))
        $second = [int]::Parse($digits.Substring(12, 2))
        return [datetime]::new($year, $month, $day, $hour, $minute, $second)
    }
    catch {
        return $null
    }
}

function Get-ExifToolTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $exifToolCommand = Get-Command -Name 'exiftool' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $exifToolCommand) {
        return $null
    }

    try {
        $jsonOutput = @(& $exifToolCommand.Source -json -DateTimeOriginal -DateTimeDigitized -MediaCreateDate -TrackCreateDate -CreateDate -MediaModifyDate -TrackModifyDate -ModifyDate $File.FullName 2>$null)
        if ($jsonOutput.Count -eq 0) {
            return $null
        }

        $metadata = ConvertFrom-Json -InputObject ($jsonOutput -join [System.Environment]::NewLine) -ErrorAction Stop
        while ($metadata -is [array]) {
            if ($metadata.Count -eq 0) {
                return $null
            }
            $metadata = $metadata[0]
        }

        if ($null -eq $metadata) {
            return $null
        }

        $tagSources = @(
            @{ Tag = 'DateTimeOriginal'; Source = 'EXIF Photo taken' },
            @{ Tag = 'DateTimeDigitized'; Source = 'EXIF Photo digitized' },
            @{ Tag = 'MediaCreateDate'; Source = 'EXIF Media create date' },
            @{ Tag = 'TrackCreateDate'; Source = 'EXIF Track create date' },
            @{ Tag = 'CreateDate'; Source = 'EXIF Create date' },
            @{ Tag = 'MediaModifyDate'; Source = 'EXIF Media update date' },
            @{ Tag = 'TrackModifyDate'; Source = 'EXIF Track media date' },
            @{ Tag = 'ModifyDate'; Source = 'EXIF Update date' }
        )

        foreach ($tagSource in $tagSources) {
            $tagName = $tagSource.Tag
            $property = $metadata.PSObject.Properties[$tagName]
            if ($null -eq $property) {
                continue
            }

            $parsed = Try-ParseDateTimeValue -Value $property.Value
            if ($null -ne $parsed) {
                return [pscustomobject]@{
                    Value = $parsed
                    Source = $tagSource.Source
                }
            }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Get-ExifTimestamp {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $extension = Normalize-MediaExtension -Extension $File.Extension
    if ([string]::IsNullOrWhiteSpace($extension)) {
        return $null
    }

    $exifToolTimestamp = Get-ExifToolTimestamp -File $File
    if ($null -ne $exifToolTimestamp) {
        return $exifToolTimestamp
    }

    if ($extension -notin @('jpg', 'jpeg', 'tif', 'tiff', 'png', 'bmp')) {
        return $null
    }

    try {
        $image = [System.Drawing.Image]::FromFile($File.FullName)
    }
    catch {
        return $null
    }

    try {
        $tagIds = @(36867, 36868, 306)
        foreach ($tagId in $tagIds) {
            $propertyItem = @($image.PropertyItems | Where-Object { $_.Id -eq $tagId }) | Select-Object -First 1
            if ($null -eq $propertyItem) {
                continue
            }

            $rawValue = [System.Text.Encoding]::ASCII.GetString($propertyItem.Value)
            $parsed = Try-ParseDateTimeValue -Value $rawValue
            if ($null -ne $parsed) {
                return [pscustomobject]@{
                    Value = $parsed
                    Source = 'EXIF Photo taken'
                }
            }
        }
    }
    catch {
        return $null
    }
    finally {
        $image.Dispose()
    }

    return $null
}

function Get-EffectiveTimestampValue {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File
    )

    $embeddedFilename = Get-EmbeddedFilenameTimestamp -File $File
    if ($null -ne $embeddedFilename) {
        return [pscustomobject]@{
            Value = $embeddedFilename
            Source = 'filename'
        }
    }

    $exifTimestamp = Get-ExifTimestamp -File $File
    if ($null -ne $exifTimestamp) {
        return $exifTimestamp
    }

    $fallbackOrder = @(
        @{ Label = 'file property Created date'; Value = $File.CreationTime },
        @{ Label = 'file property Modified date'; Value = $File.LastWriteTime }
    )

    foreach ($fallbackEntry in $fallbackOrder) {
        if ($null -ne $fallbackEntry.Value) {
            return [pscustomobject]@{
                Value = $fallbackEntry.Value
                Source = $fallbackEntry.Label
            }
        }
    }

    return $null
}

function Get-LogFilePath {
    $scriptName = [System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
    if ([string]::IsNullOrWhiteSpace($scriptName)) {
        $scriptName = 'Rename-MediaFiles'
    }

    $timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    return Join-Path -Path (Get-Location).Path -ChildPath ('{0}-{1}.log' -f $scriptName, $timestamp)
}

function Write-LogMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($DryRun) {
        Write-Output $Message
        return
    }

    if (-not $script:LogFilePath) {
        $script:LogFilePath = Get-LogFilePath
        $null = New-Item -ItemType File -Path $script:LogFilePath -Force -ErrorAction Stop
    }

    Add-Content -LiteralPath $script:LogFilePath -Value $Message -Encoding UTF8
}

function Confirm-InteractiveFolder {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,

        [Parameter(Mandatory = $true)]
        [int]$PlannedCount
    )

    if ($DryRun -or -not $Interactive) {
        return $true
    }

    $autoConfirmValue = $env:MEDIA_RENAMER_AUTO_CONFIRM
    if (-not [string]::IsNullOrWhiteSpace($autoConfirmValue)) {
        $normalized = $autoConfirmValue.Trim()
        if ($normalized -match '^(y|yes|1|true)$') {
            return $true
        }

        if ($normalized -match '^(n|no|0|false)$') {
            return $false
        }
    }

    $response = Read-Host ("Proceed with renaming {0} file(s) in '{1}'? [Y/N]" -f $PlannedCount, $FolderPath)
    return ($response -match '^(y|yes)$')
}

function Get-RenamePlanForFolder {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$Folder,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedExtensions
    )

    $plan = @()
    $folderFiles = @(Get-ChildItem -LiteralPath $Folder.FullName -File | Where-Object {
        $fileExtension = Normalize-MediaExtension -Extension $_.Extension
        $AllowedExtensions -contains $fileExtension
    } | Sort-Object FullName)

    $usedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($file in $folderFiles) {
        $timestampInfo = Get-EffectiveTimestampValue -File $file
        if ($null -eq $timestampInfo) {
            continue
        }

        $timestampValue = $timestampInfo.Value
        $timestampSourceLabel = $timestampInfo.Source
        $normalizedExtension = Normalize-MediaExtension -Extension $file.Extension
        $candidateTimestamp = [datetime]$timestampValue
        $baseName = $candidateTimestamp.ToString('yyyyMMdd-HHmmss')
        $newName = if ([string]::IsNullOrEmpty($normalizedExtension)) { $baseName } else { '{0}.{1}' -f $baseName, $normalizedExtension }
        $conflictMessages = @()

        $candidatePath = Join-Path -Path $file.DirectoryName -ChildPath $newName
        while ($usedNames.Contains($newName) -or ((Test-Path -LiteralPath $candidatePath) -and -not ([System.StringComparer]::OrdinalIgnoreCase.Equals($candidatePath, $file.FullName)))) {
            $conflictingName = $newName
            $candidateTimestamp = $candidateTimestamp.AddSeconds(1)
            $baseName = $candidateTimestamp.ToString('yyyyMMdd-HHmmss')
            $newName = if ([string]::IsNullOrEmpty($normalizedExtension)) { $baseName } else { '{0}.{1}' -f $baseName, $normalizedExtension }
            $candidatePath = Join-Path -Path $file.DirectoryName -ChildPath $newName
            $conflictMessages += ("[CONFLICT] '{0}' already exists; incrementing timestamp to '{1}'" -f $conflictingName, $newName)
        }

        $usedNames.Add($newName) | Out-Null
        $plan += [pscustomobject]@{
            File = $file
            NewName = $newName
            Source = $timestampSourceLabel
            ConflictMessages = $conflictMessages
        }
    }

    return $plan
}

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    throw "SourceDir is required and must be a valid directory path."
}

$resolvedSource = Resolve-CanonicalDirectory -Path $SourceDir -Name 'SourceDir' -MustExist

if (-not $DryRun) {
    $script:LogFilePath = Get-LogFilePath
    $null = New-Item -ItemType File -Path $script:LogFilePath -Force -ErrorAction Stop
}

$allowedExtensions = Get-AllowedExtensions -Inputs $Extensions
$foldersToProcess = @((Get-Item -LiteralPath $resolvedSource))
if ($Recurse) {
    $foldersToProcess += @(Get-ChildItem -LiteralPath $resolvedSource -Directory -Recurse | Sort-Object FullName)
}
$foldersToProcess = @($foldersToProcess | Sort-Object FullName -Unique)

$renamedCount = 0
$skippedCount = 0

foreach ($folder in $foldersToProcess) {
    $folderPlan = @(Get-RenamePlanForFolder -Folder $folder -AllowedExtensions $allowedExtensions)

    if ($DryRun) {
        foreach ($item in $folderPlan) {
            foreach ($conflictMessage in $item.ConflictMessages) {
                Write-LogMessage $conflictMessage
            }
            Write-LogMessage ("[DRY-RUN] {0} -> {1} ({2})" -f $item.File.FullName, $item.NewName, $item.Source)
        }
        continue
    }

    if ($Interactive) {
        foreach ($item in $folderPlan) {
            foreach ($conflictMessage in $item.ConflictMessages) {
                Write-Output $conflictMessage
            }
            Write-Output ("[DRY-RUN] {0} -> {1} ({2})" -f $item.File.FullName, $item.NewName, $item.Source)
        }

        $shouldProceed = Confirm-InteractiveFolder -FolderPath $folder.FullName -PlannedCount $folderPlan.Count
        if (-not $shouldProceed) {
            Write-Output ("Skipping folder '{0}'." -f $folder.FullName)
            continue
        }
    }

    foreach ($item in $folderPlan) {
        foreach ($conflictMessage in $item.ConflictMessages) {
            Write-LogMessage $conflictMessage
        }

        $newPath = Join-Path -Path $item.File.DirectoryName -ChildPath $item.NewName
        if ($PSCmdlet.ShouldProcess($item.File.FullName, "Rename to $($item.NewName)")) {
            Write-LogMessage ("[RENAME] {0} -> {1} ({2})" -f $item.File.FullName, $newPath, $item.Source)
            Rename-Item -LiteralPath $item.File.FullName -NewName $item.NewName -ErrorAction Stop
            $renamedCount++
        }
    }
}

[pscustomobject]@{
    SourceDir = $resolvedSource
    Recurse = $Recurse.IsPresent
    DryRun = $DryRun.IsPresent
    RenamedCount = $renamedCount
    SkippedCount = $skippedCount
    LogFile = if ($script:LogFilePath) { $script:LogFilePath } else { $null }
}
