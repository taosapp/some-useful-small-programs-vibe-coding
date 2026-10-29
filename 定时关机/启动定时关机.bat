@echo off
title 定时关机助手
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ScheduledShutdown.ps1"
pause
