@echo off
REM NB Remote Client launcher
REM Edit the two lines below, then double-click this file to start.

set NB_REMOTE_RELAY=https://render-ylyt.onrender.com
set NB_REMOTE_TOKEN=634bfa728ebe2b3e834bd03e4fb6fba3
set NB_REMOTE_FPS=2
set NB_REMOTE_QUALITY=40

echo Starting NB Remote Client (PowerShell)...
echo Relay: %NB_REMOTE_RELAY%
echo Press Ctrl+C to stop.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nb_client.ps1"
pause
