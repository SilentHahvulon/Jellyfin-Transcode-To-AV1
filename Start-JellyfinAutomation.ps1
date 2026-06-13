# Set the current directory to the script's directory so relative paths work
Set-Location -Path $PSScriptRoot

Write-Host "Starting Jellyfin Media Automation..." -ForegroundColor Cyan

# Check if the scripts exist before trying to run them
$autoAddScript = ".\auto_add_to_ab-av1.ps1"
$directAddScript = ".\direct_add_notify.ps1"

if (Test-Path $autoAddScript) {
    Write-Host "Launching Auto-Add Transcoding Script..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoExit -File `"$autoAddScript`""
} else {
    Write-Host "Warning: $autoAddScript not found!" -ForegroundColor Red
}

if (Test-Path $directAddScript) {
    Write-Host "Launching Direct Add Notify Script..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoExit -File `"$directAddScript`""
} else {
    Write-Host "Warning: $directAddScript not found!" -ForegroundColor Red
}

Write-Host "Automation scripts launched in separate windows." -ForegroundColor Green
