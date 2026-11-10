# media-renamer
Media renaming utilities focused on timestamp-based naming.

This repository is dedicated to media renaming only. The first implementation is a PowerShell renamer, and future implementations will stay within that same media-renaming scope.

## Project layout

- `scripts/powershell/Rename-MediaFiles.ps1` - the executable PowerShell entry point for renaming media files in place
- `libraries/powershell/Rename-MediaFiles.ps1` - the reusable library-style version that mirrors the script logic for code reuse and testing
- `tests/Rename-MediaFiles.Tests.ps1` - smoke tests covering the expected behavior and regression checks

## PowerShell usage

### Requirements for the PowerShell version

The script uses standard PowerShell cmdlets for filtering and renaming files in place.

- PowerShell 5.1+ or PowerShell 7+
- ExifTool on `PATH` to read HEIC and media-container timestamps. Without it, the script still uses filename timestamps and filesystem dates; supported raster images retain the `System.Drawing` EXIF fallback.
- ImageMagick on `PATH`, built with HEIC support, to convert HEIC files to JPEG.

### What the script does

The script scans a source directory, finds supported media files, and renames each file in place to a timestamp-based name using the pattern:

```text
yyyymmdd-hhmmss.ext
```

The rename is performed in place inside the same directory as the original file. The script does not copy the file to a separate target folder. HEIC files are converted to JPG, transferable embedded metadata is copied with ExifTool, and the original filesystem Created and Modified times are applied to the JPG. The HEIC is removed only after conversion and metadata copying succeed.

#### Timestamp selection logic

For every eligible file, the script resolves the timestamp in priority order:

1. Embedded timestamp in the original filename, ignoring the extension
2. Photo capture metadata (`DateTimeOriginal`, then `DateTimeDigitized`)
3. `MediaCreateDate`
4. `TrackCreateDate`
5. `CreateDate`
6. `MediaModifyDate` (media update date)
7. `TrackModifyDate` (track media/update date)
8. `ModifyDate` (update date)
9. File Creation Date/Time
10. File Modification Date/Time

The filename-based detection looks for a valid `20xx` date/time embedded in the basename, using a pattern such as:

```text
2024-09-15_13-45-12
```

and it validates the result before using it. Invalid embedded timestamps are ignored and the script continues with the next available source.

Once a valid timestamp is found, it is converted to a `DateTime` and formatted as:

```text
yyyyMMdd-HHmmss
```

For example:

```text
2024-09-15 13:45:12 -> 20240915-134512
```

After that, the extension is appended.

ExifTool reads the listed metadata fields for supported media files, including HEIC and media containers. If no metadata date is found, the script uses the filesystem creation time, then the filesystem modification time. HEIC metadata reading and preservation require ExifTool on `PATH`; converting HEIC to JPG also requires ImageMagick with HEIC support.

#### Extension handling and normalization

The script only considers supported media extensions. The default supported list is:

- `.jpg`, `.jpeg`, `.png`, `.gif`, `.bmp`, `.tif`, `.tiff`, `.heic`
- `.mp4`, `.mov`, `.avi`, `.mkv`, `.wmv`, `.webm`, `.m4v`
- `.mp3`, `.wav`, `.aac`, `.flac`, `.ogg`

Before naming, the extension is normalized as follows:

- it is lower-cased
- `.jpeg` is rewritten to `.jpg`
- `.heic` remains `.heic` (lowercase)
- any other supported extension keeps its normalized lowercase form

Examples:

- `IMG.JPG` -> `20240915-134512.jpg`
- `photo.JPEG` -> `20240915-134512.jpg`
- `video.MP4` -> `20240915-134512.mp4`

#### Collision handling

If two files in the same folder would end up with the same final name, the later file is shifted forward by one second until the name is unique. The script logs that adjustment and continues with the next timestamp.

Example:

- first file -> `20240915-134512.jpg`
- second file with the same timestamp -> `20240915-134513.jpg`

This prevents accidental overwrites.

### Parameters and options

#### Required parameter

- `-SourceDir <path>`
  - Required path to the directory to process; optionally append a filename wildcard pattern, such as `C:\path\to\source\IMG*.jpg`
  - Relative and absolute paths are resolved to the same canonical path before processing
  - The directory must exist and must be a directory; wildcard characters are supported only in the final filename component

#### Switches

- `-DryRun`
  - Preview mode only
  - Prints the planned renames to the console
  - Does not rename any files

- `-Interactive`
  - Has no effect in `-DryRun` mode
  - In normal mode, it prints the dry-run preview for each folder and prompts for confirmation before renaming that folder
  - If you answer `N`, the folder is skipped and processing continues with the next folder

- `-Recurse`
  - Alias: `-Recursive`
  - Includes files in subfolders under `-SourceDir`
  - Without this switch, only files in the top-level source directory are processed

- `-WhatIf`
  - Supported by PowerShell’s built-in `SupportsShouldProcess`
  - Shows the rename plan without applying the changes

#### Optional parameter

- `-Extensions <string[]>`
  - Lets you override the set of accepted extensions
  - Values are treated as glob-like patterns such as `*.jpg` and `*.jpeg`
  - The script normalizes them before comparing to the actual file extension

### Logging behaviour

- In `-DryRun` mode, log lines are printed to the console.
- In a real run, the script writes a timestamped log file in the current working directory using the pattern:

```text
Rename-MediaFiles-yyyymmdd-hhmmss.log
```

The log includes messages such as:

- `[DRY-RUN] ...`
- `[RENAME] ...`
- `[CONFLICT] ...`

### Examples

Rename files in a directory using the automatic timestamp priority:

```powershell
powershell -NoProfile -File .\scripts\powershell\Rename-MediaFiles.ps1 -SourceDir "C:\path\to\source"
```

Preview the renames without changing files:

```powershell
powershell -NoProfile -File .\scripts\powershell\Rename-MediaFiles.ps1 -SourceDir "C:\path\to\source" -DryRun
```

Process files recursively under a source tree:

```powershell
powershell -NoProfile -File .\scripts\powershell\Rename-MediaFiles.ps1 -SourceDir "C:\path\to\source" -Recurse
```

Process only JPG files whose names start with `IMG`, including matching files in subfolders:

```powershell
powershell -NoProfile -File .\scripts\powershell\Rename-MediaFiles.ps1 -SourceDir "C:\path\to\source\IMG*.jpg" -Recurse -DryRun
```

Only process JPEG and PNG images:

```powershell
powershell -NoProfile -File .\scripts\powershell\Rename-MediaFiles.ps1 -SourceDir "C:\path\to\source" -Extensions '*.jpg','*.jpeg','*.png'
```

The script renames files to the pattern:

```text
yyyymmdd-hhmmss.ext
```

where `ext` is the normalized lower-case extension of the original file, with `.jpeg` normalized to `.jpg`.
