#Requires -Version 5.1

<#
Baut eine eigenständige BIOS-Update.exe aus Update-Bios-GUI.ps1 +
BiosUpdateCore.ps1. Der Core-Code wird als Base64-Text in eine
zusammengeführte Datei eingebettet (nicht als separate .ps1 danebengelegt),
damit die fertige exe wirklich für sich allein läuft - nichts weiter
kopieren, kein Execution-Policy-Ärger mehr (kompilierte exes unterliegen
nicht der PowerShell-Skript-Policy), kein .bat-Umweg mehr nötig
(-requireAdmin sorgt selbst für die UAC-Abfrage).

Einmalig auf einem Windows-Rechner mit Internetzugang ausführen (installiert
bei Bedarf automatisch das ps2exe-Modul aus der PowerShell Gallery). Danach
liegt BIOS-Update.exe im selben Ordner - diese eine Datei ist alles, was
zum Verteilen/Weitergeben gebraucht wird.

    .\Build-Exe.ps1
#>

[CmdletBinding()]
param(
    [string]$OutputExe = (Join-Path $PSScriptRoot 'BIOS-Update.exe')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'ps2exe-Modul nicht gefunden, installiere aus PSGallery...'
    Install-Module -Name ps2exe -Scope CurrentUser -Force
}
Import-Module ps2exe

$corePath = Join-Path $PSScriptRoot 'BiosUpdateCore.ps1'
$guiPath = Join-Path $PSScriptRoot 'Update-Bios-GUI.ps1'
$iconPath = Join-Path $PSScriptRoot 'bios-update.ico'
$combinedPath = Join-Path $PSScriptRoot 'Update-Bios-GUI.Combined.ps1'

foreach ($p in @($corePath, $guiPath, $iconPath)) {
    if (-not (Test-Path $p)) { throw "Nicht gefunden: $p" }
}

$coreText = Get-Content -Path $corePath -Raw
$guiText = Get-Content -Path $guiPath -Raw

$coreBase64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($coreText))
$embedAssignment = "`$script:EmbeddedCoreScriptText = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$coreBase64'))"

# Muss NACH den #Requires-Zeilen eingefügt werden (die müssen als erste
# Statements im Skript stehen), deshalb gezielt direkt danach einschieben
# statt einfach vorne anzuhängen.
$replacement = '$1' + "`r`n`r`n" + $embedAssignment
$guiTextWithEmbed = $guiText -replace '(?m)(^#Requires -RunAsAdministrator\s*$)', $replacement

if ($guiTextWithEmbed -eq $guiText) {
    throw "Konnte '#Requires -RunAsAdministrator' in Update-Bios-GUI.ps1 nicht finden - Datei wurde vermutlich geändert, Build-Exe.ps1 muss angepasst werden."
}

Set-Content -Path $combinedPath -Value $guiTextWithEmbed -Encoding UTF8

try {
    Write-Host "Kompiliere $OutputExe ..."
    Invoke-ps2exe -inputFile $combinedPath -outputFile $OutputExe `
        -iconFile $iconPath `
        -noConsole `
        -requireAdmin `
        -title 'BIOS-Update' `
        -version '1.0.0.0' `
        -company 'Eigenbau' `
        -product 'BIOS-Update-Tool'
} finally {
    Remove-Item -Path $combinedPath -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Fertig: $OutputExe"
Write-Host 'Diese eine .exe-Datei reicht jetzt zum Weitergeben/Starten - keine BiosUpdateCore.ps1, keine .bat-Datei mehr nötig.'
