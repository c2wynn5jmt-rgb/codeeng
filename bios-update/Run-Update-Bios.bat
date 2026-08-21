@echo off
REM Startet Update-Bios.ps1 mit Admin-Rechten, ohne die systemweite
REM Execution Policy zu aendern (Bypass gilt nur fuer diesen einen Aufruf).
REM Doppelklick reicht - UAC fragt automatisch nach Admin-Bestaetigung.

set SCRIPT_DIR=%~dp0
set SCRIPT_PATH=%SCRIPT_DIR%Update-Bios.ps1

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -NoExit -ExecutionPolicy Bypass -File \"%SCRIPT_PATH%\" %*' -Verb RunAs"
