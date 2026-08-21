#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
Grafische Oberfläche für das BIOS-Update-Tool. Nutzt dieselbe Logik wie
Update-Bios.ps1 (BiosUpdateCore.ps1), aber mit Prüfen-/Installieren-
Buttons statt Kommandozeile. Erkennung und Installation laufen als
Hintergrund-Job (Start-Job), damit das Fenster währenddessen reagiert.
#>

[CmdletBinding()]
param(
    [int]$BitLockerRebootCount = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$corePath = Join-Path $PSScriptRoot 'BiosUpdateCore.ps1'
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir "bios-update-gui_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

. $corePath

$script:sysInfo = $null
$script:latest = $null
$script:currentJob = $null
$script:onJobCompleted = $null

# --- Fenster/Controls -------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'BIOS-Update'
$form.Size = New-Object System.Drawing.Size(640, 560)
$form.MinimumSize = New-Object System.Drawing.Size(560, 420)
$form.StartPosition = 'CenterScreen'

$lblManufCaption = New-Object System.Windows.Forms.Label -Property @{ Text = 'Hersteller:'; Location = New-Object System.Drawing.Point(20, 20); AutoSize = $true }
$lblManuf         = New-Object System.Windows.Forms.Label -Property @{ Text = '-'; Location = New-Object System.Drawing.Point(200, 20); AutoSize = $true }

$lblModelCaption  = New-Object System.Windows.Forms.Label -Property @{ Text = 'Modell:'; Location = New-Object System.Drawing.Point(20, 45); AutoSize = $true }
$lblModel         = New-Object System.Windows.Forms.Label -Property @{ Text = '-'; Location = New-Object System.Drawing.Point(200, 45); AutoSize = $true }

$lblCurrentCaption = New-Object System.Windows.Forms.Label -Property @{ Text = 'Installierte BIOS-Version:'; Location = New-Object System.Drawing.Point(20, 70); AutoSize = $true }
$lblCurrent        = New-Object System.Windows.Forms.Label -Property @{ Text = '-'; Location = New-Object System.Drawing.Point(200, 70); AutoSize = $true }

$lblLatestCaption = New-Object System.Windows.Forms.Label -Property @{ Text = 'Neueste verfügbare Version:'; Location = New-Object System.Drawing.Point(20, 95); AutoSize = $true }
$lblLatest        = New-Object System.Windows.Forms.Label -Property @{ Text = '-'; Location = New-Object System.Drawing.Point(200, 95); AutoSize = $true; ForeColor = [System.Drawing.Color]::DarkOrange }

$btnCheck = New-Object System.Windows.Forms.Button
$btnCheck.Text = 'Prüfen'
$btnCheck.Location = New-Object System.Drawing.Point(20, 130)
$btnCheck.Size = New-Object System.Drawing.Size(120, 32)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = 'Installieren'
$btnInstall.Location = New-Object System.Drawing.Point(150, 130)
$btnInstall.Size = New-Object System.Drawing.Size(120, 32)
$btnInstall.Enabled = $false

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Style = 'Marquee'
$progressBar.Location = New-Object System.Drawing.Point(20, 172)
$progressBar.Size = New-Object System.Drawing.Size(580, 18)
$progressBar.Anchor = 'Top,Left,Right'
$progressBar.Visible = $false

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Bereit.'
$lblStatus.Location = New-Object System.Drawing.Point(20, 198)
$lblStatus.Size = New-Object System.Drawing.Size(580, 20)
$lblStatus.Anchor = 'Top,Left,Right'

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ReadOnly = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.Location = New-Object System.Drawing.Point(20, 226)
$txtLog.Size = New-Object System.Drawing.Size(580, 270)
$txtLog.Anchor = 'Top,Bottom,Left,Right'

$form.Controls.AddRange(@(
    $lblManufCaption, $lblManuf,
    $lblModelCaption, $lblModel,
    $lblCurrentCaption, $lblCurrent,
    $lblLatestCaption, $lblLatest,
    $btnCheck, $btnInstall,
    $progressBar, $lblStatus, $txtLog
))

# --- Hilfsfunktionen ---------------------------------------------------------

function Update-LogBox {
    if (-not (Test-Path $logFile)) { return }
    $content = Get-Content -Path $logFile -Raw -ErrorAction SilentlyContinue
    if ($content -and $content -ne $txtLog.Text) {
        $txtLog.Text = $content
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
}

function Set-BusyState {
    param([bool]$Busy, [string]$Status)
    $btnCheck.Enabled = -not $Busy
    $btnInstall.Enabled = (-not $Busy) -and ($null -ne $script:latest)
    $progressBar.Visible = $Busy
    $lblStatus.Text = $Status
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 700
$timer.Add_Tick({
    Update-LogBox
    if ($script:currentJob -and $script:currentJob.State -in @('Completed', 'Failed', 'Stopped')) {
        $timer.Stop()
        Update-LogBox
        $result = $null
        $jobError = $null
        try {
            $result = Receive-Job -Job $script:currentJob -ErrorAction Stop
        } catch {
            $jobError = $_.Exception.Message
        }
        Remove-Job -Job $script:currentJob -Force -ErrorAction SilentlyContinue
        $script:currentJob = $null
        $callback = $script:onJobCompleted
        $script:onJobCompleted = $null
        if ($callback) { & $callback $result $jobError }
    }
})

function Start-BackgroundJob {
    param([scriptblock]$ScriptBlock, [array]$ArgumentList, [scriptblock]$OnCompleted)
    $script:onJobCompleted = $OnCompleted
    $script:currentJob = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $timer.Start()
}

# --- Prüfen -------------------------------------------------------------

$btnCheck.Add_Click({
    Set-BusyState -Busy $true -Status 'Ermittle Modell und BIOS-Versionen...'
    $txtLog.Clear()
    $lblLatest.ForeColor = [System.Drawing.Color]::DarkOrange

    $checkScript = {
        param($CorePath, $LogFile)
        $logFile = $LogFile
        . $CorePath
        $out = [ordered]@{ SysInfo = $null; Latest = $null; ErrorMessage = $null }
        try {
            $out.SysInfo = Get-SystemInfo
            $out.Latest = Get-LatestBiosForVendor -SysInfo $out.SysInfo
        } catch {
            $out.ErrorMessage = $_.Exception.Message
        }
        [PSCustomObject]$out
    }

    Start-BackgroundJob -ScriptBlock $checkScript -ArgumentList @($corePath, $logFile) -OnCompleted {
        param($result, $jobError)
        Update-LogBox

        if ($jobError -or -not $result) {
            Set-BusyState -Busy $false -Status "Fehler: $jobError"
            [System.Windows.Forms.MessageBox]::Show("Fehler bei der Erkennung: $jobError", 'BIOS-Update', 'OK', 'Error') | Out-Null
            return
        }
        if ($result.ErrorMessage) {
            Set-BusyState -Busy $false -Status "Fehler: $($result.ErrorMessage)"
            [System.Windows.Forms.MessageBox]::Show($result.ErrorMessage, 'BIOS-Update', 'OK', 'Error') | Out-Null
            return
        }

        $script:sysInfo = $result.SysInfo
        $script:latest = $result.Latest

        $lblManuf.Text = $script:sysInfo.Manufacturer
        $lblModel.Text = $script:sysInfo.Model
        $lblCurrent.Text = $script:sysInfo.CurrentBios

        if ($script:latest) {
            $lblLatest.Text = $script:latest.Version
            Set-BusyState -Busy $false -Status 'Update verfügbar.'
        } else {
            $lblLatest.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblLatest.Text = "$($script:sysInfo.CurrentBios) (aktuell)"
            Set-BusyState -Busy $false -Status 'BIOS ist bereits aktuell.'
        }
    }
})

# --- Installieren ---------------------------------------------------------
# Fragt Version erneut ab, statt das bereits geprüfte Objekt weiterzureichen:
# Start-Job läuft in einem eigenen Prozess, komplexe .NET-Objekte (z.B. das
# LSUClient-Paketobjekt) würden beim Grenzübertritt über Job-Argumente ihre
# Typinformationen verlieren. Neu abfragen im selben Job hält Abfrage und
# Installation im selben Prozess und ist zudem eine kleine zusätzliche
# Sicherheit gegen zwischenzeitlich veraltete Daten.

$btnInstall.Add_Click({
    if (-not $script:latest -or -not $script:sysInfo) { return }

    if (-not (Test-OnACPower)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Gerät hängt nicht am Netzteil. Bitte Netzteil anschließen, bevor ein BIOS-Update gestartet wird.',
            'BIOS-Update', 'OK', 'Warning') | Out-Null
        return
    }

    $confirm = [System.Windows.Forms.MessageBox]::Show(
        "Neue BIOS-Version verfügbar:`n`n" +
        "Installiert: $($script:sysInfo.CurrentBios)`n" +
        "Verfügbar:   $($script:latest.Version)`n`n" +
        "Jetzt installieren? Das Gerät startet dabei ggf. mehrfach neu.",
        'BIOS-Update', 'YesNo', 'Question')
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    Set-BusyState -Busy $true -Status 'Setze BitLocker für die Update-Neustarts aus...'
    Suspend-BitLockerForUpdate -RebootCount $BitLockerRebootCount
    Update-LogBox

    Set-BusyState -Busy $true -Status 'Lade Update herunter und installiere (kann dauern)...'

    $installScript = {
        param($CorePath, $LogFile, $SysInfo)
        $logFile = $LogFile
        . $CorePath
        $out = [ordered]@{ ExitCode = $null; ErrorMessage = $null; NoUpdateNeeded = $false }
        try {
            $latest = Get-LatestBiosForVendor -SysInfo $SysInfo
            if (-not $latest) {
                $out.NoUpdateNeeded = $true
            } else {
                $out.ExitCode = Install-BiosForVendor -SysInfo $SysInfo -LatestInfo $latest
            }
        } catch {
            $out.ErrorMessage = $_.Exception.Message
        }
        [PSCustomObject]$out
    }

    Start-BackgroundJob -ScriptBlock $installScript -ArgumentList @($corePath, $logFile, $script:sysInfo) -OnCompleted {
        param($result, $jobError)
        Update-LogBox

        if ($jobError -or -not $result -or $result.ErrorMessage) {
            $msg = if ($jobError) { $jobError } else { $result.ErrorMessage }
            Set-BusyState -Busy $false -Status "Fehler: $msg"
            [System.Windows.Forms.MessageBox]::Show("Installation fehlgeschlagen: $msg", 'BIOS-Update', 'OK', 'Error') | Out-Null
            return
        }

        if ($result.NoUpdateNeeded) {
            $script:latest = $null
            $lblLatest.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblLatest.Text = "$($script:sysInfo.CurrentBios) (aktuell)"
            Set-BusyState -Busy $false -Status 'Kein Update mehr nötig (bereits aktuell).'
            return
        }

        $script:latest = $null
        Set-BusyState -Busy $false -Status "Installation abgeschlossen (Exit-Code $($result.ExitCode)). Ggf. ist ein Neustart nötig."
        [System.Windows.Forms.MessageBox]::Show(
            'BIOS-Update abgeschlossen. Bitte ggf. anstehende Neustarts durchführen.',
            'BIOS-Update', 'OK', 'Information') | Out-Null
    }
})

# --- Schließen während laufendem Job absichern ------------------------------

$form.Add_FormClosing({
    param($sender, $e)
    if ($script:currentJob -and $script:currentJob.State -eq 'Running') {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'Ein Vorgang läuft noch (z.B. BIOS-Installation). Wirklich schließen?',
            'BIOS-Update', 'YesNo', 'Warning')
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { $e.Cancel = $true }
    }
})

$form.Add_Shown({ $btnCheck.PerformClick() })

[void]$form.ShowDialog()
