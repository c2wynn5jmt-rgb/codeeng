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
non-interaktiv auf mindestens 2.2.5 aktualisiert (mit `-AllowClobber`, weil
das dabei mitgezogene `PackageManagement`-Update sonst mit
"CommandAlreadyAvailable" abbricht — dessen Cmdlets sind im laufenden System
schon geladen).

**Zweiter Fund, selbes Gerät:** Auch danach schlug der `Install-Module
HPCMSL -AcceptLicense`-Aufruf im selben Skript-Lauf noch mit demselben
Fehler fehl — das frisch installierte PowerShellGet wirkt laut Microsoft
nicht im laufenden Prozess (die alte PowerShellGet-Assembly ist schon
geladen und lässt sich zur Laufzeit nicht austauschen; `Import-Module
-Force` lädt zwar neue Funktionen nach, der bereits gebundene
`Install-Module`-Befehl bleibt aber der alte). Behoben mit
`Install-ModuleAcceptingLicense`: prüft, ob `-AcceptLicense` im aktuellen
Prozess verfügbar ist — falls nicht, wird HPCMSL stattdessen in einem
frischen `powershell.exe`-Kindprozess installiert, der PowerShellGet neu von
der Platte lädt (verifiziert 2026-08-22).

**Dritter Fund, selbes Gerät:** Nach erfolgreicher HPCMSL-Installation brach
die Plattform-Erkennung ab — `Get-HPDeviceDetails` liefert auf dieser
Hardware weder `Base Board Product` noch `Platform` (beides ungetestet
geraten, da HPs Primärdoku beim Schreiben nicht zugänglich war). Behoben,
indem mehrere bekannte Property-Namen probiert werden und zusätzlich über
`Win32_BaseBoard` (WMI, unabhängig von HPCMSL) nachgefasst wird; schlägt
alles fehl, wird die volle `Get-HPDeviceDetails`-Ausgabe ins Log geschrieben
statt nur ein Fehler ohne Kontext.

**Vierter Fund, selbes Gerät:** Plattform-ID (`876F`) wurde danach korrekt
erkannt, aber `Get-SoftpaqList` brach mit HTTP 404 ab
(`Could not find data file .../876f_64_11.0.25h2.cab`) — ohne `-Os`/`-OsVer`
ermittelt HPCMSL die installierte Windows-Version selbst (hier 25H2) und
holt die dazu passende HP-Referenzkatalogdatei; für eine sehr neue
Windows-Version kann die bei HP noch fehlen. Behoben mit einem Fallback auf
ältere Referenzversionen (`24H2`/`23H2`/`22H2`/`21H2`) nach demselben
Prinzip wie beim Lenovo-404-Fix weiter oben — BIOS-Softpaqs sind i. d. R.
nicht OS-Versions-spezifisch, nur die Katalog-Referenzdatei ist es
(Fallback-Liste selbst nicht gegen HPs Katalog verifiziert, s. o. zur
Doku-Zugänglichkeit).

**Fünfter Fund, selbes Gerät — vermutlich eine Geräte-Einschränkung, kein
Skript-Bug:** Alle vier Fallback-Versionen scheiterten ebenfalls mit
"Could not find data file". Zur Diagnose direkt `Get-HPBIOSUpdates` (das
andere, in `Install-HPBios` als primär bevorzugte HP-Cmdlet) separat
aufgerufen — schlägt mit derselben Meldung fehl: *"Unable to retrieve BIOS
data for a platform with ID 876F (data file not found)"*. Zwei
unterschiedliche HPCMSL-Cmdlets scheitern identisch, unabhängig von der
OS-Version — das spricht dafür, dass HP für diese Plattform-ID schlicht
keine Katalogdaten hinterlegt hat, nicht für eine falsche OS-Version-Wahl.
HP CMSL/HPIA ist primär für Business-Geräte (EliteBook/ProBook/ZBook)
ausgelegt; Consumer-Modelle (Envy/Pavilion/Spectre — wie das Testgerät, ein
HP ENVY x360 Convertible 15-ee0xxx) fehlen im HPIA-Katalog teils komplett.
**Nächster Schritt:** auf einem HP-Business-Gerät testen (das eigentliche
Zielgerät für den Bechtle-Einsatz), dort sollte die Katalogabdeckung
vorhanden sein. Die Fehlermeldung im Skript wurde für diesen Fall klarer
gemacht (erkennt "data file not found" und weist direkt auf die vermutliche
Ursache hin), statt nur einen rohen HTTP-404-Fehler zu zeigen.

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
- **Prüfen** stößt die Erkennung erneut an und füllt die Liste
  **"Verfügbare Versionen"** mit den letzten 5 Katalog-Einträgen
  (HP: aus `Get-SoftpaqList`, Lenovo: aus `Get-LSUpdate` - dort i. d. R. nur
  1 Eintrag, da Lenovos Katalog meist nur die aktuell anwendbare Version
  führt, keine Historie). Oberster Eintrag = neueste verfügbare Version.
- **Installieren** installiert die in der Liste **ausgewählte** Version
  (Standard: die oberste/neueste, wie bisher) und ist aktiv, sobald
  mindestens ein Katalog-Eintrag vorliegt - auch wenn das BIOS laut
  Erkennung schon aktuell ist, damit gezielt eine **ältere Version
  installiert werden kann (Rollback)**. Fragt vor dem Start noch einmal per
  Dialog nach (mit Hinweis, falls keine neueste Version gewählt wurde),
  prüft Netzteil-Anschluss, setzt BitLocker aus und installiert dann im
  Hintergrund — das Fenster bleibt währenddessen bedienbar, der Log-Bereich
  unten füllt sich live.
  **Wichtig bei HP:** `Get-HPBIOSUpdates -Flash` installiert immer HPs
  eigene empfohlene (= neueste) Version, unabhängig vom übergebenen
  Softpaq - für eine gezielt ausgewählte ältere Version schaltet
  `Install-HPBios` deshalb automatisch auf den manuellen
  Softpaq-Download/Install-Weg um, der eine bestimmte Id ansteuern kann.
  Bei Lenovo (LSUClient) ist das kein Thema, `Install-LSUpdate` installiert
  ohnehin immer das übergebene Paketobjekt gezielt.
- Erkennung und Installation laufen asynchron in einer **einzigen,
  dauerhaft offenen PowerShell-Runspace** (nicht `Start-Job`/separater
  Prozess), damit das Fenster nicht einfriert. Der Vorteil gegenüber
  `Start-Job`: Das Ergebnis von "Prüfen" (inkl. z. B. des
  LSUClient-Paketobjekts für Lenovo) bleibt als `$global:lastAvailableVersions`
  *in dieser Runspace* im Speicher und wird von "Installieren" direkt
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

**Versionsauswahl/Rollback (2026-08-22) noch nicht auf echter Hardware
getestet:** Die Liste "Verfügbare Versionen" plus gezielte Installation
einer nicht-neuesten Version wurde am Schreibtisch entworfen (Mac, keine
Windows/HP/Lenovo-Hardware) und nur auf Klammern-/Syntax-Konsistenz
geprüft, kein Live-Test. Insbesondere unklar: ob `Get-Softpaq -Number
<Id>` für eine ältere, nicht mehr "aktuellste" HP-Softpaq-Id noch
funktioniert (HP könnte alte Downloads aus dem aktiven Katalog entfernen),
und ob das GUI-Layout mit dem neuen Listenfeld bei allen Fenstergrößen
sauber aussieht. Vor produktivem Rollback-Einsatz auf einem Testgerät
prüfen.

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
