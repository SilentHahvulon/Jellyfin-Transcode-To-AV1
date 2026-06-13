@echo off
setlocal enabledelayedexpansion

:: Ensure local bin is in PATH for dependencies
set "PATH=%~dp0bin;%PATH%"

cd "ffmpeg\Temp"

:: 1. Define your temporary workspace
set "TEMP_DIR=%~dp0Temp"

:: 2. Get input from Drag-and-Drop or Prompt
if "%~1"=="" (
    set /p "input=Drag and drop file here: "
) else (
    set "input=%~1"
)

:: 3. Clean quotes and extract file information
set "input=!input:"=!"
for %%F in ("!input!") do (
    set "origDir=%%~dpF"
    set "fileName=%%~nF"
    set "origExt=%%~xF"
)

:: 4. Define temporary and final paths
set "tempOutput=!TEMP_DIR!\!fileName!_AV1.mkv"
set "finalOutput=!origDir!!fileName!_AV1.mkv"

:: 5. DETECT AVERAGE FRAMERATE (Prevents SVT-AV1 errors)
echo Probing framerate...
for /f "usebackq tokens=*" %%F in (`ffprobe -v error -analyzeduration=20000000 -probesize 50M -select_streams v:0 -show_entries stream^=r_frame_rate -of default^=noprint_wrappers^=1:nokey^=1 "!input!"`) do set "avgFPS=%%F"
echo Detected Framerate: !avgFPS!

for /f "tokens=*" %%L in ('ffprobe -v error -select_streams v:0 -show_entries stream^=codec_name -of default^=noprint_wrappers^=1^:nokey^=1 "!input!"') do set "CODEC=%%L"

echo Detected Codec: "!CODEC!"

:: 1. Reset variables
set "DYNAMIC_VFILTER=crop=floor(iw/8)*8:floor(ih/8)*8"
:: Removed single quotes from path to avoid Windows environment variable issues


echo ----------------------------------------------------
echo Select Quality Target:
echo ----------------------------------------------------
echo [F]ast (XPSNR 40) - Smaller file size
echo [H]igh Quality (XPSNR 43) - Visually transparent + extra to compensate for inflated value from credits
choice /c FH /t 120 /d H

if %ERRORLEVEL% EQU 1 (
    set "targetXPSNR=40"
    set "qualityLevel=Fast"
)
if %ERRORLEVEL% EQU 2 (
    set "targetXPSNR=43"
    set "qualityLevel=High Quality"
)



echo ----------------------------------------------------
echo Select preset. Lower presets are more efficient but take longer.
echo ----------------------------------------------------
echo [1, 2, 3] Slow (Smallest File Size, Longest Time)
echo [4, 5, 6] Balanced (Balanced File Size and Time)
echo [7, 8, 9] Fast (Largest File Size, Shortest Time)
choice /c 123456789 /t 120 /d 4 /n /m "Choose a preset (1-9): "

set "preset=!ERRORLEVEL!"

echo ----------------------------------------------------
echo Select Parallelism level. Higher is faster, but uses more CPU and Memory resources.
echo ----------------------------------------------------
echo [1, 2] Low Parallelism (Less CPU/RAM, Longer Time)
echo [3, 4] Balanced Parallelism (Balanced CPU/RAM and Time)
echo [5, 6] High Parallelism (Very High Resource Usage, Shorter Time [do not select 6 if you are using PC])
choice /c 123456 /t 120 /d 4 /n /m "Choose a parallelism level (1-6): "

set "parallelism=!ERRORLEVEL!"

if !parallelism! LEQ 2 (
    set "parallelismTier=Low"
) else if !parallelism! LEQ 4 (
    set "parallelismTier=Balanced"
) else (
    set "parallelismTier=High"
)

set "COMBINED_LOG=!TEMP_DIR!\!fileName!_transcode.log"



echo. >> "!COMBINED_LOG!"
echo ==================================================== >> "!COMBINED_LOG!"
echo FINAL ENCODE STARTING >> "!COMBINED_LOG!"
echo ==================================================== >> "!COMBINED_LOG!"
echo. >> "!COMBINED_LOG!"

echo ----------------------------------------------------
echo Targeting an XPSNR of !targetXPSNR! at a preset of !preset! with !parallelismTier! parallelism.
echo Encoding "!fileName!!origExt!" with selected settings to Temp...
echo ----------------------------------------------------

set "FFREPORT=level=40:file='!COMBINED_LOG!'"

cmd /c "exit 0"




:: Run ab-av1
ab-av1 auto-encode ^
    --min-crf 10 ^
    --max-crf 63 ^
    --thorough ^
    --sample-every 10m ^
    --min-samples 30 ^
    --min-xpsnr "!targetXPSNR!" ^
    --xpsnr-pix-format yuv420p ^
    -v ^
    -vv ^
    --enc "v=40" ^
    --enc "hide_banner" ^
    -i "!input!" ^
    -o "!tempOutput!" ^
    --preset "!preset!" ^
    --svt "tune=0" ^
    --svt "lp='!parallelism!'" ^
    --svt "lookahead=40" ^
    --acodec libopus ^
    --enc "b:a=448k" ^
    --enc "af=aformat=channel_layouts=7.1|5.1|stereo" ^
    --enc "mapping_family=-1" ^
    --enc "sn" 
    
    


if %ERRORLEVEL% EQU 0 (
    echo.
    echo ----------------------------------------------------
    echo STEP 2: Success! Moving to: "!origDir!"
    echo ----------------------------------------------------
    
    move /y "!tempOutput!" "!finalOutput!"
    
    if %ERRORLEVEL% EQU 0 (
        echo.
        echo ----------------------------------------------------
        echo STEP 3: Finalizing. Determining what to do with the original file...
        echo ----------------------------------------------------
        choice /t 120 /d Y /M "Transcode Complete. Do you want to delete the original file"
        if !ERRORLEVEL! EQU 1 (
            del /F /Q "!input!"
            echo Original file "!fileName!!origExt!" has been removed.
        )
        choice /t 120 /d N /M "Do you want to delete the transcode log"
        if !ERRORLEVEL! EQU 1 (
            del /F /Q "!TEMP_DIR!\!fileName!_transcode.log"
            echo Transcode log has been removed.
        )
        ren "!finalOutput!" "!fileName!!origExt!"

    ) else (
        echo ERROR: Could not move the file from Temp to Source. Original kept.
    )
    
    
) else (
    echo.
    echo ----------------------------------------------------
    echo ERROR: Transcode failed. Check log: "!TEMP_DIR!\!fileName!_transcode.log"
    echo ----------------------------------------------------
)
