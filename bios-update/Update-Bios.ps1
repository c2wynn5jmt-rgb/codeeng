#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
Kommandozeilen-Variante: Erkennt Hersteller/Modell, installierte und
neueste verfügbare BIOS-Version (HP über HP CMSL, Lenovo über LSUClient),
fragt per GUI-Dialog nach, ob aktualisiert werden soll, setzt BitLocker für
die Update-Neustarts aus und installiert das BIOS-Update.

Für eine grafische Oberfläche siehe Update-Bios-GUI.ps1 (nutzt dieselbe
Logik aus BiosUpdateCore.ps1).
#>

[CmdletBinding()]
param(
    # Nur erkennen und Versionen anzeigen, nichts installieren.
    [switch]$DetectOnly,

    # Wie viele Neustarts BitLocker ausgesetzt bleibt (Standard: 3, deckt
    # auch mehrstufige BIOS-Updates mit mehreren Reboots ab).
    [int]$BitLockerRebootCount = 3,

    # Countdown in Sekunden vor dem automatischen Neustart nach der
    # Installation (Dialog mit Abbrechen-Option, siehe Invoke-PostUpdateRestart).
    [int]$RestartCountdownSeconds = 60
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'BiosUpdateCore.ps1')

function Show-YesNoDialog {
    param([string]$Message, [string]$Title = 'BIOS-Update')
    Add-Type -AssemblyName System.Windows.Forms
    $result = [System.Windows.Forms.MessageBox]::Show(
        $Message, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    return $result -eq [System.Windows.Forms.DialogResult]::Yes
}

try {
    $sysInfo = Get-SystemInfo
    Write-Log "Hersteller: $($sysInfo.Manufacturer)"
    Write-Log "Modell: $($sysInfo.Model)"
    Write-Log "Installierte BIOS-Version: $($sysInfo.CurrentBios)"

    $latest = Get-LatestBiosForVendor -SysInfo $sysInfo

    if (-not $latest) {
        Write-Log 'BIOS ist bereits aktuell.'
        exit 0
    }

    Write-Log "Neueste verfügbare BIOS-Version: $($latest.Version)"

    if ($DetectOnly) {
        Write-Log 'DetectOnly gesetzt, Installation wird übersprungen.'
        exit 0
    }

    if (-not (Test-OnACPower)) {
        [void] [System.Windows.Forms.MessageBox]::Show(
            'Gerät hängt nicht am Netzteil. Bitte Netzteil anschließen, bevor ein BIOS-Update gestartet wird.',
            'BIOS-Update', 'OK', 'Warning'
        )
        Write-Log 'Abbruch: Gerät läuft im Akkubetrieb.' -Level WARN
        exit 1
    }

    $confirmed = Show-YesNoDialog -Message (
        "Neue BIOS-Version verfügbar:`n`n" +
        "Installiert: $($sysInfo.CurrentBios)`n" +
        "Verfügbar:   $($latest.Version)`n`n" +
        "Jetzt installieren? Das Gerät startet dabei ggf. mehrfach neu."
    )

    if (-not $confirmed) {
        Write-Log 'Nutzer hat Installation abgelehnt.'
        exit 0
    }

    Suspend-BitLockerForUpdate -RebootCount $BitLockerRebootCount

    $exitCode = Install-BiosForVendor -SysInfo $sysInfo -LatestInfo $latest

    Write-Log "BIOS-Update-Prozess abgeschlossen, Exit-Code: $exitCode"

    Invoke-PostUpdateRestart -CountdownSeconds $RestartCountdownSeconds | Out-Null
}
catch {
    Write-Log "Fehler: $($_.Exception.Message)" -Level ERROR
    throw
}
