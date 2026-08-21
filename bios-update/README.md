# BIOS-Update-Tool (HP + Lenovo, Windows)

Erkennt Hersteller/Modell, installierte und neueste verfügbare BIOS-Version,
fragt per Dialog nach, ob aktualisiert werden soll, setzt BitLocker für die
Update-Neustarts aus (kein Wiederherstellungsschlüssel nötig) und installiert
das Update.

Zwei Frontends, dieselbe Logik (`BiosUpdateCore.ps1`):

- **`Update-Bios.ps1`** — Kommandozeile, für Automatisierung/Skripting.
- **`Update-Bios-GUI.ps1`** — Fenster mit Prüfen-/Installieren-Buttons,
  Fortschrittsanzeige und Log-Bereich. Für den täglichen Gebrauch gedacht,
  auch für Kolleg:innen ohne PowerShell-Erfahrung (siehe Abschnitt GUI).

Für die Weitergabe an Kolleg:innen lässt sich die GUI zu einer einzelnen
**`BIOS-Update.exe`** (mit eigenem Icon) kompilieren — siehe Abschnitt
[Eigenständige .exe bauen](#eigenständige-exe-bauen).

## ⚠️ Vor dem produktiven Einsatz unbedingt lesen

Dieses Skript wurde auf einem Mac ohne Windows/HP/Lenovo-Hardware geschrieben
und ist **noch nicht vollständig auf echter Hardware getestet**. Erkennung
(Modell, installierte Version) wurde bereits erfolgreich auf einem Lenovo
Testgerät verifiziert. Eine Stelle ist bewusst mit Unsicherheit markiert
(Log-Warnung im Skript):

- **HP-Installation** (`Install-HPBios`): Nutzt bevorzugt
  `Get-HPBIOSUpdates -Flash -Bitlocker suspend` — laut mehreren
  Community-Quellen (u. a. [techuisitive.com](https://techuisitive.com/updating-bios-version-with-hp-cmsl/))
  das seit ca. 2020 von HP empfohlene Kombi-Cmdlet, das Erkennung, Flash
  und BitLocker in einem Aufruf erledigt und die alte manuelle
  Softpaq-Download/Install-Kette ablöst. **Nicht gegen HPs primäre
  Dokumentation verifiziert** (developers.hp.com blockierte automatisierte
  Zugriffe mit HTTP 403 beim Schreiben dieses Tools) — basiert auf
  Sekundärquellen. Fällt auf die alte, manuelle Kette
  (`Get-Softpaq`/`Install-HPSoftpaq`/`<installer>.exe /s`) zurück, falls
  `Get-HPBIOSUpdates` auf einer älteren HPCMSL-Version nicht existiert.

**Getestet und gefixt (2026-08-21, HP ENVY x360 Convertible 15-ee0xxx):**
Erkennung lief sofort korrekt (Hersteller, Modell, installierte BIOS-Version
F.24). `Install-Module -Name HPCMSL ... -AcceptLicense` brach danach ab mit
"Es wurde kein Parameter gefunden, der dem Parameternamen 'AcceptLicense'
entspricht" — das mit Windows PowerShell 5.1 mitgelieferte PowerShellGet
(1.0.0.1) kennt `-AcceptLicense` noch nicht (erst ab PowerShellGet 2.0.0).
Behoben, indem `Initialize-PSGalleryAccess` PowerShellGet bei Bedarf zuerst
non-interaktiv auf mindestens 2.2.5 aktualisiert, bevor HPCMSL installiert
wird. Dabei zusätzlich `-AllowClobber` nötig: das aktualisierte PowerShellGet
zieht die Abhängigkeit `PackageManagement` mit, deren Cmdlets im laufenden
System schon geladen sind — ohne `-AllowClobber` bricht das mit
"CommandAlreadyAvailable" ab (auf echter HP-Hardware verifiziert,
2026-08-22).

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

# Countdown vor dem automatischen Neustart anpassen (Standard: 60 Sekunden)
.\Update-Bios.ps1 -RestartCountdownSeconds 120

# GUI direkt starten (statt per .bat):
.\Update-Bios-GUI.ps1
```

## GUI (`Update-Bios-GUI.ps1`)

Start per Doppelklick auf `Run-Update-Bios-GUI.bat` (fragt per UAC nach
Admin) oder direkt per PowerShell wie oben.

- Beim Öffnen wird automatisch einmal geprüft (Hersteller, Modell,
  installierte und neueste Version erscheinen oben im Fenster).
- **Prüfen** stößt die Erkennung erneut an.
- **Installieren** ist nur aktiv, wenn ein Update gefunden wurde. Fragt vor
  dem Start noch einmal per Dialog nach, prüft Netzteil-Anschluss, setzt
  BitLocker aus und installiert dann im Hintergrund — das Fenster bleibt
  währenddessen bedienbar, der Log-Bereich unten füllt sich live.
- Erkennung und Installation laufen asynchron in einer **einzigen,
  dauerhaft offenen PowerShell-Runspace** (nicht `Start-Job`/separater
  Prozess), damit das Fenster nicht einfriert. Der Vorteil gegenüber
  `Start-Job`: Das Ergebnis von "Prüfen" (inkl. z. B. des
  LSUClient-Paketobjekts für Lenovo) bleibt als `$global:lastLatest` *in
  dieser Runspace* im Speicher und wird von "Installieren" direkt
  weiterverwendet — ohne den langsamen Update-Katalog ein zweites Mal
  komplett abzufragen. Bei `Start-Job` hätte der Prozesswechsel dieses
  Objekt auf reine Daten reduziert und seine Typinformation verloren,
  weshalb frühere Versionen dort zwangsweise doppelt abgefragt haben.
- Ist die letzte Prüfung älter als `-MaxCheckAgeMinutes` (Standard: 20),
  fordert "Installieren" zu einem erneuten "Prüfen" auf statt mit
  möglicherweise veralteten Daten zu installieren.
- Schließen des Fensters während ein Vorgang läuft fragt vorher noch einmal
  nach.

**Grenze von `Get-LSUpdate` (Lenovo):** Es gibt keinen eingebauten
Kategorie-Filter — jeder Aufruf lädt und prüft grundsätzlich alle
Pakete (Treiber, Firmware, Dolby Vision, etc.), nicht nur BIOS. Ein
`Where-Object`-Filter danach spart keine Zeit, weil zu dem Zeitpunkt schon
alles geladen wurde ([LSUClient-Dokumentation](https://jantari.github.io/LSUClient-docs/docs/cmdlets/get-lsupdate/)).
Das lässt sich an der Quelle nicht abkürzen — die einzige Stellschraube auf
unserer Seite ist, den Katalog nicht öfter als nötig abzufragen (siehe
oben).

**Noch nicht auf echter Hardware getestet** (im Gegensatz zur
Kommandozeilen-Variante, die bereits erfolgreich Erkennung auf einem
Lenovo-Testgerät durchlaufen hat). Die zugrundeliegende Logik ist identisch
und schon verifiziert — was neu und ungetestet ist, ist ausschließlich die
Bedienoberfläche und die Runspace-basierte asynchrone Ausführung selbst.
Bei seltsamem Verhalten (Buttons reagieren nicht, Log aktualisiert sich
nicht) zuerst `Update-Bios.ps1` direkt in der Konsole zum Vergleich laufen
lassen.

## Eigenständige .exe bauen

Für die Weitergabe reicht eine einzelne Datei, kein Ordner mit mehreren
`.ps1`/`.bat`-Dateien mehr. `Build-Exe.ps1` fasst `Update-Bios-GUI.ps1` und
`BiosUpdateCore.ps1` zusammen (Core-Code wird als Text eingebettet, nicht
als separate Datei danebengelegt) und kompiliert sie mit
[ps2exe](https://github.com/MScholtes/PS2EXE) zu `BIOS-Update.exe`, inkl.
eigenem Icon (`bios-update.ico`).

**Wichtig: Das muss einmalig auf einem Windows-Rechner mit Internetzugang
laufen** — der Build selbst wurde beim Schreiben dieses Tools nicht
ausgeführt (keine Windows-Umgebung verfügbar), nur der PowerShell-Code
dahinter geprüft (Klammern-/Encoding-Konsistenz). Bitte einmal testen,
bevor die exe verteilt wird.

```powershell
.\Build-Exe.ps1
```

Installiert bei Bedarf automatisch das `ps2exe`-Modul aus der PowerShell
Gallery, erzeugt `BIOS-Update.exe` im selben Ordner und räumt die
Zwischen-Datei (`Update-Bios-GUI.Combined.ps1`) danach wieder auf.

**Danach reicht `BIOS-Update.exe` allein** — kein `BiosUpdateCore.ps1`
mehr nötig daneben, keine `.bat`-Datei, und auch das Execution-Policy-Thema
von weiter oben entfällt komplett: kompilierte `.exe`-Dateien unterliegen
nicht der PowerShell-Skript-Ausführungsrichtlinie. Per Doppelklick fragt
Windows direkt per UAC nach Administratorrechten (eingebaut über
`-requireAdmin`), ganz ohne den bisherigen `.bat`-Umweg.

`Update-Bios.ps1` (Kommandozeile) bleibt weiterhin auf `BiosUpdateCore.ps1`
als separate Datei angewiesen — nur die GUI wird zur eigenständigen exe.

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

   **Wichtig beim Testen (verifiziert 2026-08-21):** Jeder erneute Aufruf
   von `Suspend-BitLockerForUpdate` setzt den Zähler wieder auf `N` zurück,
   er zählt nicht kumulativ über mehrere Skript-Läufe. Wer das Tool
   mehrfach hintereinander testet (z. B. Installation mehrmals anstößt),
   sieht BitLocker also länger als `N` Neustarts pausiert — das ist kein
   Bug, sondern der Zähler startet bei jedem Lauf neu. Auf einem
   Lenovo-Testgerät hat sich der Schutz nach 3 Neustarts **ohne**
   zwischenzeitlichen erneuten Skript-Aufruf wie erwartet automatisch
   wieder aktiviert.
7. Update herunterladen und still installieren.
8. **Neustart:** Weder `Get-HPBIOSUpdates -Flash` noch `Install-LSUpdate`
   starten das Gerät selbst neu — beide "stagen" das Update nur, wirksam
   wird es erst beim nächsten Boot. Deshalb zeigt `Invoke-PostUpdateRestart`
   danach einen Countdown-Dialog (Standard: 60 Sekunden, per
   `-RestartCountdownSeconds` änderbar) mit "Jetzt neu starten" /
   "Abbrechen". Ohne Bestätigung nach Ablauf des Countdowns startet das
   Gerät automatisch neu (`Restart-Computer -Force`); bei "Abbrechen" bleibt
   es an, mit einer Log-Warnung, dass zeitnah manuell neu gestartet werden
   sollte (BitLocker bleibt sonst unbegrenzt ausgesetzt, da
   `-RebootCount` nur bei tatsächlichen Neustarts runterzählt).

Alles wird nach `logs/bios-update_<Zeitstempel>.log` protokolliert.

## Bekannte Einschränkungen

- Nur HP und Lenovo unterstützt (wie angefragt).
- Geht von genau einer verschlüsselten Systempartition typischer Bauart aus;
  bei ungewöhnlichen BitLocker-Setups (z. B. mehrere Datenvolumes mit
  eigenständigem Schutz) prüfen, ob `Suspend-BitLockerForUpdate` alle
  relevanten Volumes erfasst.
- Kein Rollback-Mechanismus — wie bei jedem BIOS-Update: stabile
  Stromversorgung sicherstellen, Update nicht unterbrechen.
