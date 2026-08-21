@echo off
REM Wie Run-Update-Bios.bat, aber fest mit -DetectOnly - installiert nichts,
REM zeigt nur installierte und neueste BIOS-Version an. Fuer den ersten Test.

set SCRIPT_DIR=%~dp0
set SCRIPT_PATH=%SCRIPT_DIR%Update-Bios.ps1

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%SCRIPT_PATH%\" -DetectOnly' -Verb RunAs"
