@echo off
setlocal
if not exist "%~dp0preview\standalone_preview.html" (
    echo Preview file not found: "%~dp0preview\standalone_preview.html"
    pause
    exit /b 1
)
start "" "%~dp0preview\standalone_preview.html"
endlocal
