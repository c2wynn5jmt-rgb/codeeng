@echo off
REM Startet die GUI-Version (Update-Bios-GUI.ps1) mit Admin-Rechten, ohne
REM die systemweite Execution Policy zu aendern (Bypass gilt nur fuer
REM diesen einen Aufruf). Doppelklick reicht - UAC fragt nach Admin.

set SCRIPT_DIR=%~dp0
set SCRIPT_PATH=%SCRIPT_DIR%Update-Bios-GUI.ps1

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%SCRIPT_PATH%\"' -Verb RunAs"
