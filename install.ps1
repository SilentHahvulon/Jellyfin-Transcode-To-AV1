param(
    [string]$InstallPath = "$env:USERPROFILE\JellyfinMediaAutomation"
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Jellyfin Media Automation Installer" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Ask for installation directory
$userInputPath = Read-Host "Enter installation directory [$InstallPath]"
if (-not [string]::IsNullOrWhiteSpace($userInputPath)) {
    $InstallPath = $userInputPath
}

if (-not (Test-Path $InstallPath)) {
    Write-Host "Creating directory $InstallPath..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
}

Write-Host "Downloading latest version from GitHub..." -ForegroundColor Yellow
$zipUrl = "https://github.com/SilentHahvulon/Jellyfin-Transcode-To-AV1/archive/refs/heads/main.zip"
$zipPath = "$env:TEMP\JellyfinMediaAutomation.zip"

Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath

Write-Host "Extracting files to $InstallPath..." -ForegroundColor Yellow
$tempExtract = "$env:TEMP\JellyfinMediaAutomation_Extract"
if (Test-Path $tempExtract) { Remove-Item -Recurse -Force $tempExtract }
New-Item -ItemType Directory -Path $tempExtract | Out-Null

Expand-Archive -Path $zipPath -DestinationPath $tempExtract -Force

# GitHub zips put everything in a subfolder (e.g., Jellyfin-Transcode-To-AV1-main)
$extractedFolder = Get-ChildItem -Path $tempExtract -Directory | Select-Object -First 1
Copy-Item -Path "$($extractedFolder.FullName)\*" -Destination $InstallPath -Recurse -Force

# Cleanup temp files
Remove-Item -Path $zipPath -Force
Remove-Item -Recurse -Force $tempExtract

Write-Host "Files downloaded and extracted successfully." -ForegroundColor Green
Write-Host ""

# 2. Check Dependencies
$binPath = Join-Path -Path $InstallPath -ChildPath "bin"
if (-not (Test-Path $binPath)) {
    New-Item -ItemType Directory -Path $binPath -Force | Out-Null
}

# Add local bin to PATH temporarily for the installer
$env:PATH = "$binPath;" + $env:PATH

$ffmpegMissing = $null -eq (Get-Command ffmpeg -ErrorAction SilentlyContinue)
$abav1Missing = $null -eq (Get-Command ab-av1 -ErrorAction SilentlyContinue)

if ($ffmpegMissing -or $abav1Missing) {
    Write-Host "Missing dependencies detected." -ForegroundColor Red
    if ($ffmpegMissing) { Write-Host " - ffmpeg not found" -ForegroundColor Yellow }
    if ($abav1Missing) { Write-Host " - ab-av1 not found" -ForegroundColor Yellow }

    $downloadDeps = Read-Host "Would you like to automatically download these dependencies into the local bin folder? (y/n) [y]"
    if ([string]::IsNullOrWhiteSpace($downloadDeps)) { $downloadDeps = "y" }

    if ($downloadDeps -match "^y") {
        if ($ffmpegMissing) {
            Write-Host "Downloading FFmpeg..." -ForegroundColor Yellow
            $ffmpegZipUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
            $ffmpegZipPath = "$env:TEMP\ffmpeg.zip"
            Invoke-WebRequest -Uri $ffmpegZipUrl -OutFile $ffmpegZipPath

            Write-Host "Extracting FFmpeg..." -ForegroundColor Yellow
            $ffmpegExtractPath = "$env:TEMP\ffmpeg_extract"
            if (Test-Path $ffmpegExtractPath) { Remove-Item -Recurse -Force $ffmpegExtractPath }
            Expand-Archive -Path $ffmpegZipPath -DestinationPath $ffmpegExtractPath -Force

            $ffmpegExe = Get-ChildItem -Path $ffmpegExtractPath -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
            $ffprobeExe = Get-ChildItem -Path $ffmpegExtractPath -Recurse -Filter "ffprobe.exe" | Select-Object -First 1

            Copy-Item -Path $ffmpegExe.FullName -Destination $binPath -Force
            Copy-Item -Path $ffprobeExe.FullName -Destination $binPath -Force

            Remove-Item -Path $ffmpegZipPath -Force
            Remove-Item -Recurse -Force $ffmpegExtractPath
            Write-Host "FFmpeg downloaded and installed locally." -ForegroundColor Green
        }

        if ($abav1Missing) {
            Write-Host "Downloading ab-av1..." -ForegroundColor Yellow
            # Get latest release from github API or hardcode known url format. Let's use latest release.
            $abav1ZipUrl = "https://github.com/alexheretic/ab-av1/releases/download/v0.7.13/ab-av1-v0.7.13-x86_64-pc-windows-msvc.zip"
            $abav1ZipPath = "$env:TEMP\abav1.zip"
            Invoke-WebRequest -Uri $abav1ZipUrl -OutFile $abav1ZipPath

            Write-Host "Extracting ab-av1..." -ForegroundColor Yellow
            $abav1ExtractPath = "$env:TEMP\abav1_extract"
            if (Test-Path $abav1ExtractPath) { Remove-Item -Recurse -Force $abav1ExtractPath }
            Expand-Archive -Path $abav1ZipPath -DestinationPath $abav1ExtractPath -Force

            $abav1Exe = Get-ChildItem -Path $abav1ExtractPath -Recurse -Filter "ab-av1.exe" | Select-Object -First 1
            Copy-Item -Path $abav1Exe.FullName -Destination $binPath -Force

            Remove-Item -Path $abav1ZipPath -Force
            Remove-Item -Recurse -Force $abav1ExtractPath
            Write-Host "ab-av1 downloaded and installed locally." -ForegroundColor Green
        }
    } else {
        Write-Host "Skipping dependency downloads. Please ensure they are installed manually." -ForegroundColor Yellow
    }
} else {
    Write-Host "All dependencies (ffmpeg, ab-av1) are already available in your PATH." -ForegroundColor Green
}
Write-Host ""

# 3. Create Desktop Shortcut
Write-Host "Creating Desktop Shortcut..." -ForegroundColor Yellow
$WshShell = New-Object -comObject WScript.Shell
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$Shortcut = $WshShell.CreateShortcut("$DesktopPath\Jellyfin Media Automation.lnk")
$Shortcut.TargetPath = "powershell.exe"
$Shortcut.Arguments = "-ExecutionPolicy Bypass -NoExit -File `"$InstallPath\Start-JellyfinAutomation.ps1`""
$Shortcut.WorkingDirectory = $InstallPath
$Shortcut.IconLocation = "powershell.exe,0"
$Shortcut.Description = "Launch Jellyfin Media Automation Scripts"
$Shortcut.Save()
Write-Host "Shortcut created on Desktop." -ForegroundColor Green
Write-Host ""

# 4. Run Setup
Write-Host "Launching Setup Wizard..." -ForegroundColor Cyan
Set-Location -Path $InstallPath
if (Test-Path ".\setup.ps1") {
    # Run setup.ps1 in the current process so we wait for it
    . .\setup.ps1
} else {
    Write-Host "setup.ps1 not found in $InstallPath" -ForegroundColor Red
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Installation Complete!" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "You can start the automation at any time by double-clicking"
Write-Host "the 'Jellyfin Media Automation' shortcut on your Desktop."
Write-Host "==========================================" -ForegroundColor Cyan
