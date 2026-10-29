@echo off
title 定时提醒助手
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0ScheduledReminder.ps1"
pause
