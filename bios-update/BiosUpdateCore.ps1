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

# --- Modul-Installation ohne interaktive Rückfragen -------------------------
# Ohne das hier vorab zu erledigen, fragt PowerShellGet beim ersten
# Install-Module ggf. interaktiv nach, ob der NuGet-Anbieter installiert
# werden darf. In der Konsole kann man das noch mit "J" bestätigen, aber
# die GUI (Hintergrund-Runspace, kein interaktiver Host) hat dafür keinen
# Host, der eine Ja/Nein-Abfrage entgegennehmen kann - das schlägt dort mit
# "ShouldContinue nicht unterstützt" fehl. Deshalb NuGet-Anbieter und
# PSGallery-Vertrauen vorab explizit und nicht-interaktiv einrichten.

function Initialize-PSGalleryAccess {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Write-Log 'NuGet-Anbieter (PackageManagement) nicht gefunden, installiere...'
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser -Confirm:$false | Out-Null
    }
    if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    # Das mit Windows PowerShell 5.1 mitgelieferte PowerShellGet (1.0.0.1) kennt
    # den Parameter -AcceptLicense noch nicht (erst ab PowerShellGet 2.0.0) -
    # Install-Module -Name HPCMSL -AcceptLicense bricht damit sofort mit
    # "Es wurde kein Parameter gefunden, der dem Parameternamen 'AcceptLicense'
    # entspricht" ab (auf echter HP-Hardware verifiziert, 2026-08-21). Ohne
    # den Parameter würde HPCMSL stattdessen interaktiv nach Lizenzzustimmung
    # fragen - im GUI-Runspace ohne interaktiven Host schlägt das genauso fehl
    # wie die NuGet-Rückfrage oben. Deshalb PowerShellGet bei Bedarf einmalig
    # nicht-interaktiv aktualisieren (Install-ModuleAcceptingLicense unten
    # nutzt danach einen frischen Kindprozess, weil das Update selbst im
    # laufenden Prozess nicht wirkt - siehe dort).
    if (-not (Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) {
        Write-Log 'PowerShellGet ist zu alt für -AcceptLicense, aktualisiere...' -Level WARN
        # -AllowClobber: Install-Module -Name PowerShellGet aktualisiert dabei
        # auch die Abhängigkeit PackageManagement, deren Cmdlets (Find-Package
        # etc.) im laufenden System schon geladen/verfügbar sind - ohne
        # -AllowClobber bricht das mit "CommandAlreadyAvailable" ab (auf
        # echter HP-Hardware verifiziert, 2026-08-22).
        Install-Module -Name PowerShellGet -MinimumVersion 2.2.5 -Scope CurrentUser -Force -Confirm:$false -SkipPublisherCheck -AllowClobber -ErrorAction Stop
    }
}

# Installiert ein PSGallery-Modul, das RequireLicenseAcceptance verlangt
# (aktuell nur HPCMSL). Läuft der aktuelle Prozess noch mit dem alten,
# mitgelieferten PowerShellGet (kein -AcceptLicense-Parameter), reicht ein
# Install-Module -Name PowerShellGet -Force im selben Prozess NICHT, um
# direkt danach -AcceptLicense nutzen zu können: die alte PowerShellGet-
# Assembly ist im Prozess schon geladen und lässt sich zur Laufzeit nicht
# austauschen (von Microsoft so dokumentiert - ein Import-Module -Force
# lädt zwar neue Funktionen nach, der schon gebundene Install-Module-Befehl
# bleibt aber der alte). Deshalb in diesem Fall einen frischen
# PowerShell-Kindprozess starten, der PowerShellGet neu von der Platte lädt
# (auf echter HP-Hardware verifiziert, 2026-08-22).
function Install-ModuleAcceptingLicense {
    param([Parameter(Mandatory)][string]$Name)

    Initialize-PSGalleryAccess

    if ((Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) {
        Install-Module -Name $Name -Scope CurrentUser -Force -AcceptLicense -Confirm:$false -ErrorAction Stop
        return
    }

    Write-Log "PowerShellGet-Update wirkt erst in einem neuen Prozess, installiere $Name deshalb in einem Kindprozess..." -Level WARN
    $cmd = "Install-Module -Name $Name -Scope CurrentUser -Force -AcceptLicense -Confirm:`$false -ErrorAction Stop"
    $proc = Start-Process -FilePath powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ne 0) {
        throw "Install-Module -Name $Name im Kindprozess fehlgeschlagen (ExitCode $($proc.ExitCode)). Bitte diese PowerShell-Sitzung schließen, neu öffnen und das Skript erneut starten."
    }
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Install-Module -Name $Name im Kindprozess lief ohne Fehler, das Modul ist aber weiterhin nicht auffindbar. Bitte diese PowerShell-Sitzung schließen, neu öffnen und das Skript erneut starten."
    }
}

# --- HP -----------------------------------------------------------------

function Get-HPLatestBios {
    param([string]$Model, [string]$CurrentBios)

    if (-not (Get-Module -ListAvailable -Name HPCMSL)) {
        Write-Log 'HP CMSL-Modul nicht gefunden, installiere aus PSGallery...' -Level WARN
        Install-ModuleAcceptingLicense -Name HPCMSL
    }
    Import-Module HPCMSL -ErrorAction Stop

    # Get-HPDeviceDetails' genaue Property-Namen sind von HP nicht verlässlich
    # dokumentiert (developers.hp.com blockierte automatisierte Zugriffe beim
    # Schreiben dieses Tools) und wichen auf echter Hardware bereits von der
    # ursprünglich angenommenen 'Base Board Product'/'Platform' ab (verifiziert
    # 2026-08-22, HP ENVY x360). Deshalb mehrere bekannte Namensvarianten
    # probieren und zusätzlich über WMI/Win32_BaseBoard nachfassen - das ist
    # der von HPCMSL unabhängige Standardweg, den auch HPs eigene Doku und
    # Community-Skripte für die 4-stellige Plattform-/Baseboard-ID nutzen.
    $device = Get-HPDeviceDetails
    $platform = $null
    foreach ($prop in 'Base Board Product', 'Platform', 'Product ID', 'SystemID', 'BaseBoardProduct') {
        if ($device.PSObject.Properties.Name -contains $prop -and $device.$prop) {
            $platform = $device.$prop
            break
        }
    }
    if (-not $platform) {
        try {
            $platform = (Get-CimInstance -ClassName Win32_BaseBoard -ErrorAction Stop).Product
        } catch {
            $platform = $null
        }
    }
    if (-not $platform) {
        $props = ($device | Format-List * | Out-String).Trim()
        Write-Log "Get-HPDeviceDetails-Ausgabe zur Diagnose:`n$props" -Level WARN
        throw "Konnte HP-Plattform-ID nicht ermitteln. Siehe Log-Zeile direkt darüber für die rohe Get-HPDeviceDetails-Ausgabe."
    }
    Write-Log "HP-Plattform-ID: $platform"

    # Ohne -Os/-OsVer ermittelt Get-SoftpaqList die installierte Windows-
    # Version selbst und holt die dazu passende HP-Referenzkatalogdatei
    # (z. B. ".../876f_64_11.0.25h2.cab"). Für eine sehr neue Windows-Version
    # kann diese Datei bei HP noch fehlen (HTTP 404 "Could not find data
    # file" - auf echter HP-Hardware verifiziert, 2026-08-22, Windows 25H2).
    # Deshalb bei Fehlschlag auf ältere, mit hoher Wahrscheinlichkeit
    # vorhandene Referenzversionen zurückfallen - BIOS-Softpaqs sind i. d. R.
    # nicht OS-Versions-spezifisch, nur die Katalog-Referenzdatei ist es.
    $osVerFallbacks = '24H2', '23H2', '22H2', '21H2'
    $softpaqs = $null
    $lastError = $null
    try {
        $softpaqs = Get-SoftpaqList -Platform $platform -Category BIOS -Bitness 64 -ErrorAction Stop |
            Sort-Object -Property Version -Descending
    } catch {
        $lastError = $_
        Write-Log "SoftPaq-Liste mit automatisch erkannter OS-Version fehlgeschlagen ($($_.Exception.Message)), versuche ältere Referenzversionen..." -Level WARN
        foreach ($osVer in $osVerFallbacks) {
            try {
                $softpaqs = Get-SoftpaqList -Platform $platform -Category BIOS -Bitness 64 -Os win11 -OsVer $osVer -ErrorAction Stop |
                    Sort-Object -Property Version -Descending
                if ($softpaqs) {
                    Write-Log "SoftPaq-Liste über Referenzversion $osVer gefunden."
                    break
                }
            } catch {
                $lastError = $_
            }
        }
    }

    if (-not $softpaqs) {
        # "data file not found" von HP CMSL bedeutet: für diese Plattform-ID
        # gibt es bei HP überhaupt keine Katalog-Referenzdatei - egal welche
        # OS-Version man probiert. Auf echter Hardware reproduziert (2026-08-22,
        # HP ENVY x360 Convertible, Plattform 876F): Get-SoftpaqList UND
        # Get-HPBIOSUpdates scheitern beide identisch mit dieser Meldung. HP
        # CMSL/HPIA ist primär für Business-Geräte (EliteBook/ProBook/ZBook)
        # ausgelegt - Consumer-Modelle (Envy/Pavilion/Spectre) stehen oft
        # schlicht nicht im HPIA-Katalog. Das ist keine falsche OS-Version,
        # sondern eine Katalog-Lücke für dieses Gerät.
        if ($lastError -and $lastError.Exception.Message -match 'data file not found|Unable to retrieve BIOS data') {
            throw "HP liefert für Plattform $platform keine Katalogdaten (auch nicht mit älteren OS-Referenzversionen) - Get-HPBIOSUpdates scheitert vermutlich mit derselben Meldung. HP CMSL/HPIA deckt primär Business-Geräte (EliteBook/ProBook/ZBook) ab; Consumer-Modelle fehlen im Katalog teils komplett. Auf einem Business-Gerät testen, oder BIOS für dieses Modell manuell über support.hp.com suchen."
        }
        if ($lastError) { throw $lastError }
        throw "Keine BIOS-Softpaqs für Plattform $platform gefunden."
    }

    # Letzte 5 Katalog-Versionen für die Versionsauswahl in der GUI (auch
    # ältere als die installierte - für gezielten Rollback), unabhängig
    # davon, ob überhaupt ein Update ansteht.
    $availableVersions = @($softpaqs | Select-Object -First 5 | ForEach-Object {
        [PSCustomObject]@{ Version = $_.Version; Id = $_.Id; Name = $_.Name }
    })

    $top = $softpaqs[0]
    $latestUpdate = $null
    if (Compare-BiosVersion -Current $CurrentBios -Latest $top.Version) {
        $latestUpdate = [PSCustomObject]@{ Version = $top.Version; Id = $top.Id; Name = $top.Name }
    }

    [PSCustomObject]@{
        Latest            = $latestUpdate
        AvailableVersions = $availableVersions
    }
}

function Install-HPBios {
    param($SoftpaqInfo, [bool]$IsLatestRecommended = $true)

    # Bevorzugt Get-HPBIOSUpdates -Flash: HPs eigenes, für genau diesen
    # Workflow gedachtes Kombi-Cmdlet (Erkennung + Flash + BitLocker-Suspend
    # in einem Aufruf), laut mehreren Community-Quellen der seit ~2020
    # empfohlene Weg, der die manuelle Softpaq-Download/Install-Kette
    # ablöst. Primäre HP-Doku (developers.hp.com) war beim Schreiben nicht
    # erreichbar (403) - basiert auf Sekundärquellen, siehe README.
    # WICHTIG: Get-HPBIOSUpdates -Flash installiert immer HPs eigene
    # empfohlene (= neueste) Version, unabhängig davon, welches SoftpaqInfo
    # übergeben wird. Für eine gezielt ausgewählte, NICHT-neueste Version
    # (Rollback über die Versionsliste in der GUI) funktioniert das nicht -
    # dafür ist $IsLatestRecommended = $false und es geht direkt in den
    # manuellen Softpaq-Weg weiter unten, der eine bestimmte Id ansteuert.
    if ($IsLatestRecommended -and (Get-Command -Name Get-HPBIOSUpdates -ErrorAction SilentlyContinue)) {
        Write-Log "Flashe BIOS über Get-HPBIOSUpdates -Flash (Ziel-Version: $($SoftpaqInfo.Version))..."
        Get-HPBIOSUpdates -Flash -Bitlocker suspend -Force -ErrorAction Stop
        Write-Log 'BIOS-Flash angestoßen. Die neue Version wird erst nach einem Neustart aktiv (wird von diesem Tool danach eingeleitet).'
        return 0
    }

    if ($IsLatestRecommended) {
        Write-Log 'Get-HPBIOSUpdates nicht verfügbar (ältere HPCMSL-Version?), falle zurück auf manuellen Softpaq-Download...' -Level WARN
    } else {
        Write-Log "Gezielt ausgewählte Version $($SoftpaqInfo.Version) (nicht die von HP empfohlene neueste) - installiere über den manuellen Softpaq-Weg, da Get-HPBIOSUpdates -Flash keine bestimmte Version ansteuern kann." -Level WARN
    }
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
        Initialize-PSGalleryAccess
        Install-Module -Name LSUClient -Scope CurrentUser -Force -Confirm:$false -ErrorAction Stop
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

    # LSUClient liefert pro Modell i. d. R. nur das aktuell anwendbare
    # BIOS-Paket, keine historischen Alt-Versionen - anders als bei HPs
    # Softpaq-Katalog ist eine "letzte 5"-Auswahl hier meist nur 1 Eintrag
    # lang. Code trotzdem allgemein für mehrere Treffer gehalten, falls
    # LSUClient für ein Modell doch mehrere BIOS-Pakete listet.
    $biosUpdates = @($updates | Where-Object { $_.Category -match 'BIOS' -or $_.Title -match 'BIOS' } |
        Select-Object -First 5)

    if ($biosUpdates.Count -eq 0) {
        Write-Log 'Kein anwendbares BIOS-Update laut LSUClient gefunden (vermutlich bereits aktuell).'
        return [PSCustomObject]@{ Latest = $null; AvailableVersions = @() }
    }

    $availableVersions = @($biosUpdates | ForEach-Object {
        [PSCustomObject]@{ Version = $_.Version; Package = $_ }
    })

    $top = $biosUpdates[0]
    $latestUpdate = $null
    if (Compare-BiosVersion -Current $CurrentBios -Latest $top.Version) {
        $latestUpdate = [PSCustomObject]@{ Version = $top.Version; Package = $top }
    }

    [PSCustomObject]@{
        Latest            = $latestUpdate
        AvailableVersions = $availableVersions
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
    param($SysInfo, $LatestInfo, [bool]$IsLatestRecommended = $true)
    switch -Wildcard ($SysInfo.Manufacturer) {
        '*HP*'      { return Install-HPBios -SoftpaqInfo $LatestInfo -IsLatestRecommended $IsLatestRecommended }
        '*Hewlett*' { return Install-HPBios -SoftpaqInfo $LatestInfo -IsLatestRecommended $IsLatestRecommended }
        '*Lenovo*'  { return Install-LenovoBios -LatestInfo $LatestInfo }
        default     { throw "Nicht unterstützter Hersteller: $($SysInfo.Manufacturer)" }
    }
}

# --- Neustart nach Installation ---------------------------------------------
# Weder Get-HPBIOSUpdates -Flash noch Install-LSUpdate starten das Gerät
# selbst neu - beide "stagen" das Update nur, wirksam wird es erst beim
# nächsten Boot. Ohne diesen Schritt bliebe BitLocker unbegrenzt ausgesetzt
# (Suspend-BitLocker zählt nur bei tatsächlichen Neustarts runter) und das
# Update würde nie angewendet, bis irgendwann zufällig manuell neu
# gestartet wird. Zeigt daher einen Countdown-Dialog mit Abbrechen-Option,
# statt kommentarlos durchzustarten.

function Show-RestartCountdownDialog {
    param([int]$Seconds = 60)

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'BIOS-Update - Neustart erforderlich'
    $dlg.Size = New-Object System.Drawing.Size(440, 160)
    $dlg.StartPosition = 'CenterScreen'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.TopMost = $true

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(20, 15)
    $lbl.Size = New-Object System.Drawing.Size(390, 50)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Abbrechen (später manuell neu starten)'
    $btnCancel.Location = New-Object System.Drawing.Point(20, 75)
    $btnCancel.Size = New-Object System.Drawing.Size(280, 32)

    $btnNow = New-Object System.Windows.Forms.Button
    $btnNow.Text = 'Jetzt neu starten'
    $btnNow.Location = New-Object System.Drawing.Point(310, 75)
    $btnNow.Size = New-Object System.Drawing.Size(100, 32)

    $dlg.Controls.AddRange(@($lbl, $btnCancel, $btnNow))
    $dlg.AcceptButton = $btnNow
    $dlg.CancelButton = $btnCancel

    $result = 'Cancelled'
    $remaining = $Seconds

    $updateLabel = {
        $lbl.Text = "Das Gerät startet in $remaining Sekunden neu, um das BIOS-Update anzuwenden.`n`nBitte offene Arbeiten jetzt speichern."
    }
    & $updateLabel

    $cdTimer = New-Object System.Windows.Forms.Timer
    $cdTimer.Interval = 1000
    $cdTimer.Add_Tick({
        $remaining--
        & $updateLabel
        if ($remaining -le 0) {
            $cdTimer.Stop()
            $script:__restartDialogResult = 'Restart'
            $dlg.Close()
        }
    })

    $btnCancel.Add_Click({
        $cdTimer.Stop()
        $script:__restartDialogResult = 'Cancelled'
        $dlg.Close()
    })
    $btnNow.Add_Click({
        $cdTimer.Stop()
        $script:__restartDialogResult = 'Restart'
        $dlg.Close()
    })

    $script:__restartDialogResult = 'Cancelled'
    $cdTimer.Start()
    [void]$dlg.ShowDialog()
    $cdTimer.Dispose()

    return $script:__restartDialogResult
}

function Invoke-PostUpdateRestart {
    param([int]$CountdownSeconds = 60)

    $choice = Show-RestartCountdownDialog -Seconds $CountdownSeconds
    if ($choice -eq 'Restart') {
        Write-Log 'Automatischer Neustart wird jetzt ausgeführt.'
        Restart-Computer -Force
    } else {
        Write-Log 'Automatischer Neustart abgebrochen. Bitte zeitnah manuell neu starten - BitLocker ist nur für eine begrenzte Anzahl Neustarts ausgesetzt.' -Level WARN
    }
    return $choice
}
