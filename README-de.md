# looper

Deploy-Zeit-Verifikation für Claude Code Commands, Skills und Plugins — führt Installations-,
Trigger-Genauigkeits- und Verhaltens-Eval-Suite (T5) Tests in einem sauberen Docker-CC-Container
aus. Wird als Stage 5 der skill-test-Pipeline eingesetzt.

## Installation

```bash
bash install.sh
# oder ein benutzerdefiniertes Claude-Konfigurationsverzeichnis angeben
bash install.sh --target ~/.claude
# oder die CLAUDE_DIR-Konvention verwenden
CLAUDE_DIR=~/.claude bash install.sh
```

Installiert:
- `commands/looper.md → ~/.claude/commands/looper.md`
- `assets/config/.claude.json → ~/.claude/looper/.claude.json`

> ✅ **Verifiziert**: Abgedeckt durch die skill-test-Pipeline (looper Stage 5).

## Verwendung

```
/looper --plugin <pkg>                    # packer/<pkg>/ installieren und verifizieren
/looper --plugin <pkg> --image <image>   # explizites Container-Image verwenden
```

## Voraussetzungen

- **Docker** (muss auf dem Host verfügbar sein; innerhalb eines Devcontainers wird dies erkannt und looper beendet sich mit einem Hinweis)
- **CC-Runtime-Image** (`cc-runtime-minimal` — siehe unten; enthält python3 für die T5-Eval-Ausführung)

## Image-Strategie

looper bestimmt das Container-Image anhand der folgenden Prioritätsreihenfolge (das Ergebnis
wird nach dem ersten Aufruf in `looper/.looper-state.json` gespeichert und bei Folgeaufrufen
wiederverwendet):

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

## Entwicklung

### Evals

`evals/evals.json` enthält 10 Testfälle, die Argument-Parsing, Zielauflösung,
Docker-Verfügbarkeitserkennung, Image-Strategiezweige und die Ausführung der T5-Eval-Suite abdecken:

| ID | Szenario | Was verifiziert wird |
|----|----------|---------------------|
| 1 | `/looper --plugin patterns` | Argument-Parsing, Zielpfad-Existenz, Docker-Verfügbarkeit; graceful Exit bei fehlendem Docker; T5 ausgelöst wenn Docker verfügbar (evals.json vorhanden) |
| 2 | `/looper --plugin xyz_nonexistent_...` | Gibt "❌ target not found" aus wenn `packer/<pkg>` fehlt; kein Container wird gestartet |
| 3 | `/looper --plugin patterns` (vollständiger Ablauf) | Findet `packer/patterns/`, führt `install.sh` aus, baut saubere Umgebung, führt T1–T3 aus |
| 4 | `/looper` (ohne Argumente) | Gibt Verwendungshinweis aus; keine Docker-Operationen |
| 5 | `/looper --plugin patterns --image my-custom-registry:cc-runtime` | `--image` Flag setzt user-specified Strategie (Priorität 1), überspringt devcontainer-Erkennung und Cache |
| 6 | Wie oben (mit vorhandenem `.looper-state.json`) | Liest gecachte State-Datei, verwendet aufgezeichnetes Image ohne Neuerkennnung |
| 7 | Image-Strategie-Ausgabe-Verifikation | Ausführungsausgabe enthält Image-Name und Strategie-Label (devcontainer / user-specified / fallback / cached) |
| 8 | T5 aktiv — `/looper --plugin patterns` (evals.json vorhanden) | Step 4 injiziert Eval-Runner + evals.json; bei verfügbarem Docker läuft T5 und gibt EVAL_SUITE_RESULT aus |
| 9 | T5 übersprungen — `disable_t5: true` in evals.json | Step 4 vermerkt "eval suite: skipped (disable_t5=true)"; T5-Zeile zeigt ⏭️; Gesamtergebnis nicht fehlgeschlagen |

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

Manuelles Testen (in einer Claude Code-Sitzung):
```bash
/looper --plugin patterns     # eval 1
/looper                       # eval 4 — Verwendungshinweis anzeigen
```

Alle Evals mit dem Eval-Loop von skill-creator ausführen (falls installiert):
```bash
python ~/.claude/skills/skill-creator/scripts/run_loop.py \
  --skill-path ~/.claude/commands/looper.md \
  --evals-path evals/evals.json
```

## Paketstruktur

```
looper/
├── commands/looper.md          # installiert nach ~/.claude/commands/
├── assets/
│   ├── config/.claude.json     # installiert nach ~/.claude/looper/
│   └── image/                  # cc-runtime-minimal Image-Quellcode
│       ├── Dockerfile
│       └── .github/workflows/build-push.yml
├── evals/evals.json
├── install.sh
└── SKILL.md
```
