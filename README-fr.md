# looper

Vérification au déploiement pour les commands, skills et plugins Claude Code — exécute des
tests d'installation, de précision de déclenchement et de suite d'évaluation comportementale
(T5) dans un conteneur Docker CC propre. Utilisé comme étape 5 du pipeline skill-test.

## Installation

```bash
bash install.sh
# ou spécifier un répertoire de configuration Claude personnalisé
bash install.sh --target ~/.claude
# ou utiliser la convention CLAUDE_DIR
CLAUDE_DIR=~/.claude bash install.sh
```

Installe :
- `commands/looper.md → ~/.claude/commands/looper.md`
- `assets/config/.claude.json → ~/.claude/looper/.claude.json`

> ✅ **Vérifié** : couvert par le pipeline skill-test (looper Stage 5).

## Utilisation

```
/looper --plugin <pkg>                    # installer et vérifier packer/<pkg>/
/looper --plugin <pkg> --image <image>   # utiliser une image de conteneur explicite
```

## Prérequis

- **Docker** (doit être disponible sur l'hôte ; dans un devcontainer, looper le détecte et se termine avec un message d'indication)
- **Image CC runtime** (`cc-runtime-minimal` — voir ci-dessous ; inclut python3 pour l'exécution de la suite T5)

## Stratégie d'image

looper détermine l'image de conteneur selon l'ordre de priorité suivant (le résultat est
persisté dans `looper/.looper-state.json` après le premier appel et réutilisé ensuite) :

| Priorité | Source | Notes |
|----------|--------|-------|
| 1 | Flag `--image <image>` | Priorité absolue ; non écrit dans le cache d'état |
| 2 | Cache `.looper-state.json` | Réutilise l'image de l'appel précédent |
| 3 | `.devcontainer/devcontainer.json` | Lit automatiquement l'image standard du projet |
| 4 | `cc-runtime-minimal` local | Précédemment construit ou tiré |
| 5 | Guidance de repli | Fournit les instructions pour obtenir `cc-runtime-minimal` |

### Obtenir cc-runtime-minimal

**Tirer (recommandé) :**
```bash
docker pull easyfan/agents-slim:cc-runtime-minimal
docker tag easyfan/agents-slim:cc-runtime-minimal cc-runtime-minimal
```

**Construire localement** (pour audit de sécurité) :
```bash
docker build -t cc-runtime-minimal assets/image/
```

Source de l'image : [easyfan/agents-slim](https://github.com/easyfan/agents-slim)

## Développement

### Evals

`evals/evals.json` contient 10 cas de test couvrant l'analyse d'arguments, la résolution de
cibles, la détection de disponibilité Docker, les branches de stratégie d'image et l'exécution
de la suite T5 :

| ID | Scénario | Ce qui est vérifié |
|----|----------|--------------------|
| 1 | `/looper --plugin patterns` | Analyse d'arguments, existence du chemin cible, disponibilité Docker ; sortie gracieuse si Docker absent ; T5 déclenché si Docker disponible (evals.json présent) |
| 2 | `/looper --plugin xyz_nonexistent_...` | Affiche "❌ target not found" quand `packer/<pkg>` est absent ; aucun conteneur démarré |
| 3 | `/looper --plugin patterns` (flux complet) | Localise `packer/patterns/`, exécute `install.sh`, construit un environnement propre, exécute T1–T3 |
| 4 | `/looper` (sans arguments) | Affiche le guide d'utilisation ; aucune opération Docker |
| 5 | `/looper --plugin patterns --image my-custom-registry:cc-runtime` | Le flag `--image` définit la stratégie user-specified (priorité 1), ignore la détection devcontainer et le cache |
| 6 | Même cas (avec `.looper-state.json` existant) | Lit le fichier d'état mis en cache, réutilise l'image enregistrée sans re-détection |
| 7 | Vérification de la sortie de stratégie d'image | La sortie d'exécution contient le nom d'image et le label de stratégie (devcontainer / user-specified / fallback / cached) |
| 8 | T5 actif — `/looper --plugin patterns` (evals.json présent) | Step 4 injecte le runner d'eval + evals.json ; si Docker disponible, T5 s'exécute et produit EVAL_SUITE_RESULT |
| 9 | T5 ignoré — `disable_t5: true` dans evals.json | Step 4 note "eval suite: skipped (disable_t5=true)" ; ligne T5 affiche ⏭️ ; résultat global non échoué |

### Désactiver T5

Ajoutez `"disable_t5": true` au niveau racine de `evals.json` pour empêcher looper d'exécuter
la suite d'évaluation dans le conteneur. À utiliser quand l'outil testé est looper lui-même
(Docker-in-Docker serait nécessaire) ou tout autre outil ne pouvant pas s'exécuter dans
l'environnement propre.

```json
{
  "skill_name": "looper",
  "disable_t5": true,
  "evals": [ ... ]
}
```

Step 4 affichera `eval suite: skipped (disable_t5=true in evals.json)`. Le résultat global
n'est pas marqué FAIL pour cette raison.

Tests manuels (dans une session Claude Code) :
```bash
/looper --plugin patterns     # eval 1
/looper                       # eval 4 — afficher le guide d'utilisation
```

Exécuter tous les evals avec le eval loop de skill-creator (si installé) :
```bash
python ~/.claude/skills/skill-creator/scripts/run_loop.py \
  --skill-path ~/.claude/commands/looper.md \
  --evals-path evals/evals.json
```

## Structure du paquet

```
looper/
├── commands/looper.md          # installé dans ~/.claude/commands/
├── assets/
│   ├── config/.claude.json     # installé dans ~/.claude/looper/
│   └── image/                  # source de l'image cc-runtime-minimal
│       ├── Dockerfile
│       └── .github/workflows/build-push.yml
├── evals/evals.json
├── install.sh
└── SKILL.md
```
