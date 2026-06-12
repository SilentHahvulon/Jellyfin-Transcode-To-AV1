# Jellyfin Media Automation & Transcoding

This repository contains a set of PowerShell and Batch scripts designed to automate media processing for a Jellyfin server. It automatically watches directories for new media, transcodes them to the highly efficient AV1 format using `ab-av1` and `ffmpeg`, and sends out notifications to users via Discord, NTFY, Email, and Jellyfin.

It integrates seamlessly with the *arr stack (Radarr, Sonarr) and Seerr to fetch metadata and notify the specific user who requested the media.

## Features

- **Automated AV1 Transcoding**: Watches specified directories for new `.mkv`, `.mp4`, or `.avi` files and automatically transcodes them to AV1 to save space.
- **Direct Add Notifications**: Watches direct download folders for files that don't need transcoding, batching episode notifications together to avoid spam.
- **Smart Queueing**: Supports VIP/Priority queues so important media gets transcoded first.
- **Rich Notifications**:
  - **Discord**: Sends beautiful embed messages with posters, file size savings, and mentions the requester.
  - **Email**: Sends styled HTML emails with media statistics to the user who requested the content.
  - **NTFY**: Pushes notifications to NTFY topics.
  - **Jellyfin Toasts**: Sends real-time pop-up notifications to active Jellyfin sessions for the requesting user.
- **Arr Stack Integration**: Automatically updates Radarr and Sonarr paths after moving transcoded files.

## Prerequisites

To use these scripts, you will need the following installed and available in your system's PATH:

- **Windows PowerShell** (Version 5.1 or newer recommended)
- **[FFmpeg](https://ffmpeg.org/)**
- **[ab-av1](https://github.com/alexheretic/ab-av1)**
- **Radarr, Sonarr, and Seerr** (for metadata and request tracking)
- **Jellyfin** (for in-app notifications)

## Setup

1. **Clone the repository:**
   ```bash
   git clone https://github.com/your-repo/jellyfin-media-automation.git
   cd jellyfin-media-automation
   ```

2. **Configure Environment Variables:**
   - Copy `.env.example` to `.env`.
   - Fill in your API keys, URLs, SMTP settings, and Webhooks.
   ```powershell
   cp .env.example .env
   ```

3. **Configure JSON Settings:**
   - Copy `config.example.json` to `config.json`.
   - Edit `config.json` to match your directory structures and user mappings.
   - **Users**: Maps Seerr requester names to their Jellyfin usernames, Email, and Discord ID.
   - **WatchFolders**: Folders to monitor for *transcoding*. Moves completed files to the `Processed` path.
   - **DirectWatchFolders**: Folders to monitor for *direct additions* (no transcoding, just notifications).
   - **Paths**: Paths for logs, the temporary FFmpeg directory, and the location of the `ffmpeg_convert_av1.bat` script.

## Usage

### 1. Transcoding Workflow (`auto_add_to_ab-av1.ps1`)
Run this script to monitor your "Unprocessed" folders. When a new file is completely copied, the script will:
- Add it to a Priority or Standard queue.
- Notify the requester that the transcode has started.
- Call `ffmpeg_convert_av1.bat` to encode the file to AV1.
- Move the finished AV1 file to your final media directory.
- Trigger Sonarr/Radarr to scan the new file.
- Send a "Ready to Watch" notification.

```powershell
.\auto_add_to_ab-av1.ps1
```

### 2. Direct Add Workflow (`direct_add_notify.ps1`)
Run this script to monitor folders where media is added directly without needing to be transcoded (e.g., pre-encoded AV1 downloads).
- It waits for the file to finish copying.
- Batches notifications (e.g., groups multiple episodes of a season together).
- Sends a "Ready to Watch" notification.

```powershell
.\direct_add_notify.ps1
```

### 3. Manual Transcoding (`ffmpeg_convert_av1.bat`)
You can also use the batch script standalone by dragging and dropping a video file onto it, or passing the file path as an argument.
- It prompts for Quality (XPSNR target), Preset, and Parallelism level.
- If left unattended, it will auto-select default values (High Quality, Preset 1, Parallelism 6) after 120 seconds.

## Architecture

- **`JellyfinFunctions.ps1`**: The core library handling API calls (Radarr, Sonarr, Seerr, Jellyfin), notifications (Email, Discord, Ntfy), and environment loading.
- **`auto_add_to_ab-av1.ps1`**: The file system watcher for transcoding. Manages concurrent queues and triggers the batch script.
- **`direct_add_notify.ps1`**: The file system watcher for direct media. Handles batching and triggers notifications.
- **`ffmpeg_convert_av1.bat`**: The wrapper around `ab-av1` and `ffmpeg` that performs the actual AV1 encode.

## Note

I am very new to coding and I built this project mainly for myself because I wasn't completely satisfied with how tools like Tdarr function. I decided to upload it here in case someone else finds it useful or can learn from it.

*AI Disclosure: I used Google Gemini as a collaboration partner throughout the writing and troubleshooting of this repository. Jules (an AI agent) was also involved in writing this README file.*
