# looper

Deploy-Zeit-Verifikation für Claude Code Plugins — führt Installations-,
Trigger-Genauigkeits- und Verhaltens-Eval-Suite (T5) Tests in einem sauberen Docker-CC-Container
aus. Wird als Stage 5 der skill-test-Pipeline eingesetzt.

## Installation

### Option A — Claude Code Plugin-Marktplatz

```
/plugin marketplace update looper
/plugin install looper@looper
```

> Erstmalige Nutzung? Zuerst den Marktplatz hinzufügen:
> ```
> /plugin marketplace add easyfan/looper
> /plugin install looper@looper
> ```

> ⚠️ **Nicht durch automatisierte Tests verifiziert**: `/plugin` ist ein Claude Code REPL-Befehl und kann nicht via `claude -p` aufgerufen werden. Manuell in einer Claude Code-Sitzung ausführen; nicht durch die skill-test-Pipeline (looper Stage 5) abgedeckt.

### Option B — Installationsskript

```bash
git clone https://github.com/easyfan/looper
cd looper
bash install.sh
# Vorschau ohne Schreibzugriff
bash install.sh --dry-run
# Installierte Dateien entfernen
bash install.sh --uninstall
# Benutzerdefiniertes Claude-Konfigurationsverzeichnis (Flag oder Umgebungsvariable)
bash install.sh --target=~/.claude
CLAUDE_DIR=~/.claude bash install.sh
```

Installiert:
- `skills/looper/ → ~/.claude/skills/looper/`

> ✅ **Verifiziert**: Abgedeckt durch die skill-test-Pipeline (looper Stage 5).

### Option C — Manuell

```bash
cp -r skills/looper ~/.claude/skills/looper
```

> ✅ **Verifiziert**: Abgedeckt durch die skill-test-Pipeline (looper Stage 5).

## Verwendung

```
/looper --plugin <name>                          # packer/<name>/ verifizieren
/looper --plugin <name> --plan a                 # Nur Plan A (install.sh-Pfad)
/looper --plugin <name> --plan b                 # Nur Plan B (claude plugin install-Pfad)
/looper --plugin <name> --image <image>          # explizites Container-Image verwenden
/looper --help                                   # Verwendungshinweis anzeigen
```

## Voraussetzungen

- **Docker** (muss auf dem Host verfügbar sein; innerhalb eines Devcontainers wird dies erkannt und looper beendet sich mit einem Hinweis)
- **CC-Runtime-Image** (`cc-runtime-minimal` — siehe unten; enthält python3 für die T5-Eval-Ausführung)

## Image-Strategie

looper bestimmt das Container-Image anhand der folgenden Prioritätsreihenfolge (das Ergebnis
wird nach dem ersten Aufruf in `packer/<name>/.looper-state.json` gespeichert und bei
Folgeaufrufen wiederverwendet):

| Priorität | Quelle | Hinweise |
|-----------|--------|----------|
| 1 | `--image <image>` Flag | Explizite Angabe, hat immer Vorrang; wird nicht in den State-Cache geschrieben |
| 2 | `.looper-state.json` Cache | Wiederverwendet das Image aus dem vorherigen Aufruf |
| 3 | `.devcontainer/devcontainer.json` | Liest automatisch das Standard-Image des Projekts |
| 4 | Lokales `cc-runtime-minimal` | Zuvor gebaut oder gepullt |
| 5 | Fallback-Anleitung | Gibt Anweisungen zum Beziehen von `cc-runtime-minimal` aus |

### cc-runtime-minimal beziehen

**Pullen (empfohlen):**
```bash
docker pull easyfan/agents-slim:cc-runtime-minimal
docker tag easyfan/agents-slim:cc-runtime-minimal cc-runtime-minimal
```

**Lokal bauen** (für Sicherheitsaudits):
```bash
docker build -t cc-runtime-minimal assets/image/
```

Image-Quellcode: [easyfan/agents-slim](https://github.com/easyfan/agents-slim)

## Testpläne

looper führt zwei unabhängige Verifikationspläne aus. Mit `--plan both` (Standard) werden alle
Tests ausgeführt, mit `--plan a` bzw. `--plan b` jeweils nur ein Plan.

| Plan | Schritte | Was verifiziert wird |
|------|----------|---------------------|
| A | T2 (A1–A7) | `install.sh`-Schnittstellenkonformität, Dateiinstallation, Idempotenz, Deinstallation, Dry-run |
| B | T2b (B1–B8) | `claude plugin install`-Pfad (Marketplace / lokale `plugin.json`) |

Diese Tests laufen unabhängig vom `--plan`-Parameter immer mit:

| Test | Was verifiziert wird |
|------|---------------------|
| T0 | `plugin.json`-Manifest-Validierung (Host, einmalig) |
| T1 | CC-Verfügbarkeit im Container |
| T3 | Skill-Trigger-Genauigkeit (einzelner `claude -p`-Aufruf) |
| T5 | Verhaltens-Eval-Suite (führt `evals/evals.json` im Container aus; übersprungen bei `disable_t5: true`) |

## Entwicklung

### Evals

`evals/evals.json` enthält 7 Testfälle für die aktuelle `--plugin`-only-CLI:

| ID | Szenario | Was verifiziert wird |
|----|----------|---------------------|
| 1 | `/looper --help` | Hilfetext enthält alle vier Flags und mindestens ein Verwendungsbeispiel; kein Docker ausgeführt |
| 2 | `/looper` (ohne Argumente) | Gibt Verwendungshinweis aus; keine Docker-Operationen |
| 3 | `/looper --plugin xyz_nonexistent_...` | Gibt Fehler "Plugin nicht gefunden" aus; kein Container gestartet |
| 4 | `/looper --plugin looper --plan a` | Nur Plan A; T2b-Ergebnis ist skip |
| 5 | `/looper --plugin looper --plan b` | Nur Plan B; T2-Ergebnis ist skip |
| 6 | `/looper --plugin looper --image my-custom-registry:cc-runtime` | `--image` Flag; user-specified Strategie; Image-Name erscheint in der Ausgabe |
| 7 | `/looper --plugin looper` | Plugin im Container nicht gefunden; graceful Fehlerausgabe |

### T5 deaktivieren

`"disable_t5": true` auf der obersten Ebene von `evals.json` verhindert, dass looper die
Eval-Suite im Container ausführt. Geeignet wenn das zu testende Tool looper selbst ist
(Docker-in-Docker wäre erforderlich) oder andere Tools, die nicht in der sauberen Umgebung
ausgeführt werden können.

```json
{
  "skill_name": "looper",
  "disable_t5": true,
  "evals": [ ... ]
}
```

Step 4 gibt `eval suite: skipped (disable_t5=true in evals.json)` aus. Das Gesamtergebnis
wird dadurch nicht als FAIL markiert.

## Paketstruktur

```
looper/
├── .claude-plugin/
│   ├── plugin.json             # Plugin-Manifest
│   └── marketplace.json        # Marketplace-Eintrag
├── DESIGN.md                   # Architekturnotizen
├── skills/looper/
│   └── SKILL.md                # installiert nach ~/.claude/skills/looper/
├── scripts/
│   ├── run.sh                  # Kern-Verifikationslogik
│   └── run_eval_suite.py       # T5 Eval-Runner (in Container injiziert)
├── assets/image/               # cc-runtime-minimal Image-Quellcode
│   ├── Dockerfile
│   └── .github/workflows/build-push.yml
├── test/
│   ├── test-a.sh               # Plan A Host-Tests
│   ├── test-b.sh               # Plan B Host-Tests
│   └── test-all.sh
├── evals/evals.json
├── install.sh
└── package.json
```
