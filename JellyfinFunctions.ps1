# Get the directory where the scripts are located
$PSScriptRoot = Split-Path -Parent -MyInvocation $MyInvocation.MyCommand.Definition

# 1. Load Environment Variables from .env
$envFile = Join-Path -Path $PSScriptRoot -ChildPath ".env"
if (Test-Path -LiteralPath $envFile) {
    Get-Content $envFile | Where-Object { $_ -match '^\s*[^#]' } | ForEach-Object {
        $name, $value = $_.Split('=', 2)
        [Environment]::SetEnvironmentVariable($name.Trim(), $value.Trim(), 'Process')
    }
} else {
    Write-Host "WARNING: .env file not found! Please copy .env.example to .env and configure it." -ForegroundColor Yellow
}

# 2. Load JSON Configuration
$configFile = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
if (Test-Path -LiteralPath $configFile) {
    $global:Config = Get-Content $configFile | ConvertFrom-Json
} else {
    Write-Host "ERROR: config.json not found! Please copy config.example.json to config.json and configure it." -ForegroundColor Red
    exit
}

# --- SHARED FUNCTIONS ---

function Write-DualLog {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [ConsoleColor]$Color = 'Gray',
        [string]$LogFile = $null
    )

    # 1. VISUAL: Sends the colored text only to your terminal
    Write-Host $Message -ForegroundColor $Color

    # 2. HIDDEN: Appends plain, ANSI-free text to a dedicated log file (if provided)
    if ($LogFile) {
        Add-Content -Path $LogFile -Value $Message
    }
}

function Send-DiscordWebhook {
    param(
        [Parameter(Mandatory=$true)][string]$WebhookUrl,
        [Parameter(Mandatory=$true)][hashtable]$Payload
    )
    if (-not [string]::IsNullOrWhiteSpace($WebhookUrl)) {
        try {
            Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body ($Payload | ConvertTo-Json -Depth 10) -ContentType "application/json" -ErrorAction Stop | Out-Null
        } catch { Write-Warning "[$($MyInvocation.MyCommand.Name)] Failed to send Discord webhook: $_" }
    }
}

function Send-NtfyNotification {
    param(
        [Parameter(Mandatory=$true)][string]$NtfyUrl,
        [string]$Token,
        [string]$Title,
        [string]$Message,
        [string]$Tags
    )
    if (-not [string]::IsNullOrWhiteSpace($NtfyUrl)) {
        try {
            $headers = @{}
            if (-not [string]::IsNullOrWhiteSpace($Token)) { $headers["Authorization"] = "Bearer $Token" }
            if (-not [string]::IsNullOrWhiteSpace($Title)) { $headers["Title"] = $Title }
            if (-not [string]::IsNullOrWhiteSpace($Tags)) { $headers["Tags"] = $Tags }

            Invoke-RestMethod -Uri $NtfyUrl -Method Post -Headers $headers -Body $Message -ErrorAction Stop | Out-Null
        } catch { Write-Warning "[$($MyInvocation.MyCommand.Name)] Failed to send Ntfy notification: $_" }
    }
}

function Send-JellyfinToast {
    param (
        [Parameter(Mandatory=$true)][string[]]$Users,
        [Parameter(Mandatory=$true)][string]$RequesterName,
        [Parameter(Mandatory=$true)][string]$Header,
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Url = $env:JELLYFIN_URL,
        [string]$ApiKey = $env:JELLYFIN_API_KEY
    )
    $headers = @{ "Authorization" = "MediaBrowser Token=$ApiKey"; "Content-Type" = "application/json" }
    try {
        $sessions = Invoke-RestMethod -Uri "$Url/sessions" -Method Get -Headers $headers
        $isWatching = $false
        foreach ($session in $sessions) {
            if ($Users -contains $session.UserName -and $null -ne $session.NowPlayingItem) {
                $isWatching = $true
                $sessionId = $session.Id
                $deviceName = $session.DeviceName
                Write-Host "[$($MyInvocation.MyCommand.Name)] $($session.UserName) is active on $deviceName. Sending toast..." -ForegroundColor Green
                $messagePayload = @{ Header = $Header; Text = $Message; TimeoutMs = 10000 } | ConvertTo-Json
                Invoke-RestMethod -Uri "$Url/Sessions/$sessionId/Message" -Method Post -Headers $headers -Body $messagePayload
            }
        }
        if (-not $isWatching) { Write-Host "[$($MyInvocation.MyCommand.Name)] $RequesterName is not streaming. No toast sent." -ForegroundColor Yellow }
    } catch { Write-Warning "[$($MyInvocation.MyCommand.Name)] Failed to contact Jellyfin API: $_" }
}

function Get-SeerrData($filePath, $type) {
    $result = @{ Title = ""; PosterUrl = ""; RequesterName = ""; IsRequested = $false; Mention = ""; ArrId = $null }
    try {
        $oldFolder = Split-Path -Path $filePath -Parent
        
        # Check if the folder is a "Season X" folder. If so, step up to the Show folder.
        $folderLeaf = Split-Path -Path $oldFolder -Leaf
        if ($folderLeaf -match "(?i)^Season\s*\d+") {
            $oldFolder = Split-Path -Path $oldFolder -Parent
        }

        $seerrHeaders = @{ "X-Api-Key" = $env:SEERR_API_KEY; "Accept" = "application/json" }
        $mediaId = $null; $seerrMediaType = ""

        if ($type -eq "Radarr") {
            $movies = Invoke-RestMethod -Uri "$($env:RADARR_URL)/api/v3/movie" -Method Get -Headers @{ "X-Api-Key" = $env:RADARR_API_KEY }
            $match = $movies | Where-Object { $_.path -eq $oldFolder } | Select-Object -First 1
            if ($match) {
                $mediaId = $match.tmdbId
                $result.Title = $match.title
                $seerrMediaType = "movie"
                $result.ArrId = $match.id
            }
        } else {
            $shows = Invoke-RestMethod -Uri "$($env:SONARR_URL)/api/v3/series" -Method Get -Headers @{ "X-Api-Key" = $env:SONARR_API_KEY }
            $match = $shows | Where-Object { $_.path -eq $oldFolder } | Select-Object -First 1
            if ($match) {
                $mediaId = $match.tvdbId
                $result.Title = $match.title
                $seerrMediaType = "tv"
                $result.ArrId = $match.id
            }
        }

        if ($mediaId) {
            $seerrMedia = Invoke-RestMethod -Uri "$($env:SEERR_URL)/api/v1/$seerrMediaType/$mediaId" -Headers $seerrHeaders -ErrorAction Stop
            if ($seerrMedia.posterPath) { $result.PosterUrl = "https://image.tmdb.org/t/p/w600_and_h900_bestv2$($seerrMedia.posterPath)" }
            
            if ($seerrMedia.mediaInfo.requests.Count -gt 0) {
                $reqInfo = Invoke-RestMethod -Uri "$($env:SEERR_URL)/api/v1/request/$($seerrMedia.mediaInfo.requests[0].id)" -Headers $seerrHeaders -ErrorAction Stop
                $result.RequesterName = $reqInfo.requestedBy.displayName
                $result.IsRequested = $true
                if ($global:Config.Users.ContainsKey($result.RequesterName) -and -not [string]::IsNullOrWhiteSpace($global:Config.Users[$result.RequesterName].DiscordID)) {
                    $result.Mention = "<@$($global:Config.Users[$result.RequesterName].DiscordID)>"
                }
            }
        }
    } catch { Write-Host "[Warning] Failed to fetch Seerr data: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    return [pscustomobject]$result
}

function Send-MediaEmail($toEmail, $subject, $body) {
    try {
        $smtpClient = [System.Net.Mail.SmtpClient]::new($env:SMTP_SERVER, $env:SMTP_PORT)
        $smtpClient.EnableSsl = $true
        $smtpClient.Credentials = [System.Net.NetworkCredential]::new($env:SMTP_USER, $env:SMTP_PASS)
        $mailMessage = [System.Net.Mail.MailMessage]::new()
        $mailMessage.From = [System.Net.Mail.MailAddress]::new($env:EMAIL_FROM, $env:EMAIL_FROM_NAME)
        $mailMessage.To.Add($toEmail)
        $mailMessage.Subject = $subject
        $mailMessage.Body = $body
        $mailMessage.IsBodyHtml = $true
        $smtpClient.Send($mailMessage)
        $smtpClient.Dispose(); $mailMessage.Dispose()
        Write-Host "Email sent to $toEmail" -ForegroundColor Green
    } catch { Write-Host "[Warning] Failed to send email: $($_.Exception.Message)" -ForegroundColor DarkYellow }
}

function Build-MediaEmailHtml {
    param ($Headline, $HeaderColor, $TextColor = "#121212", $UserName, $Message, [System.Collections.Specialized.OrderedDictionary]$Stats, $PosterUrl)
    
    $posterHtml = if (-not [string]::IsNullOrWhiteSpace($PosterUrl)) { "<td width='140' valign='top' style='padding-right: 25px;'><img src='$PosterUrl' width='140' style='border-radius: 8px;' /></td>" } else { "" }
    $statsHtml = ""
    foreach ($stat in $Stats.GetEnumerator()) { $statsHtml += "<div style='margin-bottom: 6px;'><strong style='color: #ffffff;'>$($stat.Name):</strong> $($stat.Value)</div>" }

    return @"
    <html lang="en"><body style="margin: 0; background-color: #121212;">
        <div style="font-family: sans-serif; padding: 40px 20px;">
            <div style="max-width: 600px; margin: 0 auto; background-color: #1e1e1e; border-radius: 12px; overflow: hidden;">
                <div style="background-color: $HeaderColor; padding: 18px 20px; text-align: center;">
                    <h2 style="margin: 0; color: $TextColor;">$Headline</h2>
                </div>
                <div style="padding: 30px;">
                    <table width="100%"><tr>
                        $posterHtml
                        <td valign="top" style="color: #d4d4d4;">
                            <p>Hey <strong style="color: #ffffff;">$UserName</strong>,</p>
                            <p>$Message</p>
                            <div style="margin-top: 25px; background-color: #2a2a2a; padding: 15px; border-left: 4px solid $HeaderColor;">$statsHtml</div>
                        </td>
                    </tr></table>
                </div>
            </div>
        </div>
    </body></html>
"@
}

function Test-FileStable {
    Param(
        [Parameter(Mandatory=$true)]
        [PSObject]$Job,
        [int]$StableMinutes = 1
    )
    if (-not (Test-Path -LiteralPath $Job.Path)) { return $false }
    $file = Get-Item -LiteralPath $Job.Path
    $currentSize = $file.Length
    $lastWrite = $file.LastWriteTime
    $timeSinceLastWrite = (Get-Date) - $lastWrite

    if ($currentSize -eq $Job.LastSize -and $timeSinceLastWrite.TotalMinutes -ge $StableMinutes) {
        return $true    
    }
    $Job.LastSize = $currentSize
    return $false
}

function Update-RadarrMovie {
    param(
        [string]$OldPath,
        [string]$NewPath,
        $MovieId = $null
    )
    try {
        $headers = @{"X-Api-Key" = $env:RADARR_API_KEY}
        $oldFolder = Split-Path -Path $OldPath -Parent

        # If we didn't pass the ID, find it the hard way
        if ($null -eq $MovieId -or $MovieId -eq 0) {
            $movies = Invoke-RestMethod -Uri "$($env:RADARR_URL)/api/v3/movie" -Method Get -Headers $headers
            $movie = $movies | Where-Object { $_.path -eq $oldFolder }
            if ($movie) { $MovieId = $movie.id }
        }

        if ($MovieId) {
            # Update path
            $newFolder = Split-Path -Path $NewPath -Parent
            $rootFolder = Split-Path -Path $newFolder -Parent
            $editorBody = @{ movieIds = @($MovieId); rootFolderPath = $rootFolder; moveFiles = $false } | ConvertTo-Json -Depth 2
            Invoke-RestMethod -Uri "$($env:RADARR_URL)/api/v3/movie/editor" -Method Put -Body $editorBody -ContentType "application/json" -Headers $headers | Out-Null

            # Rescan
            $cmdBody = @{ name = "rescanMovie"; movieId = $MovieId } | ConvertTo-Json
            Invoke-RestMethod -Uri "$($env:RADARR_URL)/api/v3/command" -Method Post -Body $cmdBody -ContentType "application/json" -Headers $headers | Out-Null
            Write-DualLog "[Radarr] Updated and Rescanned Movie ID: $MovieId" -Color Green
        }
    } catch { Write-DualLog "Radarr Error: $($_.Exception.Message)" -Color Red }
}

function Invoke-SonarrImport {
    param([string]$FinalFilePath)
    try {
        $headers = @{"X-Api-Key" = $env:SONARR_API_KEY}
        $body = @{ name = "DownloadedEpisodesScan"; path = $FinalFilePath; importMode = "Move" } | ConvertTo-Json
        Invoke-RestMethod -Uri "$($env:SONARR_URL)/api/v3/command" -Method Post -Body $body -ContentType "application/json" -Headers $headers | Out-Null
        Write-DualLog "[Sonarr] Import command sent for: $(Split-Path $FinalFilePath -Leaf)" -Color Green
    } catch { Write-DualLog "Sonarr Import Error: $($_.Exception.Message)" -Color Red }
}