<#
Gemeinsame Funktionen für Erkennung/Installation von BIOS-Updates
(HP über HP CMSL, Lenovo über LSUClient). Wird sowohl von der
Kommandozeilen-Variante (Update-Bios.ps1) als auch der GUI
(Update-Bios-GUI.ps1) per Dot-Sourcing eingebunden:

    . (Join-Path $PSScriptRoot 'BiosUpdateCore.ps1')

Erwartet, dass der aufrufende Scope $logDir/$logFile bereits gesetzt hat,
oder setzt bei Fehlen selbst sinnvolle Standardwerte relativ zu $PSScriptRoot.
#>

if (-not $logDir) { $logDir = Join-Path $PSScriptRoot 'logs' }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
if (-not $logFile) { $logFile = Join-Path $logDir "bios-update_$(Get-Date -Format 'yyyyMMdd_HHmmss').log" }

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
    param([string]$Model, [string]$CurrentBios)

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
    if (-not (Compare-BiosVersion -Current $CurrentBios -Latest $latest.Version)) {
        return $null
    }

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
# Nutzt LSUClient (PowerShell Gallery, https://github.com/jantari/LSUClient)
# statt eines eigenen Katalog-Parsers: fragt Lenovos offizielle
# Update-Pakete ab und kennt pro Paket den korrekten Silent-Install-Befehl,
# den der Hersteller selbst hinterlegt hat.

function Get-LenovoLatestBios {
    param([string]$CurrentBios)

    if (-not (Get-Module -ListAvailable -Name LSUClient)) {
        Write-Log 'LSUClient-Modul nicht gefunden, installiere aus PSGallery...' -Level WARN
        Install-Module -Name LSUClient -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module LSUClient -ErrorAction Stop

    Write-Log 'Frage Lenovo-Update-Katalog über LSUClient ab (kann etwas dauern)...'

    # Manche Lenovo-Pakete haben defekte/fehlende Dateien beim Hersteller
    # (fuer uns irrelevant, meist nicht-BIOS-Pakete). LSUClient soll die
    # einfach ueberspringen, ohne die rote PowerShell-Fehlerausgabe zu
    # zeigen - deshalb SilentlyContinue statt des globalen 'Stop', und die
    # aufgefangenen Fehler nur als kurze, eigene Log-Zeile zusammenfassen.
    $lsuErrors = $null
    $updates = Get-LSUpdate -ErrorAction SilentlyContinue -ErrorVariable lsuErrors
    if ($lsuErrors) {
        Write-Log "$($lsuErrors.Count) Lenovo-Paket(e) konnten nicht abgerufen werden (z.B. defekte Datei beim Hersteller) und wurden übersprungen." -Level WARN
    }

    $biosUpdate = $updates | Where-Object { $_.Category -match 'BIOS' -or $_.Title -match 'BIOS' } |
        Select-Object -First 1

    if (-not $biosUpdate) {
        Write-Log 'Kein anwendbares BIOS-Update laut LSUClient gefunden (vermutlich bereits aktuell).'
        return $null
    }

    [PSCustomObject]@{
        Version = $biosUpdate.Version
        Package = $biosUpdate
    }
}

function Install-LenovoBios {
    param($LatestInfo)

    Write-Log "Installiere Lenovo-Paket $($LatestInfo.Package.ID) ($($LatestInfo.Package.Title), Version $($LatestInfo.Package.Version)) über LSUClient..."
    $result = Install-LSUpdate -Package $LatestInfo.Package -ErrorAction Stop
    Write-Log "LSUClient-Ergebnis: $($result | Out-String)"

    if ($result.Success -eq $false) {
        throw "LSUClient meldet Fehler: $($result.FailureReason)"
    }
    return 0
}

# --- Vendor-Dispatch --------------------------------------------------------

function Get-LatestBiosForVendor {
    param($SysInfo)
    switch -Wildcard ($SysInfo.Manufacturer) {
        '*HP*'      { return Get-HPLatestBios -Model $SysInfo.Model -CurrentBios $SysInfo.CurrentBios }
        '*Hewlett*' { return Get-HPLatestBios -Model $SysInfo.Model -CurrentBios $SysInfo.CurrentBios }
        '*Lenovo*'  { return Get-LenovoLatestBios -CurrentBios $SysInfo.CurrentBios }
        default     { throw "Nicht unterstützter Hersteller: $($SysInfo.Manufacturer)" }
    }
}

function Install-BiosForVendor {
    param($SysInfo, $LatestInfo)
    switch -Wildcard ($SysInfo.Manufacturer) {
        '*HP*'      { return Install-HPBios -SoftpaqInfo $LatestInfo }
        '*Hewlett*' { return Install-HPBios -SoftpaqInfo $LatestInfo }
        '*Lenovo*'  { return Install-LenovoBios -LatestInfo $LatestInfo }
        default     { throw "Nicht unterstützter Hersteller: $($SysInfo.Manufacturer)" }
    }
}
