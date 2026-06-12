Write-Host "Welcome to the Jellyfin Media Automation Setup Wizard!" -ForegroundColor Cyan
Write-Host "This script will help you configure your .env and config.json files." -ForegroundColor Cyan
Write-Host ""

function Prompt-User {
    param(
        [string]$Message,
        [string]$DefaultValue = ""
    )
    $prompt = if ($DefaultValue) { "$Message [$DefaultValue]: " } else { "$Message: " }
    $input = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($input)) {
        return $DefaultValue
    }
    return $input
}

# --- .env Setup ---
Write-Host "--- .env Configuration ---" -ForegroundColor Yellow
$envExamplePath = ".\.env.example"
$envPath = ".\.env"

if (Test-Path $envExamplePath) {
    $envContent = Get-Content $envExamplePath
    $newEnvContent = @()

    foreach ($line in $envContent) {
        if ($line.Trim() -eq "" -or $line.StartsWith("#")) {
            $newEnvContent += $line
            continue
        }

        $parts = $line -split '=', 2
        if ($parts.Length -eq 2) {
            $key = $parts[0]
            $defaultValue = $parts[1]

            # Remove inline comments for the prompt default
            $cleanDefault = ($defaultValue -split '#')[0].Trim()

            $userInput = Prompt-User -Message "Enter value for $key" -DefaultValue $cleanDefault
            $newEnvContent += "$key=$userInput"
        } else {
            $newEnvContent += $line
        }
    }

    $newEnvContent | Set-Content $envPath
    Write-Host "Saved .env file successfully!" -ForegroundColor Green
} else {
    Write-Host ".env.example not found. Skipping .env configuration." -ForegroundColor Red
}
Write-Host ""

# --- config.json Setup ---
Write-Host "--- config.json Configuration ---" -ForegroundColor Yellow
$configExamplePath = ".\config.example.json"
$configPath = ".\config.json"

if (Test-Path $configExamplePath) {
    # Specify the encoding and handle the JSON parsing carefully
    $configJson = Get-Content -Path $configExamplePath -Raw | ConvertFrom-Json

    Write-Host "Let's configure the essential paths." -ForegroundColor Cyan

    $configJson.Paths.LogDirectory = Prompt-User -Message "Enter LogDirectory path" -DefaultValue $configJson.Paths.LogDirectory
    $configJson.Paths.BatchScript = Prompt-User -Message "Enter BatchScript path" -DefaultValue $configJson.Paths.BatchScript
    $configJson.Paths.FfmpegTemp = Prompt-User -Message "Enter FfmpegTemp path" -DefaultValue $configJson.Paths.FfmpegTemp

    $configureUsers = Prompt-User -Message "Do you want to configure Users now? (y/n)" -DefaultValue "y"
    if ($configureUsers -eq 'y') {
        $configJson.Users = @{}
        while ($true) {
            $seerrUser = Prompt-User -Message "Enter the Seerr username (used as the main key)"
            if ([string]::IsNullOrWhiteSpace($seerrUser)) {
                Write-Host "Seerr username cannot be empty." -ForegroundColor Red
                continue
            }

            $userObj = @{}
            $userObj.Name = Prompt-User -Message "Enter display Name for this user" -DefaultValue $seerrUser

            $jfUsersStr = Prompt-User -Message "Enter Jellyfin usernames (comma separated, leave empty if same as Seerr username)" -DefaultValue ""
            if ([string]::IsNullOrWhiteSpace($jfUsersStr) -or $jfUsersStr -eq "n/a") {
                $userObj.JellyfinUsers = @($seerrUser)
            } else {
                $jfUsers = $jfUsersStr -split ',' | ForEach-Object { $_.Trim() }
                $userObj.JellyfinUsers = @($jfUsers)
            }

            $email = Prompt-User -Message "Enter Email address (leave empty or type 'n/a' to skip)" -DefaultValue ""
            if (-not [string]::IsNullOrWhiteSpace($email) -and $email -ne "n/a") {
                $userObj.Email = $email
            }

            $discordId = Prompt-User -Message "Enter Discord ID (leave empty or type 'n/a' to skip)" -DefaultValue ""
            if (-not [string]::IsNullOrWhiteSpace($discordId) -and $discordId -ne "n/a") {
                $userObj.DiscordID = $discordId
            }

            $configJson.Users.$seerrUser = $userObj

            $addMore = Prompt-User -Message "Add another User? (y/n)" -DefaultValue "n"
            if ($addMore -ne 'y') { break }
        }
    }

    $configureFolders = Prompt-User -Message "Do you want to configure WatchFolders now? (y/n)" -DefaultValue "n"
    if ($configureFolders -eq 'y') {
        $configJson.WatchFolders = @()
        while ($true) {
            $watchFolder = @{}
            $watchFolder.Watch = Prompt-User -Message "Enter the folder path to Watch for unprocessed media"
            $watchFolder.Processed = Prompt-User -Message "Enter the Processed destination path"
            $type = Prompt-User -Message "Is this for Radarr or Sonarr?" -DefaultValue "Radarr"
            $watchFolder.Type = $type
            $isPriority = Prompt-User -Message "Is this a priority queue? (true/false)" -DefaultValue "false"

            # Parse string to boolean safely
            if ($isPriority -match "true|t|1|yes|y") {
                $watchFolder.IsPriority = $true
            } else {
                $watchFolder.IsPriority = $false
            }

            $configJson.WatchFolders += $watchFolder

            $addMore = Prompt-User -Message "Add another WatchFolder? (y/n)" -DefaultValue "n"
            if ($addMore -ne 'y') { break }
        }
    }

    $configureDirectFolders = Prompt-User -Message "Do you want to configure DirectWatchFolders now? (y/n)" -DefaultValue "n"
    if ($configureDirectFolders -eq 'y') {
        $configJson.DirectWatchFolders = @()
        while ($true) {
            $directFolder = @{}
            $directFolder.Watch = Prompt-User -Message "Enter the folder path to Watch for direct additions"
            $type = Prompt-User -Message "Is this for Radarr or Sonarr?" -DefaultValue "Radarr"
            $directFolder.Type = $type

            $configJson.DirectWatchFolders += $directFolder

            $addMore = Prompt-User -Message "Add another DirectWatchFolder? (y/n)" -DefaultValue "n"
            if ($addMore -ne 'y') { break }
        }
    }

    $configJson | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath -Encoding UTF8
    Write-Host "Saved config.json file successfully!" -ForegroundColor Green
} else {
    Write-Host "config.example.json not found. Skipping config.json configuration." -ForegroundColor Red
}

Write-Host ""
Write-Host "Setup complete! You can now run the automation scripts." -ForegroundColor Green
