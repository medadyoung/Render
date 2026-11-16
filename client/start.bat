@echo off
title NB Remote Client
cd /d "%~dp0"

set NB_REMOTE_RELAY=https://render-ylyt.onrender.com
set NB_REMOTE_TOKEN=634bfa728ebe2b3e834bd03e4fb6fba3
set NB_REMOTE_FPS=2
set NB_REMOTE_QUALITY=40

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0nb_client.ps1"
pause
