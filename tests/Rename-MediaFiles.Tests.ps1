$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$scriptPath = Join-Path $PSScriptRoot '..\scripts\powershell\Rename-MediaFiles.ps1'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("media-renamer-tests-" + [System.Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempRoot -Force

try {
    $sourceRoot = Join-Path $tempRoot 'source'
    $null = New-Item -ItemType Directory -Path $sourceRoot -Force

    $fileA = Join-Path $sourceRoot 'sample.jpg'
    [System.IO.File]::WriteAllBytes($fileA, [byte[]](1, 2, 3, 4))
    (Get-Item $fileA).LastWriteTime = [System.DateTime]::Parse('2024-09-15 13:45:12')
    (Get-Item $fileA).CreationTime = [System.DateTime]::Parse('2024-09-15 13:45:12')

    $fileB = Join-Path $sourceRoot 'sample-copy.jpg'
    [System.IO.File]::WriteAllBytes($fileB, [byte[]](5, 6, 7, 8))
    (Get-Item $fileB).LastWriteTime = [System.DateTime]::Parse('2024-09-15 13:45:12')
    (Get-Item $fileB).CreationTime = [System.DateTime]::Parse('2024-09-15 13:45:12')

    Push-Location $tempRoot
    try {
        $resultA = & $scriptPath -SourceDir $sourceRoot
        Assert-True ($resultA.RenamedCount -eq 2) "Expected both media files to be renamed in place."
        Assert-True (Test-Path (Join-Path $sourceRoot '20240915-134512.jpg')) "Expected first file to be renamed to 20240915-134512.jpg."
        Assert-True (Test-Path (Join-Path $sourceRoot '20240915-134513.jpg')) "Expected duplicate timestamp to increment the second to 20240915-134513.jpg."

        $logFiles = @(Get-ChildItem -Path $tempRoot -Filter 'Rename-MediaFiles-*.log' | Sort-Object LastWriteTime -Descending)
        Assert-True ($logFiles.Count -ge 1) "Expected the real execution to create a timestamped log file in the current directory."
        $logText = (Get-Content -LiteralPath $logFiles[0].FullName -Raw)
        Assert-True ($logText.Contains('[CONFLICT]')) "Expected the log file to note a conflict when a duplicate name is adjusted by extra seconds."
        Assert-True ($logText.Contains('20240915-134513.jpg')) "Expected the log file to show the incremented timestamp chosen after the conflict."
    }
    finally {
        Pop-Location
    }

    $filenameTimestampFile = Join-Path $sourceRoot 'photo_2024-09-18_10-30-45.jpg'
    [System.IO.File]::WriteAllBytes($filenameTimestampFile, [byte[]](9, 9, 9))
    (Get-Item $filenameTimestampFile).LastWriteTime = [System.DateTime]::Parse('2024-09-20 08:00:00')
    (Get-Item $filenameTimestampFile).CreationTime = [System.DateTime]::Parse('2024-09-19 07:00:00')

    $resultFilename = & $scriptPath -SourceDir $sourceRoot
    Assert-True ($resultFilename.RenamedCount -ge 3) "Expected files with embedded timestamps to prefer the filename date."
    Assert-True (Test-Path (Join-Path $sourceRoot '20240918-103045.jpg')) "Expected a valid embedded filename timestamp to win over file system timestamps."

    $invalidEmbeddedFile = Join-Path $sourceRoot 'notadate_2024-99-99_88-88-88.jpg'
    [System.IO.File]::WriteAllBytes($invalidEmbeddedFile, [byte[]](10, 11, 12))
    (Get-Item $invalidEmbeddedFile).LastWriteTime = [System.DateTime]::Parse('2024-09-21 11:15:16')
    (Get-Item $invalidEmbeddedFile).CreationTime = [System.DateTime]::Parse('2024-09-21 11:15:16')

    $resultInvalid = & $scriptPath -SourceDir $sourceRoot
    Assert-True (Test-Path (Join-Path $sourceRoot '20240921-111516.jpg')) "Expected an invalid embedded timestamp to be ignored so the file system timestamp is used as fallback."

    $sourceRoot2 = Join-Path $tempRoot 'source2'
    $null = New-Item -ItemType Directory -Path $sourceRoot2 -Force
    $upperCaseFile = Join-Path $sourceRoot2 'uppercase.JPG'
    $bitmapUpper = New-Object System.Drawing.Bitmap(1, 1)
    $bitmapUpper.SetPixel(0, 0, [System.Drawing.Color]::Red)
    $bitmapUpper.Save($upperCaseFile, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bitmapUpper.Dispose()
    (Get-Item $upperCaseFile).LastWriteTime = [System.DateTime]::Parse('2024-09-16 08:10:42')
    (Get-Item $upperCaseFile).CreationTime = [System.DateTime]::Parse('2024-09-16 08:10:42')

    $dryRunOutput = & $scriptPath -SourceDir $sourceRoot2 -DryRun 2>&1
    $dryRunText = ($dryRunOutput | Out-String)
    Assert-True ($dryRunText.Contains('[DRY-RUN]')) "Expected dry-run mode to print the planned rename to the screen."
    Assert-True ($dryRunText.Contains('20240916-081042.jpg')) "Expected uppercase source extension to be normalized to lowercase in the dry-run preview."
    Assert-True (-not $dryRunText.Contains('20240916-081042.JPG')) "Expected the preview output to avoid uppercase extensions."
    Assert-True ($dryRunText.Contains('(file property Created date)')) "Expected dry-run output to indicate the Created-date timestamp source used for the rename."

    $filenameSourceFile = Join-Path $sourceRoot2 'IMG_2024-09-18_10-30-45.jpg'
    [System.IO.File]::WriteAllBytes($filenameSourceFile, [byte[]](99, 98, 97))
    (Get-Item $filenameSourceFile).LastWriteTime = [System.DateTime]::Parse('2024-09-20 08:00:00')
    $filenameDryRun = & $scriptPath -SourceDir $sourceRoot2 -DryRun 2>&1
    $filenameDryRunText = ($filenameDryRun | Out-String)
    Assert-True ($filenameDryRunText.Contains('(filename)')) "Expected a filename-derived timestamp to be labeled in the dry-run output."

    $patternRoot = Join-Path $tempRoot 'pattern'
    $patternSubfolder = Join-Path $patternRoot 'subfolder'
    $null = New-Item -ItemType Directory -Path $patternSubfolder -Force
    foreach ($patternFile in @(
        (Join-Path $patternRoot 'IMG001.jpg'),
        (Join-Path $patternRoot 'other.jpg'),
        (Join-Path $patternSubfolder 'IMG002.jpg'),
        (Join-Path $patternSubfolder 'IMG003.png')
    )) {
        [System.IO.File]::WriteAllBytes($patternFile, [byte[]](1, 2, 3))
    }
    $patternPreview = & $scriptPath -SourceDir (Join-Path $patternRoot 'IMG*.jpg') -Recurse -DryRun 2>&1
    $patternPreviewText = ($patternPreview | Out-String)
    Assert-True ($patternPreviewText.Contains('IMG001.jpg')) "Expected the filename pattern to match files in the source directory."
    Assert-True ($patternPreviewText.Contains('IMG002.jpg')) "Expected the filename pattern to match files in recursively scanned subfolders."
    Assert-True (-not $patternPreviewText.Contains('other.jpg')) "Expected files outside the filename pattern to be excluded."
    Assert-True (-not $patternPreviewText.Contains('IMG003.png')) "Expected extension filtering to remain active with a filename pattern."

    $heicRoot = Join-Path $tempRoot 'heic'
    $null = New-Item -ItemType Directory -Path $heicRoot -Force
    $heicFile = Join-Path $heicRoot 'phone_2024-10-11_12-13-14.HEIC'
    [System.IO.File]::WriteAllBytes($heicFile, [byte[]](1, 2, 3, 4))
    $heicDryRun = & $scriptPath -SourceDir $heicRoot -DryRun 2>&1
    $heicDryRunText = ($heicDryRun | Out-String)
    Assert-True ($heicDryRunText.Contains('20241011-121314.jpg')) "Expected HEIC files to be planned as JPG output by default."
    Assert-True ($heicDryRunText.Contains('(HEIC to JPG; filename)')) "Expected the preview to identify HEIC-to-JPG conversion."

    if ($null -eq (Get-Command -Name 'magick' -CommandType Application -ErrorAction SilentlyContinue)) {
        $missingConverterRoot = Join-Path $tempRoot 'missing-converter'
        $null = New-Item -ItemType Directory -Path $missingConverterRoot -Force
        $missingConverterFile = Join-Path $missingConverterRoot 'photo_2024-10-11_12-13-14.heic'
        [System.IO.File]::WriteAllBytes($missingConverterFile, [byte[]](3, 2, 1))
        $conversionFailed = $false
        try {
            $null = & $scriptPath -SourceDir $missingConverterRoot
        }
        catch {
            $conversionFailed = $_.Exception.Message.Contains('ImageMagick is required')
        }
        Assert-True $conversionFailed "Expected a clear dependency error when ImageMagick is unavailable."
        Assert-True (Test-Path -LiteralPath $missingConverterFile) "Expected the original HEIC to remain untouched when conversion cannot start."
    }

    $fileDateRoot = Join-Path $tempRoot 'file-date-priority'
    $null = New-Item -ItemType Directory -Path $fileDateRoot -Force
    $fileDate = Join-Path $fileDateRoot 'no-metadata.heic'
    [System.IO.File]::WriteAllBytes($fileDate, [byte[]](4, 3, 2, 1))
    (Get-Item $fileDate).CreationTime = [System.DateTime]::Parse('2024-10-14 08:07:06')
    (Get-Item $fileDate).LastWriteTime = [System.DateTime]::Parse('2024-10-15 09:08:07')
    $fileDatePreview = & $scriptPath -SourceDir $fileDateRoot -DryRun 2>&1
    $fileDatePreviewText = ($fileDatePreview | Out-String)
    Assert-True ($fileDatePreviewText.Contains('20241014-080706.jpg (HEIC to JPG; file property Created date)')) "Expected HEIC output to be JPG and File Creation Date/Time to be preferred over File Modification Date/Time."

    $exifToolCommand = Get-Command -Name 'exiftool' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $exifToolCommand) {
        $heicMetadataRoot = Join-Path $tempRoot 'heic-metadata'
        $null = New-Item -ItemType Directory -Path $heicMetadataRoot -Force
        $metadataJpeg = Join-Path $heicMetadataRoot 'metadata.jpg'
        $metadataHeic = Join-Path $heicMetadataRoot 'metadata.HEIC'
        $metadataBitmap = New-Object System.Drawing.Bitmap(2, 2)
        $metadataBitmap.Save($metadataJpeg, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        $metadataBitmap.Dispose()
        & $exifToolCommand.Source -overwrite_original '-DateTimeOriginal=2024:10:12 13:14:15' $metadataJpeg | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "Expected ExifTool to write the capture-date test fixture."
        Copy-Item -LiteralPath $metadataJpeg -Destination $metadataHeic
        (Get-Item $metadataHeic).LastWriteTime = [System.DateTime]::Parse('2024-10-13 09:00:00')

        $heicMetadataDryRun = & $scriptPath -SourceDir $heicMetadataRoot -DryRun 2>&1
        $heicMetadataDryRunText = ($heicMetadataDryRun | Out-String)
        Assert-True ($heicMetadataDryRunText.Contains('20241012-131415.jpg')) "Expected HEIC EXIF capture time to take priority over file properties and produce JPG output."
        Assert-True ($heicMetadataDryRunText.Contains('(EXIF Photo taken)')) "Expected HEIC EXIF timestamp source to be identified in the preview."
    }

    $interactiveRoot = Join-Path $tempRoot 'interactive'
    $null = New-Item -ItemType Directory -Path $interactiveRoot -Force
    $interactiveFile = Join-Path $interactiveRoot 'manual_2024-09-22_15-05-09.jpg'
    [System.IO.File]::WriteAllBytes($interactiveFile, [byte[]](1, 2, 3, 4))
    (Get-Item $interactiveFile).LastWriteTime = [System.DateTime]::Parse('2024-09-23 10:20:30')
    $previousAutoConfirm = $env:MEDIA_RENAMER_AUTO_CONFIRM
    $env:MEDIA_RENAMER_AUTO_CONFIRM = 'Y'
    try {
        $interactiveResult = & $scriptPath -SourceDir $interactiveRoot -Interactive
        Assert-True ($interactiveResult.RenamedCount -eq 1) "Expected interactive mode to proceed after confirmation."
        Assert-True (Test-Path (Join-Path $interactiveRoot '20240922-150509.jpg')) "Expected interactive mode to rename the file after confirmation."
    }
    finally {
        if ($null -eq $previousAutoConfirm) {
            Remove-Item Env:MEDIA_RENAMER_AUTO_CONFIRM -ErrorAction SilentlyContinue
        }
        else {
            $env:MEDIA_RENAMER_AUTO_CONFIRM = $previousAutoConfirm
        }
    }

    $jpegFile = Join-Path $sourceRoot2 'jpegcase.JPEG'
    $bitmapJpeg = New-Object System.Drawing.Bitmap(1, 1)
    $bitmapJpeg.SetPixel(0, 0, [System.Drawing.Color]::Blue)
    $bitmapJpeg.Save($jpegFile, [System.Drawing.Imaging.ImageFormat]::Jpeg)
    $bitmapJpeg.Dispose()
    (Get-Item $jpegFile).LastWriteTime = [System.DateTime]::Parse('2024-09-17 09:20:30')
    (Get-Item $jpegFile).CreationTime = [System.DateTime]::Parse('2024-09-17 09:20:30')
    $jpegPreview = & $scriptPath -SourceDir $sourceRoot2 -DryRun 2>&1
    $jpegPreviewText = ($jpegPreview | Out-String)
    Assert-True ($jpegPreviewText.Contains('20240917-092030.jpg')) "Expected .jpeg source files to be renamed with a .jpg extension."
    Assert-True (-not $jpegPreviewText.Contains('20240917-092030.jpeg')) "Expected .jpeg source files to be normalized to .jpg."

    $realRunPreface = & $scriptPath -SourceDir $sourceRoot2
    Assert-True ($realRunPreface.RenamedCount -ge 1) "Expected the real run to rename files in place."
    Assert-True ((Test-Path (Join-Path $sourceRoot2 '20240916-081042.jpg'))) "Expected uppercase file to be renamed in place."
    Assert-True ((Test-Path (Join-Path $sourceRoot2 '20240917-092030.jpg'))) "Expected .jpeg file to be normalized and renamed in place."

    $logFilesAfter = @(Get-ChildItem -Path $tempRoot -Filter 'Rename-MediaFiles-*.log' | Sort-Object LastWriteTime -Descending)
    Assert-True ($logFilesAfter.Count -ge 1) "Expected the real execution to write a timestamped log file in the current working directory."
    $realtimeLogText = (Get-Content -LiteralPath $logFilesAfter[0].FullName -Raw)
    Assert-True ($realtimeLogText.Contains('[RENAME]')) "Expected the real execution to log rename actions to the file."

    Write-Host 'All tests passed.'
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
