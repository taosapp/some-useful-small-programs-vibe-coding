@echo off
title 取消定时关机
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ScheduledShutdown.ps1" -Cancel
pause
