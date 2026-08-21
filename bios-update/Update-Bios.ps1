#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
Erkennt Hersteller/Modell, installierte und neueste verfügbare BIOS-Version
(HP über HP CMSL, Lenovo über den öffentlichen Lenovo-Katalog), fragt per
GUI-Dialog nach, ob aktualisiert werden soll, setzt BitLocker für die
Update-Neustarts aus und installiert das BIOS-Update.

WICHTIG: Auf einem Testgerät verifizieren, bevor dies breiter/automatisiert
eingesetzt wird. Besonders die Lenovo-Katalog-Parsing-Logik und die
HP-Silent-Install-Switches können je nach Modell/CMSL-Version abweichen —
siehe README.md.
#>

[CmdletBinding()]
param(
    # Nur erkennen und Versionen anzeigen, nichts installieren.
    [switch]$DetectOnly,

    # Wie viele Neustarts BitLocker ausgesetzt bleibt (Standard: 3, deckt
    # auch mehrstufige BIOS-Updates mit mehreren Reboots ab).
    [int]$BitLockerRebootCount = 3
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir "bios-update_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Get-SystemInfo {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS
    [PSCustomObject]@{
        Manufacturer = $cs.Manufacturer.Trim()
        Model        = $cs.Model.Trim()
        CurrentBios  = $bios.SMBIOSBIOSVersion.Trim()
    }
}

function Test-OnACPower {
    Add-Type -AssemblyName System.Windows.Forms
    try {
        $status = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
        return $status -eq [System.Windows.Forms.PowerLineStatus]::Online
    } catch {
        # Desktop-PCs ohne Akku melden hier ggf. Fehler/Unknown -> nicht blockieren.
        return $true
    }
}

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

function Suspend-BitLockerForUpdate {
    param([int]$RebootCount)
    $volumes = Get-BitLockerVolume | Where-Object { $_.ProtectionStatus -eq 'On' }
    if (-not $volumes) {
        Write-Log 'Kein aktiver BitLocker-Schutz gefunden, kein Suspend nötig.'
        return
    }
    foreach ($vol in $volumes) {
        Write-Log "Setze BitLocker auf $($vol.MountPoint) für $RebootCount Neustarts aus."
        Suspend-BitLocker -MountPoint $vol.MountPoint -RebootCount $RebootCount | Out-Null
    }
}

function Compare-BiosVersion {
    # Vergleicht zwei BIOS-Versionsstrings numerisch, soweit möglich
    # (z.B. "01.08.03" vs "01.09.00"). Fällt bei nicht-numerischen
    # Versionsschemata (z.B. Lenovo "R0FET39W") auf String-Ungleichheit zurück.
    param([string]$Current, [string]$Latest)

    $currentNums = ($Current -replace '[^0-9.]', '') -split '\.' | Where-Object { $_ -ne '' }
    $latestNums  = ($Latest  -replace '[^0-9.]', '') -split '\.' | Where-Object { $_ -ne '' }

    if ($currentNums.Count -gt 0 -and $latestNums.Count -gt 0) {
        for ($i = 0; $i -lt [Math]::Max($currentNums.Count, $latestNums.Count); $i++) {
            $c = if ($i -lt $currentNums.Count) { [int]$currentNums[$i] } else { 0 }
            $l = if ($i -lt $latestNums.Count)  { [int]$latestNums[$i] }  else { 0 }
            if ($l -gt $c) { return $true }
            if ($l -lt $c) { return $false }
        }
        return $false
    }

    # Kein numerisches Schema erkennbar -> Update anbieten, wenn die Strings
    # sich unterscheiden (typisch bei Lenovo-Versionscodes).
    return ($Current.Trim() -ne $Latest.Trim())
}

# --- HP -----------------------------------------------------------------

function Get-HPLatestBios {
    param([string]$Model)

    if (-not (Get-Module -ListAvailable -Name HPCMSL)) {
        Write-Log 'HP CMSL-Modul nicht gefunden, installiere aus PSGallery...' -Level WARN
        Install-Module -Name HPCMSL -Scope CurrentUser -Force -AcceptLicense -ErrorAction Stop
    }
    Import-Module HPCMSL -ErrorAction Stop

    $device = Get-HPDeviceDetails
    $platform = $device.'Base Board Product'
    if (-not $platform -and $device.PSObject.Properties.Name -contains 'Platform') {
        $platform = $device.Platform
    }
    if (-not $platform) {
        throw "Konnte HP-Plattform-ID nicht ermitteln. 'Get-HPDeviceDetails' auf diesem Gerät manuell prüfen."
    }
    Write-Log "HP-Plattform-ID: $platform"

    $softpaqs = Get-SoftpaqList -Platform $platform -Category BIOS -Bitness 64 -ErrorAction Stop |
        Sort-Object -Property Version -Descending

    if (-not $softpaqs) {
        throw "Keine BIOS-Softpaqs für Plattform $platform gefunden."
    }

    $latest = $softpaqs[0]
    [PSCustomObject]@{
        Version = $latest.Version
        Id      = $latest.Id
        Name    = $latest.Name
    }
}

function Install-HPBios {
    param($SoftpaqInfo)

    $downloadPath = Join-Path $env:TEMP "$($SoftpaqInfo.Id).exe"
    Write-Log "Lade $($SoftpaqInfo.Id) ($($SoftpaqInfo.Name), Version $($SoftpaqInfo.Version)) herunter..."
    Get-Softpaq -Number $SoftpaqInfo.Id -SaveAs $downloadPath -ErrorAction Stop

    if (Get-Command -Name Install-HPSoftpaq -ErrorAction SilentlyContinue) {
        Write-Log 'Installiere über Install-HPSoftpaq (CMSL-natives Cmdlet)...'
        Install-HPSoftpaq -Number $SoftpaqInfo.Id -ErrorAction Stop
        return 0
    }

    Write-Log 'Install-HPSoftpaq nicht verfügbar, starte Installer direkt mit /s (silent)...' -Level WARN
    Write-Log 'Hinweis: Silent-Switches wurden nicht auf diesem Modell verifiziert, siehe README.' -Level WARN
    $proc = Start-Process -FilePath $downloadPath -ArgumentList '/s' -Wait -PassThru
    Write-Log "Installer beendet mit Exit-Code $($proc.ExitCode)."
    return $proc.ExitCode
}

# --- Lenovo ---------------------------------------------------------------

function Get-LenovoMachineType {
    param([string]$Model)
    if ($Model.Length -ge 4) { return $Model.Substring(0, 4) }
    throw "Konnte Lenovo Machine Type nicht aus Modell '$Model' ableiten."
}

function Get-LenovoLatestBios {
    param([string]$MachineType)

    $catalogUrl = "https://download.lenovo.com/catalog/$MachineType.xml"
    Write-Log "Lade Lenovo-Katalog: $catalogUrl"

    $raw = Invoke-WebRequest -Uri $catalogUrl -UseBasicParsing -ErrorAction Stop
    $rawPath = Join-Path $logDir "lenovo-catalog_$MachineType.xml"
    Set-Content -Path $rawPath -Value $raw.Content
    Write-Log "Rohkatalog gespeichert unter $rawPath (zur Kontrolle bei Parsing-Problemen)."

    [xml]$catalog = $raw.Content

    $biosPackage = $catalog.SelectNodes('//Package') | Where-Object {
        $_.Category -match 'BIOS'
    } | Select-Object -First 1

    if (-not $biosPackage) {
        throw "Kein BIOS-Paket im Lenovo-Katalog für $MachineType gefunden. Rohkatalog prüfen: $rawPath"
    }

    [PSCustomObject]@{
        Version    = $biosPackage.Version
        Title      = $biosPackage.Title.InnerText
        Location   = $biosPackage.Location
        SilentArgs = $biosPackage.ExtractCommand
    }
}

function Install-LenovoBios {
    param($PackageInfo)

    $downloadPath = Join-Path $env:TEMP (Split-Path -Leaf $PackageInfo.Location)
    Write-Log "Lade $($PackageInfo.Title) (Version $($PackageInfo.Version)) herunter..."
    Invoke-WebRequest -Uri $PackageInfo.Location -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop

    Write-Log 'Hinweis: Silent-Install-Args aus Katalog nicht verifiziert, siehe README.' -Level WARN
    $proc = Start-Process -FilePath $downloadPath -ArgumentList '/VERYSILENT' -Wait -PassThru
    Write-Log "Installer beendet mit Exit-Code $($proc.ExitCode)."
    return $proc.ExitCode
}

# --- Hauptablauf ------------------------------------------------------------

try {
    $sysInfo = Get-SystemInfo
    Write-Log "Hersteller: $($sysInfo.Manufacturer)"
    Write-Log "Modell: $($sysInfo.Model)"
    Write-Log "Installierte BIOS-Version: $($sysInfo.CurrentBios)"

    $latest = switch -Wildcard ($sysInfo.Manufacturer) {
        '*HP*'       { Get-HPLatestBios -Model $sysInfo.Model }
        '*Hewlett*'  { Get-HPLatestBios -Model $sysInfo.Model }
        '*Lenovo*'   { Get-LenovoLatestBios -MachineType (Get-LenovoMachineType -Model $sysInfo.Model) }
        default {
            Write-Log "Nicht unterstützter Hersteller: $($sysInfo.Manufacturer)" -Level ERROR
            exit 1
        }
    }

    Write-Log "Neueste verfügbare BIOS-Version: $($latest.Version)"

    $updateAvailable = Compare-BiosVersion -Current $sysInfo.CurrentBios -Latest $latest.Version
    if (-not $updateAvailable) {
        Write-Log 'BIOS ist bereits aktuell.'
        exit 0
    }

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

    $exitCode = switch -Wildcard ($sysInfo.Manufacturer) {
        '*HP*'      { Install-HPBios -SoftpaqInfo $latest }
        '*Hewlett*' { Install-HPBios -SoftpaqInfo $latest }
        '*Lenovo*'  { Install-LenovoBios -PackageInfo $latest }
    }

    Write-Log "BIOS-Update-Prozess abgeschlossen, Exit-Code: $exitCode"
}
catch {
    Write-Log "Fehler: $($_.Exception.Message)" -Level ERROR
    throw
}
