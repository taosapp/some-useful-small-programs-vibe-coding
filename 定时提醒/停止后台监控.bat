@echo off
title Í£Ö¹ºóÌ¨¼à¿Ø
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ScheduledReminder.ps1" -StopWatcher
pause
