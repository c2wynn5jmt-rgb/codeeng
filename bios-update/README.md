# BIOS-Update-Skript (HP + Lenovo, Windows)

Erkennt Hersteller/Modell, installierte und neueste verfügbare BIOS-Version,
fragt per Dialog nach, ob aktualisiert werden soll, setzt BitLocker für die
Update-Neustarts aus (kein Wiederherstellungsschlüssel nötig) und installiert
das Update.

## ⚠️ Vor dem produktiven Einsatz unbedingt lesen

Dieses Skript wurde auf einem Mac ohne Windows/HP/Lenovo-Hardware geschrieben
und **noch nicht auf echter Hardware getestet**. Zwei Stellen sind bewusst
mit Unsicherheit markiert (Log-Warnungen im Skript), weil sie je nach Modell
und Software-Version abweichen können:

1. **HP Silent-Install-Switch** (`Install-HPBios`): Nutzt bevorzugt das
   CMSL-native `Install-HPSoftpaq`, falls verfügbar. Fällt sonst auf
   `<installer>.exe /s` zurück — das ist der übliche Silent-Switch für
   HP-Softpaqs, aber nicht für jedes Modell verifiziert.
2. **Lenovo-Katalog-Parsing** (`Get-LenovoLatestBios`): Lädt
   `https://download.lenovo.com/catalog/<MachineType>.xml` und sucht ein
   `Package`-Element mit `Category` enthält "BIOS". Das Katalogschema kann
   je nach Modell leicht variieren. Der Rohkatalog wird bei jedem Lauf unter
   `logs/lenovo-catalog_<MachineType>.xml` gespeichert — bei Fehlern dort
   nachsehen und `Get-LenovoLatestBios` ggf. anpassen (Property-Namen wie
   `Version`, `Location`, `ExtractCommand` prüfen).

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
   - **Lenovo**: über den öffentlichen Lenovo-XML-Katalog für den Machine
     Type (erste 4 Zeichen des Modellnamens)
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
