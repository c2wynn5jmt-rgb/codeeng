#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
Grafische Oberfläche für das BIOS-Update-Tool. Nutzt dieselbe Logik wie
Update-Bios.ps1 (BiosUpdateCore.ps1), aber mit Prüfen-/Installieren-
Buttons statt Kommandozeile.

Erkennung und Installation laufen asynchron in einer eigenen, dauerhaften
PowerShell-Runspace (nicht Start-Job/separater Prozess), damit das Fenster
währenddessen reagiert UND das Ergebnis von "Prüfen" (inkl. z.B. des
LSUClient-Paketobjekts für Lenovo) direkt für "Installieren"
weiterverwendet werden kann, ohne den langsamen Update-Katalog ein zweites
Mal komplett abzufragen (ein Prozesswechsel wie bei Start-Job würde diese
Objekte auf reine Daten reduzieren und ihre Typinformation verlieren).
#>

[CmdletBinding()]
param(
    [int]$BitLockerRebootCount = 3,

    # Wie alt eine "Prüfen"-Prüfung höchstens sein darf, bevor "Installieren"
    # zu einem erneuten Check auffordert statt mit ggf. veralteten Daten zu
    # installieren.
    [int]$MaxCheckAgeMinutes = 20,

    # Countdown in Sekunden vor dem automatischen Neustart nach der
    # Installation (Dialog mit Abbrechen-Option, siehe Invoke-PostUpdateRestart).
    [int]$RestartCountdownSeconds = 60
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Run-Update-Bios-GUI.bat startet dieses Skript mit -WindowStyle Hidden -
# ohne Konsolenfenster wäre ein Fehler beim Fensteraufbau (z.B. eine falsch
# geschriebene .NET-Property) sonst komplett unsichtbar: der Prozess bricht
# lautlos ab, es "passiert einfach nichts" (auf echter Hardware so erlebt,
# 2026-08-22 - Ursache war $listVersions.IntegerHeight statt IntegralHeight).
# Deshalb ab hier jeden nicht abgefangenen Fehler als MessageBox zeigen.
trap {
    [System.Windows.Forms.MessageBox]::Show(
        "Unerwarteter Fehler beim Start:`n`n$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)",
        'BIOS-Update - Fehler', 'OK', 'Error') | Out-Null
    exit 1
}

# In einer per ps2exe kompilierten exe ist $PSScriptRoot leer (das Skript
# existiert dann nicht mehr als echte Datei) - ps2exe stellt stattdessen
# $ScriptRoot bereit. Offiziell dokumentierter Fallback laut ps2exe-README,
# funktioniert unverändert im normalen .ps1-Entwicklungsmodus mit.
if (-not $PSScriptRoot -and $ScriptRoot) { $PSScriptRoot = $ScriptRoot }

# __EMBEDDED_CORE_SCRIPT_INJECTION_POINT__
# (Build-Exe.ps1 ersetzt obige Zeile durch eine $script:EmbeddedCoreScriptText-
# Zuweisung. Muss hier stehen, NICHT vor [CmdletBinding()]/param() weiter
# oben - PowerShell erlaubt dort nur Kommentare/#Requires davor, ein
# echtes Statement an der falschen Stelle bricht das Parsen von param().)

$corePath = Join-Path $PSScriptRoot 'BiosUpdateCore.ps1'
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir "bios-update-gui_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

# Lädt BiosUpdateCore.ps1 als Text statt per Datei-Dot-Sourcing, und über
# ein Scriptblock statt per "iex": funktioniert unverändert sowohl im
# Entwicklungsmodus (Core liegt als eigene Datei neben diesem Skript) als
# auch als von Build-Exe.ps1 zusammengeführte/kompilierte Einzel-exe, wo
# $script:EmbeddedCoreScriptText den Code bereits eingebettet mitbringt und
# keine externe .ps1-Datei mehr existiert.
if (Test-Path $corePath) {
    $coreScriptText = Get-Content -Path $corePath -Raw
} elseif ($script:EmbeddedCoreScriptText) {
    $coreScriptText = $script:EmbeddedCoreScriptText
} else {
    throw 'BiosUpdateCore.ps1 nicht gefunden und kein eingebetteter Code vorhanden.'
}
. ([scriptblock]::Create($coreScriptText))

$script:sysInfo = $null
$script:latest = $null
$script:availableVersions = @()
$script:lastCheckedAt = $null
$script:currentPs = $null
$script:currentAsyncResult = $null
$script:onAsyncCompleted = $null
$script:lastLogContent = $null

# --- Farbschema --------------------------------------------------------------

$Theme = @{
    WindowBg       = [System.Drawing.Color]::FromArgb(243, 244, 246)
    HeaderBg       = [System.Drawing.Color]::FromArgb(30, 41, 59)
    HeaderFg       = [System.Drawing.Color]::White
    HeaderSubFg    = [System.Drawing.Color]::FromArgb(148, 163, 184)
    Accent         = [System.Drawing.Color]::FromArgb(37, 99, 235)
    AccentHover    = [System.Drawing.Color]::FromArgb(29, 78, 216)
    CardBg         = [System.Drawing.Color]::White
    CardBorder     = [System.Drawing.Color]::FromArgb(226, 232, 240)
    TextPrimary    = [System.Drawing.Color]::FromArgb(15, 23, 42)
    TextMuted      = [System.Drawing.Color]::FromArgb(100, 116, 139)
    Success        = [System.Drawing.Color]::FromArgb(22, 163, 74)
    Warning        = [System.Drawing.Color]::FromArgb(217, 119, 6)
    Danger         = [System.Drawing.Color]::FromArgb(220, 38, 38)
    ButtonDisabled = [System.Drawing.Color]::FromArgb(203, 213, 225)
    ButtonDisabledFg = [System.Drawing.Color]::FromArgb(100, 116, 139)
    LogBg          = [System.Drawing.Color]::FromArgb(15, 23, 42)
    LogInfo        = [System.Drawing.Color]::FromArgb(203, 213, 225)
    LogWarn        = [System.Drawing.Color]::FromArgb(251, 191, 36)
    LogError       = [System.Drawing.Color]::FromArgb(248, 113, 113)
}

# --- Dauerhafte Hintergrund-Runspace vorbereiten ----------------------------
# Eine einzelne, offen bleibende Runspace statt Start-Job: Funktionen und
# Ergebnisse aus einem Aufruf (Prüfen) bleiben für den nächsten Aufruf
# (Installieren) im Speicher erhalten, solange die Runspace lebt.

$script:asyncRunspace = [runspacefactory]::CreateRunspace()
$script:asyncRunspace.Open()

$initPs = [powershell]::Create()
$initPs.Runspace = $script:asyncRunspace
[void]$initPs.AddScript({
    param($LogFile, $LogDir, $CoreScriptText)
    $logFile = $LogFile
    $logDir = $LogDir
    . ([scriptblock]::Create($CoreScriptText))
}).AddParameter('LogFile', $logFile).AddParameter('LogDir', $logDir).AddParameter('CoreScriptText', $coreScriptText)
$initPs.Invoke() | Out-Null
$initPs.Dispose()

# --- Fenster/Controls -------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BIOS-Update'
$form.Size = New-Object System.Drawing.Size(700, 750)
$form.MinimumSize = New-Object System.Drawing.Size(620, 590)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $Theme.WindowBg
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)

# Fenster-Icon (Titelleiste/Taskleiste/Alt+Tab) - ein eigenes Thema
# gegenüber dem exe-Datei-Icon (das kommt von ps2exe -iconFile). Im
# Entwicklungsmodus liegt bios-update.ico neben dem Skript -> direkt
# laden. In der kompilierten exe gibt es diese Datei nicht separat, dafür
# holt ExtractAssociatedIcon das bereits in der exe eingebettete Icon.
try {
    $devIconPath = Join-Path $PSScriptRoot 'bios-update.ico'
    if (Test-Path $devIconPath) {
        $form.Icon = New-Object System.Drawing.Icon($devIconPath)
    } else {
        $exePath = [System.Reflection.Assembly]::GetExecutingAssembly().Location
        if ($exePath -and (Test-Path $exePath)) {
            $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
        }
    }
} catch {
    # Icon ist rein kosmetisch - ein Fehler hier soll die App nicht blockieren.
}

# Kopfzeile ---

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = 'Top'
$headerPanel.Height = 76
$headerPanel.BackColor = $Theme.HeaderBg

$logoPanel = New-Object System.Windows.Forms.Panel
$logoPanel.Size = New-Object System.Drawing.Size(40, 40)
$logoPanel.Location = New-Object System.Drawing.Point(20, 18)
$logoPanel.BackColor = $Theme.Accent

$lblLogo = New-Object System.Windows.Forms.Label
$lblLogo.Text = 'B'
$lblLogo.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$lblLogo.ForeColor = [System.Drawing.Color]::White
$lblLogo.TextAlign = 'MiddleCenter'
$lblLogo.Dock = 'Fill'
$logoPanel.Controls.Add($lblLogo)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'BIOS-Update'
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $Theme.HeaderFg
$lblTitle.Location = New-Object System.Drawing.Point(72, 14)
$lblTitle.AutoSize = $true

$lblSubtitle = New-Object System.Windows.Forms.Label
$lblSubtitle.Text = 'HP & Lenovo - automatische Erkennung und Installation'
$lblSubtitle.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lblSubtitle.ForeColor = $Theme.HeaderSubFg
$lblSubtitle.Location = New-Object System.Drawing.Point(73, 42)
$lblSubtitle.AutoSize = $true

$headerPanel.Controls.AddRange(@($logoPanel, $lblTitle, $lblSubtitle))

# Info-Karte ---

$infoCard = New-Object System.Windows.Forms.Panel
$infoCard.Location = New-Object System.Drawing.Point(20, 92)
$infoCard.Size = New-Object System.Drawing.Size(640, 148)
$infoCard.Anchor = 'Top,Left,Right'
$infoCard.BackColor = $Theme.CardBg
$infoCard.BorderStyle = 'FixedSingle'

$infoTable = New-Object System.Windows.Forms.TableLayoutPanel
$infoTable.Dock = 'Fill'
$infoTable.Padding = New-Object System.Windows.Forms.Padding(18, 12, 18, 12)
$infoTable.ColumnCount = 2
$infoTable.RowCount = 4
[void]$infoTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 200)))
[void]$infoTable.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
for ($i = 0; $i -lt 4; $i++) {
    [void]$infoTable.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 25)))
}

function New-CaptionLabel {
    param([string]$Text)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $lbl.ForeColor = $Theme.TextMuted
    $lbl.Anchor = 'Left'
    $lbl.AutoSize = $true
    return $lbl
}

function New-ValueLabel {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '-'
    $lbl.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $lbl.ForeColor = $Theme.TextPrimary
    $lbl.Anchor = 'Left'
    $lbl.AutoSize = $true
    return $lbl
}

$lblManuf = New-ValueLabel
$lblModel = New-ValueLabel
$lblCurrent = New-ValueLabel
$lblLatest = New-ValueLabel
$lblLatest.ForeColor = $Theme.Warning

$infoTable.Controls.Add((New-CaptionLabel 'Hersteller'), 0, 0)
$infoTable.Controls.Add($lblManuf, 1, 0)
$infoTable.Controls.Add((New-CaptionLabel 'Modell'), 0, 1)
$infoTable.Controls.Add($lblModel, 1, 1)
$infoTable.Controls.Add((New-CaptionLabel 'Installierte BIOS-Version'), 0, 2)
$infoTable.Controls.Add($lblCurrent, 1, 2)
$infoTable.Controls.Add((New-CaptionLabel 'Neueste verfügbare Version'), 0, 3)
$infoTable.Controls.Add($lblLatest, 1, 3)

$infoCard.Controls.Add($infoTable)

# Versionsauswahl ---
# Zeigt die letzten 5 bei Hersteller/Katalog verfügbaren Versionen (nicht
# nur die neueste) - "Installieren" installiert die hier ausgewählte
# Version, per Default die oberste/neueste. Ermöglicht gezielten Rollback
# auf eine ältere Version, siehe Install-HPBios/$IsLatestRecommended.

$lblVersions = New-CaptionLabel 'Verfügbare Versionen (letzte 5, oberste = neueste)'
$lblVersions.Location = New-Object System.Drawing.Point(20, 250)

$listVersions = New-Object System.Windows.Forms.ListBox
$listVersions.Location = New-Object System.Drawing.Point(20, 270)
$listVersions.Size = New-Object System.Drawing.Size(640, 82)
$listVersions.Anchor = 'Top,Left,Right'
$listVersions.Font = New-Object System.Drawing.Font('Consolas', 9)
$listVersions.IntegralHeight = $false

# Buttons ---

function Set-ButtonStyle {
    param($Button, $BackColor, $ForeColor = [System.Drawing.Color]::White)
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = $BackColor
    $Button.ForeColor = $ForeColor
    $Button.Cursor = 'Hand'
}

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Prüfen'
$btnCheck.Location = New-Object System.Drawing.Point(20, 364)
$btnCheck.Size = New-Object System.Drawing.Size(140, 38)
$btnCheck.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
Set-ButtonStyle -Button $btnCheck -BackColor $Theme.Accent

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = 'Installieren'
$btnInstall.Location = New-Object System.Drawing.Point(172, 364)
$btnInstall.Size = New-Object System.Drawing.Size(140, 38)
$btnInstall.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$btnInstall.Enabled = $false
Set-ButtonStyle -Button $btnInstall -BackColor $Theme.ButtonDisabled -ForeColor $Theme.ButtonDisabledFg

# Fortschritt/Status ---

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Style = 'Marquee'
$progressBar.Location = New-Object System.Drawing.Point(20, 418)
$progressBar.Size = New-Object System.Drawing.Size(640, 6)
$progressBar.Anchor = 'Top,Left,Right'
$progressBar.Visible = $false

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Bereit.'
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$lblStatus.ForeColor = $Theme.TextMuted
$lblStatus.Location = New-Object System.Drawing.Point(20, 430)
$lblStatus.Size = New-Object System.Drawing.Size(640, 20)
$lblStatus.Anchor = 'Top,Left,Right'

# Log ---

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = 'FixedSingle'
$txtLog.ScrollBars = 'Vertical'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.BackColor = $Theme.LogBg
$txtLog.ForeColor = $Theme.LogInfo
$txtLog.Location = New-Object System.Drawing.Point(20, 460)
$txtLog.Size = New-Object System.Drawing.Size(640, 246)
$txtLog.Anchor = 'Top,Bottom,Left,Right'

$form.Controls.AddRange(@(
    $infoCard,
    $lblVersions, $listVersions,
    $btnCheck, $btnInstall,
    $progressBar, $lblStatus, $txtLog,
    $headerPanel
))

# --- Hilfsfunktionen ---------------------------------------------------------

function Update-LogBox {
    if (-not (Test-Path $logFile)) { return }
    $content = Get-Content -Path $logFile -Raw -ErrorAction SilentlyContinue
    if (-not $content -or $content -eq $script:lastLogContent) { return }
    $script:lastLogContent = $content

    $txtLog.SuspendLayout()
    $txtLog.Clear()
    foreach ($line in ($content -split "`r?`n")) {
        if ([string]::IsNullOrEmpty($line)) { continue }
        $color = $Theme.LogInfo
        if ($line -match '\[WARN\]') { $color = $Theme.LogWarn }
        if ($line -match '\[ERROR\]') { $color = $Theme.LogError }
        $txtLog.SelectionStart = $txtLog.TextLength
        $txtLog.SelectionLength = 0
        $txtLog.SelectionColor = $color
        $txtLog.AppendText($line + [Environment]::NewLine)
    }
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    $txtLog.ResumeLayout()
}

function Set-BusyState {
    param([bool]$Busy, [string]$Status)
    $btnCheck.Enabled = -not $Busy
    $listVersions.Enabled = -not $Busy
    $btnInstall.Enabled = (-not $Busy) -and ($script:availableVersions.Count -gt 0)
    if ($btnInstall.Enabled) {
        Set-ButtonStyle -Button $btnInstall -BackColor $Theme.Warning
    } else {
        Set-ButtonStyle -Button $btnInstall -BackColor $Theme.ButtonDisabled -ForeColor $Theme.ButtonDisabledFg
    }
    $progressBar.Visible = $Busy
    $lblStatus.Text = $Status
}

# HP-Einträge haben Name, Lenovo-Einträge Package.Title - beides normalisiert
# in eine Zeile für die Versionsliste.
function Format-VersionListItem {
    param($Version, [bool]$IsTop)
    $name = $null
    if ($Version.PSObject.Properties.Name -contains 'Name' -and $Version.Name) {
        $name = $Version.Name
    } elseif ($Version.PSObject.Properties.Name -contains 'Package' -and $Version.Package.Title) {
        $name = $Version.Package.Title
    }
    $text = if ($name) { "$($Version.Version)   $name" } else { "$($Version.Version)" }
    if ($IsTop) { $text += '   (neueste verfügbare)' }
    return $text
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.Add_Tick({
    Update-LogBox
    if ($script:currentAsyncResult -and $script:currentAsyncResult.IsCompleted) {
        $timer.Stop()
        Update-LogBox
        $result = $null
        $errorMsg = $null
        try {
            $result = $script:currentPs.EndInvoke($script:currentAsyncResult)
            if ($script:currentPs.HadErrors -and $script:currentPs.Streams.Error.Count -gt 0) {
                $errorMsg = $script:currentPs.Streams.Error[0].Exception.Message
            }
        } catch {
            $errorMsg = $_.Exception.Message
        }
        $script:currentPs.Dispose()
        $script:currentPs = $null
        $script:currentAsyncResult = $null
        $callback = $script:onAsyncCompleted
        $script:onAsyncCompleted = $null
        if ($callback) { & $callback $result $errorMsg }
    }
})

function Invoke-AsyncOnRunspace {
    param([scriptblock]$ScriptBlock, [scriptblock]$OnCompleted, [hashtable]$Parameters)
    $ps = [powershell]::Create()
    $ps.Runspace = $script:asyncRunspace
    [void]$ps.AddScript($ScriptBlock)
    if ($Parameters) {
        foreach ($key in $Parameters.Keys) {
            [void]$ps.AddParameter($key, $Parameters[$key])
        }
    }
    $script:currentPs = $ps
    $script:onAsyncCompleted = $OnCompleted
    $script:currentAsyncResult = $ps.BeginInvoke()
    $timer.Start()
}

# --- Prüfen -------------------------------------------------------------
# Speichert Ergebnis zusätzlich als $global:lastSysInfo/$global:lastLatest
# *in der Hintergrund-Runspace* (nicht im GUI-Prozess-Scope), damit
# "Installieren" später ohne erneute Katalog-Abfrage darauf zugreifen kann.

$checkScript = {
    $out = [ordered]@{ SysInfo = $null; Latest = $null; AvailableVersions = @(); ErrorMessage = $null }
    try {
        $sysInfo = Get-SystemInfo
        $latestInfo = Get-LatestBiosForVendor -SysInfo $sysInfo
        $global:lastSysInfo = $sysInfo
        $global:lastAvailableVersions = $latestInfo.AvailableVersions
        $out.SysInfo = $sysInfo
        $out.Latest = $latestInfo.Latest
        $out.AvailableVersions = $latestInfo.AvailableVersions
    } catch {
        $out.ErrorMessage = $_.Exception.Message
    }
    [PSCustomObject]$out
}

$btnCheck.Add_Click({
    Set-BusyState -Busy $true -Status 'Ermittle Modell und BIOS-Versionen...'
    $script:lastLogContent = $null
    $txtLog.Clear()
    $listVersions.Items.Clear()
    $lblLatest.ForeColor = $Theme.Warning

    Invoke-AsyncOnRunspace -ScriptBlock $checkScript -OnCompleted {
        param($result, $errorMsg)
        Update-LogBox

        if ($errorMsg -or -not $result) {
            $script:availableVersions = @()
            Set-BusyState -Busy $false -Status "Fehler: $errorMsg"
            [System.Windows.Forms.MessageBox]::Show("Fehler bei der Erkennung: $errorMsg", 'BIOS-Update', 'OK', 'Error') | Out-Null
            return
        }
        if ($result.ErrorMessage) {
            $script:availableVersions = @()
            Set-BusyState -Busy $false -Status "Fehler: $($result.ErrorMessage)"
            [System.Windows.Forms.MessageBox]::Show($result.ErrorMessage, 'BIOS-Update', 'OK', 'Error') | Out-Null
            return
        }

        $script:sysInfo = $result.SysInfo
        $script:latest = $result.Latest
        $script:availableVersions = @($result.AvailableVersions)
        $script:lastCheckedAt = Get-Date

        $lblManuf.Text = $script:sysInfo.Manufacturer
        $lblModel.Text = $script:sysInfo.Model
        $lblCurrent.Text = $script:sysInfo.CurrentBios

        $listVersions.Items.Clear()
        for ($i = 0; $i -lt $script:availableVersions.Count; $i++) {
            [void]$listVersions.Items.Add((Format-VersionListItem -Version $script:availableVersions[$i] -IsTop ($i -eq 0)))
        }
        if ($listVersions.Items.Count -gt 0) { $listVersions.SelectedIndex = 0 }

        if ($script:latest) {
            $lblLatest.ForeColor = $Theme.Warning
            $lblLatest.Text = $script:latest.Version
            Set-BusyState -Busy $false -Status 'Update verfügbar.'
        } else {
            $lblLatest.ForeColor = $Theme.Success
            $lblLatest.Text = "$($script:sysInfo.CurrentBios) (aktuell)"
            if ($script:availableVersions.Count -gt 0) {
                Set-BusyState -Busy $false -Status 'BIOS ist bereits aktuell. Ältere Versionen stehen unten zur Auswahl (Rollback).'
            } else {
                Set-BusyState -Busy $false -Status 'BIOS ist bereits aktuell.'
            }
        }
    }
})

# --- Installieren ---------------------------------------------------------
# Nutzt $global:lastLatest aus der Hintergrund-Runspace (von "Prüfen"
# gesetzt) statt neu abzufragen - solange die letzte Prüfung nicht zu alt
# ist (siehe $MaxCheckAgeMinutes).

$installScript = {
    param($SelectedIndex, [bool]$IsLatestRecommended)
    $out = [ordered]@{ ExitCode = $null; ErrorMessage = $null }
    try {
        if (-not $global:lastAvailableVersions -or $global:lastAvailableVersions.Count -eq 0) {
            throw 'Keine aktuelle Prüfung im Speicher. Bitte zuerst erneut "Prüfen" ausführen.'
        }
        if ($SelectedIndex -lt 0 -or $SelectedIndex -ge $global:lastAvailableVersions.Count) {
            throw 'Ungültige Versionsauswahl.'
        }
        $selected = $global:lastAvailableVersions[$SelectedIndex]
        $out.ExitCode = Install-BiosForVendor -SysInfo $global:lastSysInfo -LatestInfo $selected -IsLatestRecommended $IsLatestRecommended
    } catch {
        $out.ErrorMessage = $_.Exception.Message
    }
    [PSCustomObject]$out
}

$btnInstall.Add_Click({
    if ($script:availableVersions.Count -eq 0 -or -not $script:sysInfo) { return }

    $selectedIndex = $listVersions.SelectedIndex
    if ($selectedIndex -lt 0) { $selectedIndex = 0 }
    $selectedVersion = $script:availableVersions[$selectedIndex]
    $isLatestRecommended = ($selectedIndex -eq 0)

    if ($script:lastCheckedAt -and ((Get-Date) - $script:lastCheckedAt).TotalMinutes -gt $MaxCheckAgeMinutes) {
        [System.Windows.Forms.MessageBox]::Show(
            "Die letzte Prüfung ist über $MaxCheckAgeMinutes Minuten alt. Bitte zuerst nochmal auf `"Prüfen`" klicken, bevor installiert wird.",
            'BIOS-Update', 'OK', 'Information') | Out-Null
        return
    }

    if (-not (Test-OnACPower)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Gerät hängt nicht am Netzteil. Bitte Netzteil anschließen, bevor ein BIOS-Update gestartet wird.',
            'BIOS-Update', 'OK', 'Warning') | Out-Null
        return
    }

    $rollbackNote = if (-not $isLatestRecommended) {
        "`n`nHinweis: Das ist NICHT die neueste verfügbare Version - gezielte Auswahl (Rollback)."
    } else { '' }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Ausgewählte Version installieren:`n`n" +
        "Installiert:  $($script:sysInfo.CurrentBios)`n" +
        "Ausgewählt:   $($selectedVersion.Version)$rollbackNote`n`n" +
        "Jetzt installieren? Das Gerät startet dabei ggf. mehrfach neu.",
        'BIOS-Update', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Set-BusyState -Busy $true -Status 'Setze BitLocker für die Update-Neustarts aus...'
    Suspend-BitLockerForUpdate -RebootCount $BitLockerRebootCount
    Update-LogBox

    Set-BusyState -Busy $true -Status 'Lade Update herunter und installiere (kann dauern)...'

    Invoke-AsyncOnRunspace -ScriptBlock $installScript -Parameters @{ SelectedIndex = $selectedIndex; IsLatestRecommended = $isLatestRecommended } -OnCompleted {
        param($result, $errorMsg)
        Update-LogBox

        if ($errorMsg -or -not $result -or $result.ErrorMessage) {
            $msg = if ($errorMsg) { $errorMsg } else { $result.ErrorMessage }
            Set-BusyState -Busy $false -Status "Fehler: $msg"
            [System.Windows.Forms.MessageBox]::Show("Installation fehlgeschlagen: $msg", 'BIOS-Update', 'OK', 'Error') | Out-Null
            return
        }

        $script:latest = $null
        $script:availableVersions = @()
        Set-BusyState -Busy $false -Status "Installation abgeschlossen (Exit-Code $($result.ExitCode)). Neustart wird vorbereitet..."

        $restartChoice = Invoke-PostUpdateRestart -CountdownSeconds $RestartCountdownSeconds
        if ($restartChoice -eq 'Cancelled') {
            Set-BusyState -Busy $false -Status 'Installation abgeschlossen. Neustart abgebrochen - bitte zeitnah manuell neu starten.'
        }
        # Bei 'Restart' fährt das Gerät herunter, der Rest ist irrelevant.
    }
})

# --- Aufräumen ---------------------------------------------------------------

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:currentAsyncResult -and -not $script:currentAsyncResult.IsCompleted) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'Ein Vorgang läuft noch (z.B. BIOS-Installation). Wirklich schließen?',
            'BIOS-Update', 'YesNo', 'Warning')
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
    }
})

$form.Add_FormClosed({
    $timer.Stop()
    $timer.Dispose()
    if ($script:currentPs) { $script:currentPs.Dispose() }
    $script:asyncRunspace.Close()
    $script:asyncRunspace.Dispose()
})

$form.Add_Shown({ $btnCheck.PerformClick() })

[void]$form.ShowDialog()
