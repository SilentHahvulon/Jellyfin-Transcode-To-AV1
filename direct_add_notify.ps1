# Load shared configuration and API functions
. "$PSScriptRoot\JellyfinFunctions.ps1"

$script:HistoryLog = Join-Path $global:Config.Paths.LogDirectory "transcode_history.log"

# Define the FINAL folders to watch for direct downloads
$script:DirectWatchFolders = $global:Config.DirectWatchFolders

$script:NotificationQueue = [System.Collections.Concurrent.ConcurrentQueue[PSObject]]::new()
$script:NotificationBatches = @{} # Dictionary to hold batched files
$BatchWaitMinutes = 2 # How many minutes of silence before sending the grouped notification

Get-EventSubscriber | Unregister-Event -ErrorAction SilentlyContinue

# --- BATCHED NOTIFICATION LOGIC ---
function Invoke-BatchedNotification {
    param(
        [Parameter(Mandatory=$true)][array]$Files,
        [Parameter(Mandatory=$true)][string]$Type
    )
    
    # 1. Filter out files that were already transcoded
    $transcodedFiles = if (Test-Path $script:HistoryLog) { Get-Content $script:HistoryLog } else { @() }
    $validFiles = @($Files | Where-Object { $transcodedFiles -notcontains $_ })

    if ($validFiles.Count -eq 0) { return }

    # 2. Fetch data based on the first file in the batch
    $firstFile = $validFiles[0]
    $mediaData = Get-SeerrData -filePath $firstFile -type $Type
    
    # 3. Calculate total size of the batch and format dynamically (MB vs GB)
    $totalSizeBytes = 0
    foreach ($f in $validFiles) { $totalSizeBytes += (Get-Item -LiteralPath $f).Length }
    
    if ($totalSizeBytes -lt 1GB) {
        $formattedSize = "{0:N2} MB" -f ($totalSizeBytes / 1MB)
    } else {
        $formattedSize = "{0:N2} GB" -f ($totalSizeBytes / 1GB)
    }
    
    # 4. Format titles depending on file count
    $count = $validFiles.Count
    if ($count -eq 1) {
        $fileName = Split-Path -Path $firstFile -Leaf
        $displayTitle = if ($mediaData.Title) { $mediaData.Title } else { $fileName }
        $desc = "Direct download complete. Available now in Jellyfin!"
        $emailHeadline = "Ready to Watch!"
        $toastHeader = "Ready to Watch!"
        $toastMsg = "has finished downloading"
        $ntfyBody = "$displayTitle is ready to watch!"
    } else {
        # Try to use the series title from SeerrData, fallback to folder names
        if ($mediaData.Title) { 
            $baseTitle = $mediaData.Title 
        } else { 
            $parentDir = Split-Path -Path $firstFile -Parent
            $parentLeaf = Split-Path -Path $parentDir -Leaf
            
            # If the folder is named like "Season 1", go up one more level for the Show Name
            if ($parentLeaf -match "(?i)^Season\s*\d+") {
                $showName = Split-Path -Path (Split-Path -Path $parentDir -Parent) -Leaf
                $baseTitle = "$showName - $parentLeaf"
            } else {
                $baseTitle = $parentLeaf
            }
        }
        
        $displayTitle = "$baseTitle - $count Episodes Added"
        $desc = "Direct download complete for $count files. Available now in Jellyfin!"
        $emailHeadline = "Multiple Episodes Ready!"
        $toastHeader = "Episodes Ready!"
        $toastMsg = "($count episodes) have finished downloading"
        $ntfyBody = "$count new episodes of $baseTitle are ready to watch!"
    }

    Write-Host "[Direct Addition] Triggering notifications for: $displayTitle" -ForegroundColor Magenta

    try {
        # --- DISCORD ---
        $embedFields = @( @{ name = "Total Size"; value = $formattedSize; inline = $true } )
        if ($mediaData.IsRequested) { $embedFields += @{ name = "Requested By"; value = $mediaData.RequesterName; inline = $true } }

        $successEmbed = @{
            title = "New Arrival: $displayTitle"
            description = $desc
            color = 3447003 # Blue
            fields = $embedFields
            footer = @{ text = "Jellyfin Server" }
        }
        if ($mediaData.PosterUrl) { $successEmbed.image = @{ url = $mediaData.PosterUrl } }

        $discordPayload = @{
            content = if ($mediaData.Mention) { "Hey $($mediaData.Mention), your request is ready to watch!" } else { "" }
            embeds = @($successEmbed)
            username = "Library Updates"
        }
        Send-DiscordWebhook -WebhookUrl $env:DISCORD_REQUEST_WH -Payload $discordPayload

        # --- NTFY ---
        Send-NtfyNotification -NtfyUrl $env:NTFY_URL -Token $env:NTFY_TOKEN -Title "New Media Added" -Message $ntfyBody -Tags "popcorn"

        # --- EMAIL & TOAST (If Requested) ---
        if ($mediaData.IsRequested -and $global:Config.Users.ContainsKey($mediaData.RequesterName)) {
            $userInfo = $global:Config.Users[$mediaData.RequesterName]

            if (-not [string]::IsNullOrWhiteSpace($userInfo.Email)) {
                $stats = [ordered]@{ "Total Size" = $formattedSize }
                $emailBody = Build-MediaEmailHtml -Headline $emailHeadline -HeaderColor "#5865F2" -UserName $userInfo.Name -Message "Your request for <b style='color: #ffffff;'>$displayTitle</b> is successfully downloaded and available in Jellyfin." -Stats $stats -PosterUrl $mediaData.PosterUrl
                Send-MediaEmail -toEmail $userInfo.Email -subject "$emailHeadline $displayTitle" -body $emailBody
            }

            if ($count -eq 1) { 
                $successToast = "Hey $($userInfo.Name)! Your request for '$displayTitle' has finished downloading. Enjoy!" 
            } else {
                $successToast = "Hey $($userInfo.Name)! Your request for '$baseTitle' $toastMsg. Enjoy!"
            }
            
            $targetUsers = if ($null -ne $userInfo.JellyfinUsers) { $userInfo.JellyfinUsers } else { @($mediaData.RequesterName) }
            Send-JellyfinToast -User $targetUsers -RequesterName $userInfo.Name -Header $toastHeader -Message $successToast
        }
    } catch { Write-Host "Error sending batched notifications: $_" -ForegroundColor Red }
}

# --- EVENT ACTION (ADD TO RAW QUEUE) ---
$WatcherAction = {
    $path = $Event.SourceEventArgs.FullPath
    $queue = $Event.MessageData.Queue
    $type = $Event.MessageData.Type

    if ([System.IO.Path]::GetExtension($path) -match '\.(mkv|mp4|avi)$') {
        $exists = $queue | Where-Object { $_.Path -eq $path }
        if (-not $exists) {
            Write-Host "[Detected] New file incoming. Waiting for transfer to complete: $(Split-Path $path -Leaf)" -ForegroundColor Cyan
            $queue.Enqueue([pscustomobject]@{ Path = $path; Type = $type; LastSize = -1 })
        }
    }
}

# --- QUEUE WORKER (WITH BATCHING) ---
function Start-NotificationWorker {
    while ($true) {
        $job = $null
        
        # 1. Process the raw queue of incoming files
        if ($script:NotificationQueue.TryDequeue([ref]$job)) {
            if (Test-FileStable -Job $job -StableMinutes 1) {
                # File is fully transferred. Group it by its parent folder.
                $parentDir = Split-Path -Path $job.Path -Parent
                
                if (-not $script:NotificationBatches.ContainsKey($parentDir)) {
                    $script:NotificationBatches[$parentDir] = @{
                        Files = [System.Collections.Generic.List[string]]::new()
                        LastAdded = (Get-Date)
                        Type = $job.Type
                    }
                }
                
                # Add to batch and reset the timeout clock
                if ($script:NotificationBatches[$parentDir].Files -notcontains $job.Path) {
                    $script:NotificationBatches[$parentDir].Files.Add($job.Path)
                }
                $script:NotificationBatches[$parentDir].LastAdded = (Get-Date)
                Write-Host "[Batched] $(Split-Path $job.Path -Leaf) queued for notification." -ForegroundColor DarkCyan
                
            } else {
                # Still copying, send it back to the end of the queue
                $script:NotificationQueue.Enqueue($job)
            }
        }

        # 2. Check for batches that have finished cooling down
        $now = Get-Date
        $keysToRemove = @()
        
        # Iterate over a static list of keys to prevent collection-modified errors
        $keys = @($script:NotificationBatches.Keys)
        foreach ($key in $keys) {
            $batch = $script:NotificationBatches[$key]
            
            if (($now - $batch.LastAdded).TotalMinutes -ge $BatchWaitMinutes) {
                # No new files added to this folder in X minutes. Send the notification!
                Invoke-BatchedNotification -Files $batch.Files -Type $batch.Type
                $keysToRemove += $key
            }
        }

        # Clean up processed batches
        foreach ($key in $keysToRemove) {
            $script:NotificationBatches.Remove($key)
        }

        if ($keysToRemove.Count -gt 0) {
            Write-Host "`nDirect Notification Service running... Press Ctrl+C to stop." -ForegroundColor Magenta
        }

        Start-Sleep -Seconds 2
    }
}

# --- STARTUP & WATCHERS ---
$script:Watchers = New-Object System.Collections.Generic.List[System.IO.FileSystemWatcher]

foreach ($item in $script:DirectWatchFolders) {
    if (Test-Path $item.Watch) {
        Write-Host "[Startup] Monitoring Direct Folder: $($item.Watch)" -ForegroundColor Gray
        $watcher = New-Object System.IO.FileSystemWatcher -ArgumentList $item.Watch
        $watcher.IncludeSubdirectories = $true
        $watcher.InternalBufferSize = 65536
        $watcher.EnableRaisingEvents = $true
        $script:Watchers.Add($watcher)

        $eventData = @{ Type = $item.Type; Queue = $script:NotificationQueue }
        Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $WatcherAction -MessageData $eventData | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName "Renamed" -Action $WatcherAction -MessageData $eventData | Out-Null
    }
}

Write-Host "`nDirect Notification Service running... Press Ctrl+C to stop." -ForegroundColor Magenta
try { Start-NotificationWorker } finally {
    Get-EventSubscriber | Unregister-Event
    $script:Watchers | ForEach-Object { $_.Dispose() }
}