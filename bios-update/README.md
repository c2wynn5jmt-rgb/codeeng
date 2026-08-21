# BIOS-Update-Skript (HP + Lenovo, Windows)

Erkennt Hersteller/Modell, installierte und neueste verfügbare BIOS-Version,
fragt per Dialog nach, ob aktualisiert werden soll, setzt BitLocker für die
Update-Neustarts aus (kein Wiederherstellungsschlüssel nötig) und installiert
das Update.

## ⚠️ Vor dem produktiven Einsatz unbedingt lesen

Dieses Skript wurde auf einem Mac ohne Windows/HP/Lenovo-Hardware geschrieben
und ist **noch nicht vollständig auf echter Hardware getestet**. Erkennung
(Modell, installierte Version) wurde bereits erfolgreich auf einem Lenovo
Testgerät verifiziert. Eine Stelle ist bewusst mit Unsicherheit markiert
(Log-Warnung im Skript):

- **HP Silent-Install-Switch** (`Install-HPBios`): Nutzt bevorzugt das
  CMSL-native `Install-HPSoftpaq`, falls verfügbar. Fällt sonst auf
  `<installer>.exe /s` zurück — das ist der übliche Silent-Switch für
  HP-Softpaqs, aber nicht für jedes Modell verifiziert.

Der Lenovo-Pfad nutzt seit der zweiten Version das Community-Modul
[LSUClient](https://github.com/jantari/LSUClient) statt eines eigenen
Katalog-Parsers (der erste Versuch, Lenovos Katalog-XML direkt zu laden und
zu parsen, scheiterte auf dem Testgerät mit einem 404 — der geratene
Endpunkt existiert so nicht mehr). LSUClient fragt Lenovos offizielle
Update-Metadaten ab und kennt pro Paket den vom Hersteller hinterlegten,
korrekten Silent-Install-Befehl — deutlich zuverlässiger als eigenes Raten.

**Getestet und gefixt (2026-08-21):** Auf dem Lenovo-Testgerät brach
`Get-LSUpdate` zunächst mit einem 404 bei einem völlig unabhängigen,
nicht-BIOS-Paket ab (defekte Datei auf Lenovos Server, nicht unser
Problem) — das eigentliche BIOS-Paket war zu diesem Zeitpunkt bereits
korrekt als "nicht nötig" erkannt. Ursache war, dass unser globales
`$ErrorActionPreference = 'Stop'` in die LSUClient-Funktionen
"durchsickerte" und deren eigene, eigentlich robuste Fehlerbehandlung
(einzelnes Paket überspringen) in einen harten Abbruch verwandelte.
Behoben, indem `$ErrorActionPreference` nur rund um den `Get-LSUpdate`-
Aufruf gelockert wird (`Get-LenovoLatestBios`).

**Empfohlenes Vorgehen:**

```powershell
# Erst nur erkennen, nichts installieren:
.\Update-Bios.ps1 -DetectOnly
```

Auf 2-3 Testgeräten (je Hersteller) laufen lassen, Log-Ausgabe und
`logs/`-Inhalte prüfen, bevor der volle Installations-Flow verwendet wird.

## Voraussetzungen

- Windows 10/11, PowerShell 5.1+
- Skript **als Administrator** ausführen (BIOS-Update und BitLocker-Suspend
  brauchen Admin-Rechte; `#Requires -RunAsAdministrator` erzwingt das)
- Internetzugang (für HP CMSL aus der PSGallery bzw. den Lenovo-Katalog)
- Für HP: Falls `HPCMSL` noch nicht installiert ist, installiert das Skript
  es automatisch (`Install-Module -Name HPCMSL -Scope CurrentUser`). Das
  setzt vertraute PSGallery-Verbindung voraus; ggf. vorher einmalig manuell:

  ```powershell
  Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
  ```

## Verwendung

### Per Doppelklick (wenn Execution Policy das Skript blockiert)

Falls PowerShell mit "Skripte sind durch eine Policy deaktiviert" abbricht:
`Get-ExecutionPolicy -Scope MachinePolicy` und `-Scope UserPolicy` prüfen.
Zeigen beide `Undefined`, greift nur der lokale Windows-Standard — dann
einfach eine der beiden `.bat`-Dateien per Doppelklick starten (fragt per
UAC nach Admin-Bestätigung, startet PowerShell mit `-ExecutionPolicy Bypass`
nur für diesen einen Aufruf, ändert nichts systemweit):

- `Run-Update-Bios-DetectOnly.bat` — nur erkennen, nichts installieren
  (für den ersten Test empfohlen)
- `Run-Update-Bios.bat` — voller Ablauf inkl. Installation

Zeigt `MachinePolicy` oder `UserPolicy` dagegen einen konkreten Wert, ist das
eine bewusste IT-Sicherheitsvorgabe — dann bitte die IT kontaktieren statt
die `.bat`-Dateien zu nutzen (siehe Warnung oben im Dokument).

### Direkt per PowerShell

```powershell
# Nur erkennen (empfohlen für den ersten Test):
.\Update-Bios.ps1 -DetectOnly

# Voller Ablauf: erkennen, Dialog anzeigen, bei Bestätigung installieren
.\Update-Bios.ps1

# BitLocker für mehr/weniger Neustarts aussetzen (Standard: 3)
.\Update-Bios.ps1 -BitLockerRebootCount 2
```

## Ablauf

1. Modell, Hersteller und installierte BIOS-Version per WMI ermitteln
   (`Win32_ComputerSystem`, `Win32_BIOS`).
2. Je nach Hersteller neueste verfügbare Version ermitteln:
   - **HP**: über HP CMSL (`Get-HPDeviceDetails`, `Get-SoftpaqList -Category BIOS`)
   - **Lenovo**: über LSUClient (`Get-LSUpdate`), erkennt Modell und
     Windows-Version automatisch, keine manuelle Machine-Type-Ermittlung
     nötig
3. Versionen vergleichen. Kein Update nötig → Skript endet.
4. Prüfen, ob das Gerät am Netzteil hängt (BIOS-Update im Akkubetrieb wird
   blockiert).
5. GUI-Dialog: "Version X verfügbar, installieren?" — Ja/Nein.
6. Bei "Ja": `Suspend-BitLocker -RebootCount N` auf allen Volumes mit
   aktivem Schutz (verhindert die Wiederherstellungsschlüssel-Abfrage bei
   den BIOS-Update-Neustarts; Schutz aktiviert sich nach N Neustarts von
   selbst wieder — kein manuelles `Resume-BitLocker` nötig, es sei denn,
   es sind absehbar mehr Neustarts als `N`).
7. Update herunterladen und still installieren.

Alles wird nach `logs/bios-update_<Zeitstempel>.log` protokolliert.

## Bekannte Einschränkungen

- Nur HP und Lenovo unterstützt (wie angefragt).
- Geht von genau einer verschlüsselten Systempartition typischer Bauart aus;
  bei ungewöhnlichen BitLocker-Setups (z. B. mehrere Datenvolumes mit
  eigenständigem Schutz) prüfen, ob `Suspend-BitLockerForUpdate` alle
  relevanten Volumes erfasst.
- Kein Rollback-Mechanismus — wie bei jedem BIOS-Update: stabile
  Stromversorgung sicherstellen, Update nicht unterbrechen.
