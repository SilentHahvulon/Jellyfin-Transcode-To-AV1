. "$PSScriptRoot\JellyfinFunctions.ps1"

$script:cleanLog = Join-Path $global:Config.Paths.LogDirectory "dashboard_clean.log"
$script:logDir = $global:Config.Paths.LogDirectory

# --- CONFIGURATION ---
$script:batchFile = $global:Config.Paths.BatchScript

$script:folderMap = $global:Config.WatchFolders

# --- MODERN CONCURRENT QUEUES ---
$script:PriorityQueue = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()
$script:StandardQueue = [System.Collections.Concurrent.ConcurrentQueue[psobject]]::new()

Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue

function Write-IdleStatus {
    Write-DualLog -Message "`nMonitoring folders... Press Ctrl+C to stop." -Color Magenta
}

# Override Write-DualLog to automatically include the log file
$originalWriteDualLog = (Get-Command Write-DualLog).ScriptBlock
function Write-DualLog {
    param([string]$Message, [ConsoleColor]$Color = 'Gray')
    & $originalWriteDualLog -Message $Message -Color $Color -LogFile $script:cleanLog
}

# --- MAIN PROCESSING LOGIC ---
function Invoke-Transcode($filePath, $watchBase, $processedBase, $type) {
    if (-not (Test-Path -LiteralPath $filePath)) { return }
    $relativePath = $filePath.Replace($watchBase, "").TrimStart("\")
    $destination = Join-Path -Path $processedBase -ChildPath $relativePath
    $destDir = Split-Path -Path $destination -Parent
    $fileName = Split-Path -Path $filePath -Leaf
    $extension = [System.IO.Path]::GetExtension($filePath)

    if ($extension -match '\.(mkv|mp4|avi)$') {
        $fileInfo = Get-Item -LiteralPath $filePath
        $sizeGB = "{0:N2} GB" -f ($fileInfo.Length / 1GB)

        $mediaData = Get-SeerrData -filePath $filePath -type $type
        $displayTitle = if ($mediaData.Title) { $mediaData.Title } else { $fileName }
        
        Write-DualLog "[Action] Starting transcode for: $displayTitle ($sizeGB)" -Color Yellow
        
        # --- START NOTIFICATIONS ---
        try {
            $embedFields = @( @{ name = "Original Size"; value = $sizeGB; inline = $true } )
            if ($mediaData.IsRequested) {
                $embedFields += @{ name = "Requested By"; value = $mediaData.RequesterName; inline = $true }
            }

            $startEmbed = @{
                title = "Transcoding: $displayTitle"
                description = "Attempting AV1 conversion to reduce file size."
                color = 16705372 # Yellow
                fields = $embedFields
                footer = @{ text = $env:JELLYFIN_SERVER_NAME }
            }
            if ($mediaData.PosterUrl) { $startEmbed.image = @{ url = $mediaData.PosterUrl } }

            $discordPayload = @{
                content = if ($mediaData.Mention) { "Hey $($mediaData.Mention), your request is downloaded and we're starting the transcode process!" } else { "" }
                embeds = @($startEmbed)
                username = "Library Updates"
            }

            Send-DiscordWebhook -WebhookUrl $env:DISCORD_REQUEST_WH -Payload $discordPayload
            Send-NtfyNotification -NtfyUrl $env:NTFY_URL -Token $env:NTFY_TOKEN -Title "Transcode Started" -Message "$displayTitle ($sizeGB) downloaded and processing."
        
            if ($mediaData.IsRequested -and $global:Config.Users.ContainsKey($mediaData.RequesterName)) {
                $userInfo = $global:Config.Users[$mediaData.RequesterName]

                if (-not [string]::IsNullOrWhiteSpace($userInfo.Email)) {
                    $targetEmail = $userInfo.Email
                    $recipientName = $userInfo.Name

                    $stats = [ordered]@{
                        "Original Size" = $sizeGB
                    }

                    $emailBody = Build-MediaEmailHtml `
                        -Headline "Transcode Started" `
                        -HeaderColor "#fee75c" `
                        -TextColor "#121212" `
                        -UserName $recipientName `
                        -Message "Your request for <b style='color: #ffffff;'>$displayTitle</b> has been downloaded. The AV1 transcoding process to save space is beginning now." `
                        -Stats $stats `
                        -PosterUrl $mediaData.PosterUrl

                    Send-MediaEmail -toEmail $targetEmail -subject "Transcode Started: $displayTitle" -body $emailBody
                }

                $queueMessage = "Hey $($userInfo.Name)! Your request for '$displayTitle' has been downloaded and is now being transcoded to AV1 to attempt to save space."
                $targetUsers = if ($null -ne $userInfo.JellyfinUsers) { $userInfo.JellyfinUsers } else { @($mediaData.RequesterName) }

                Send-JellyfinToast -User $targetUsers -RequesterName $userInfo.Name -Header "Transcode Started" -Message $queueMessage
            }

        } catch {}

        Start-Process -FilePath $script:batchFile -ArgumentList "`"$filePath`"" -NoNewWindow -Wait 2>&1 | Tee-Object -FilePath $script:cleanLog -Append

        $errorLogPath = Join-Path $global:Config.Paths.FfmpegTemp "${fileName}_transcode.log"
        $hasErrors = $false
        if (Test-Path $errorLogPath) {
            $log = Get-Content $errorLogPath
            if ($log -match "Failed|Critical|Invalid|Target quality not met|too large|exit code -12") { $hasErrors = $true }
        }

        if (-not $hasErrors) {
            if (-not (Test-Path $destDir)) { New-Item -Path $destDir -ItemType Directory -Force | Out-Null }
            $originalPath = $filePath

            Write-DualLog "[Transfer] Moving $fileName to HDD... This may take a moment depending on file size." -Color Cyan

            # --- SELF-CLEANING LOG FLAG ---
            $logPath = Join-Path $global:Config.Paths.LogDirectory "transcode_history.log"
            $logHistory = if (Test-Path $logPath) { Get-Content $logPath } else { @() }
            if ($logHistory.Count -gt 100) {
                $logHistory | Select-Object -Last 50 | Set-Content -Path $logPath
            }
            Add-Content -Path $logPath -Value $destination

            Move-Item -LiteralPath $filePath -Destination $destination -Force
            
            $sourceDir = Split-Path -Path $filePath -Parent
            if ($sourceDir.TrimEnd('\') -ne $watchBase.TrimEnd('\')) {
                Get-ChildItem -Path $sourceDir -Exclude $fileName | ForEach-Object {
                    Move-Item -LiteralPath $_.FullName -Destination $destDir -Force
                }
                if ((Get-ChildItem -Path $sourceDir).Count -eq 0) { Remove-Item -Path $sourceDir -Force }
            }

            if ($type -eq "Sonarr") { Invoke-SonarrImport -FinalFilePath $destination }
            elseif ($type -eq "Radarr") { Update-RadarrMovie -OldPath $originalPath -NewPath $destination -MovieId $mediaData.ArrId }

            # --- SUCCESS NOTIFICATIONS ---
            $newFileInfo = Get-Item -LiteralPath $destination
            $newSizeGB = "{0:N2} GB" -f ($newFileInfo.Length / 1GB)

            $savedBytes = $fileInfo.Length - $newFileInfo.Length
            $savedGB = "{0:N2} GB" -f ($savedBytes / 1GB)
            $percentSaved = [math]::Round(($savedBytes / $fileInfo.Length) * 100, 1)

            Write-DualLog "Successfully processed and moved: $fileName to $(Split-Path $destination -Parent)" -Color Green
            
            try {
                $successFields = @(
                    @{ name = "Original Size"; value = $sizeGB; inline = $true },
                    @{ name = "New AV1 Size"; value = $newSizeGB; inline = $true },
                    @{ name = "Space Saved"; value = "$savedGB ($percentSaved%)"; inline = $true }
                )

                $successEmbed = @{
                    title = "Completed: $displayTitle"
                    description = "Transcode finished successfully and file is now available in Jellyfin!"
                    color = 5763719 # Green
                    fields = $successFields
                    footer = @{ text = $env:JELLYFIN_SERVER_NAME }
                }
                if ($mediaData.PosterUrl) { $successEmbed.image = @{ url = $mediaData.PosterUrl } }
                if ($mediaData.IsRequested) {
                    $successEmbed.fields += @( @{ name = "Requested By"; value = $mediaData.RequesterName; inline = $true } )
                }

                $successPayload = @{
                    content = if ($mediaData.Mention) { "Hey $($mediaData.Mention), your request is ready to watch!" } else { "" }
                    embeds = @($successEmbed)
                    username = "Library Updates"
                }

                Send-DiscordWebhook -WebhookUrl $env:DISCORD_REQUEST_WH -Payload $successPayload
                Send-NtfyNotification -NtfyUrl $env:NTFY_URL -Token $env:NTFY_TOKEN -Title "Transcode Complete" -Message "$displayTitle is ready to watch! Saved $savedGB ($percentSaved%)." -Tags "white_check_mark"
            
                if ($mediaData.IsRequested -and $global:Config.Users.ContainsKey($mediaData.RequesterName)) {
                    $userInfo = $global:Config.Users[$mediaData.RequesterName]

                    if (-not [string]::IsNullOrWhiteSpace($userInfo.Email)) {
                        $targetEmail = $userInfo.Email
                        $recipientName = $userInfo.Name

                        $stats = [ordered]@{
                            "Original Size" = $sizeGB
                            "New AV1 Size" = $newSizeGB
                            "Space Saved" = "$savedGB ($percentSaved%)"
                        }

                        $emailBody = Build-MediaEmailHtml `
                            -Headline "Ready to Watch!" `
                            -HeaderColor "#57f287" `
                            -TextColor "#121212" `
                            -UserName $recipientName `
                            -Message "Your request for <b style='color: #ffffff;'>$displayTitle</b> has finished transcoding and is now available in Jellyfin. Enjoy watching!" `
                            -Stats $stats `
                            -PosterUrl $mediaData.PosterUrl

                        Send-MediaEmail -toEmail $targetEmail -subject "Ready to Watch: $displayTitle" -body $emailBody
                    }

                    $successToast = "Hey $($userInfo.Name)! Your request for '$displayTitle' has finished transcoding and is now available in Jellyfin. Enjoy watching!"
                    $targetUsers = if ($null -ne $userInfo.JellyfinUsers) { $userInfo.JellyfinUsers } else { @($mediaData.RequesterName) }

                    Send-JellyfinToast -User $targetUsers -RequesterName $userInfo.Name -Header "Ready to Watch!" -Message $successToast
                }
            } catch {}
        }
    }
}

# --- EVENT ACTION ---
$WatcherAction = {
    $path = $Event.SourceEventArgs.FullPath
    
    $itemData = $Event.MessageData.Config
    $PriorityQ = $Event.MessageData.PriorityQ
    $StandardQ = $Event.MessageData.StandardQ
    
    if ([System.IO.Path]::GetExtension($path) -match '\.(mkv|mp4|avi)$') {
        $isPriority = $itemData.IsPriority -or ($path -match "(?i)\[priority\]")
        if ($isPriority) {
            $targetQueue = $PriorityQ
        } else {
            $targetQueue = $StandardQ
        }

        $exists = $targetQueue | Where-Object { $_.Path -eq $path }
        if (-not $exists) {
            try {
                $fileInfo = Get-Item -LiteralPath $path -ErrorAction Stop
                $sizeGB = "{0:N2} GB" -f ($fileInfo.Length / 1GB)
            } catch { $sizeGB = "Calculating..." }

            $queueName = if ($isPriority) { "VIP QUEUE" } else { "STANDARD QUEUE" }
            Write-DualLog "[Detected] New file added to $queueName : $(Split-Path $path -Leaf) ($sizeGB)" -Color Cyan
            
            $targetQueue.Enqueue([pscustomobject]@{ Path = $path; Watch = $itemData.Watch; Processed = $itemData.Processed; Type = $itemData.Type; LastSize = -1 })
        }
    }
}

# --- QUEUE WORKER ---
function Start-QueueWorker {
    $stopFlagPath = Join-Path $global:Config.Paths.LogDirectory "stop_transcode.flag"

    while ($true) {
        if (Test-Path $stopFlagPath) {
            Write-DualLog "`n[Shutdown] Stop flag detected! Script will exit cleanly now." -Color Red
            Remove-Item -LiteralPath $stopFlagPath -Force 
            
            Write-DualLog "[Logging] Archiving dashboard log..." -Color Cyan

            if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Path $script:logDir | Out-Null }
            
            $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
            $permanentLog = Join-Path -Path $script:logDir -ChildPath "Graceful_Shutdown_$timestamp.txt"
            
            if (Test-Path $script:cleanLog) {
                Move-Item -LiteralPath $script:cleanLog -Destination $permanentLog -Force
                Write-DualLog "[Logging] Full history saved to: $permanentLog" -Color Green
            }
            
            break 
        }

        $job = $null
        
        if ($script:PriorityQueue.TryDequeue([ref]$job)) {
            if (Test-FileStable -Job $job -StableMinutes 1) {
                Write-DualLog "`n[VIP] Processing Priority File..." -Color DarkYellow
                Invoke-Transcode -filePath $job.Path -watchBase $job.Watch -processedBase $job.Processed -type $job.Type
                Write-IdleStatus
            } else {
                $script:PriorityQueue.Enqueue($job) 
                Start-Sleep -Seconds 5
            }
        } 
        elseif ($script:StandardQueue.TryDequeue([ref]$job)) {
            if (Test-FileStable -Job $job -StableMinutes 1) {
                Invoke-Transcode -filePath $job.Path -watchBase $job.Watch -processedBase $job.Processed -type $job.Type
                Write-IdleStatus
            } else {
                $script:StandardQueue.Enqueue($job) 
                Start-Sleep -Seconds 5
            }
        } 
        else {
             Start-Sleep -Seconds 2 
        }
    }
}

# --- STARTUP & WATCHERS ---
$script:Watchers = New-Object System.Collections.Generic.List[System.IO.FileSystemWatcher]
$globalStartupFiles = @() 

foreach ($item in $script:folderMap) {
    if (Test-Path $item.Watch) {
        Write-DualLog "[Startup] Scanning: $($item.Watch)" -Color Gray
        
        $foundFiles = Get-ChildItem -Path $item.Watch -File -Recurse | Where-Object { $_.Extension -match '\.(mkv|mp4|avi)$' }
        foreach ($file in $foundFiles) {
            $globalStartupFiles += [pscustomobject]@{
                FileInfo = $file
                Config = $item
            }
        }

        $watcher = New-Object System.IO.FileSystemWatcher -ArgumentList $item.Watch
        $watcher.IncludeSubdirectories = $true
        $watcher.InternalBufferSize = 65536
        $watcher.EnableRaisingEvents = $true
        $script:Watchers.Add($watcher)

        $eventData = @{ Config = $item; PriorityQ = $script:PriorityQueue; StandardQ = $script:StandardQueue }

        Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $WatcherAction -MessageData $eventData | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName "Renamed" -Action $WatcherAction -MessageData $eventData | Out-Null
    }
}

if ($globalStartupFiles.Count -gt 0) {
    Write-DualLog "`n[Startup] Sorting $($globalStartupFiles.Count) existing files globally by age..." -Color Gray
    
    $sortedFiles = $globalStartupFiles | Sort-Object { $_.FileInfo.LastWriteTime }

    foreach ($item in $sortedFiles) {
        $file = $item.FileInfo
        $config = $item.Config
        $sizeGB = "{0:N2} GB" -f ($file.Length / 1GB)
        
        $isPriority = $config.IsPriority -or ($file.Name -match "(?i)\[priority\]")
        if ($isPriority) {
            $targetQueue = $script:PriorityQueue
        } else {
            $targetQueue = $script:StandardQueue
        }
        $queueTag = if ($isPriority) { "[VIP]" } else { "[Standard]" }
        
        Write-DualLog "[Found] $queueTag Queuing: $($file.Name) ($sizeGB)" -Color Cyan
        $targetQueue.Enqueue([pscustomobject]@{ Path = $file.FullName; Watch = $config.Watch; Processed = $config.Processed; Type = $config.Type; LastSize = -1 })
    }
}

Write-IdleStatus
try { Start-QueueWorker } finally {
    Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue
    $script:Watchers | ForEach-Object { $_.Dispose() }
}