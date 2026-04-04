# looper

Vérification au déploiement pour les plugins Claude Code — exécute des tests d'installation,
de précision de déclenchement et de suite d'évaluation comportementale (T5) dans un conteneur
Docker CC propre. Utilisé comme étape 5 du pipeline skill-test.

## Installation

### Option A — Place de marché de plugins Claude Code

```
/plugin marketplace update looper
/plugin install looper@looper
```

> Première utilisation ? Ajoutez d'abord la place de marché :
> ```
> /plugin marketplace add easyfan/looper
> /plugin install looper@looper
> ```

> ⚠️ **Non vérifié par des tests automatisés** : `/plugin` est une commande intégrée du REPL Claude Code et ne peut pas être invoquée via `claude -p`. À exécuter manuellement dans une session Claude Code ; non couvert par le pipeline skill-test (looper Stage 5).

### Option B — Script d'installation

```bash
git clone https://github.com/easyfan/looper
cd looper
bash install.sh
# Aperçu sans écriture
bash install.sh --dry-run
# Supprimer les fichiers installés
bash install.sh --uninstall
# Répertoire de configuration Claude personnalisé (flag ou variable d'environnement)
bash install.sh --target=~/.claude
CLAUDE_DIR=~/.claude bash install.sh
```

Installe :
- `skills/looper/ → ~/.claude/skills/looper/`

> ✅ **Vérifié** : couvert par le pipeline skill-test (looper Stage 5).

### Option C — Manuel

```bash
cp -r skills/looper ~/.claude/skills/looper
```

> ✅ **Vérifié** : couvert par le pipeline skill-test (looper Stage 5).

## Utilisation

```
/looper --plugin <name>                          # vérifier packer/<name>/
/looper --plugin <name> --plan a                 # Plan A uniquement (chemin install.sh)
/looper --plugin <name> --plan b                 # Plan B uniquement (chemin claude plugin install)
/looper --plugin <name> --image <image>          # utiliser une image de conteneur explicite
/looper --help                                   # afficher l'aide
```

## Prérequis

- **Docker** (doit être disponible sur l'hôte ; dans un devcontainer, looper le détecte et se termine gracieusement avec un message d'indication)
- **Image CC runtime** (`cc-runtime-minimal` — voir ci-dessous ; inclut python3 pour l'exécution de la suite T5)

## Stratégie d'image

looper détermine l'image de conteneur selon l'ordre de priorité suivant (le résultat est
persisté dans `packer/<name>/.looper-state.json` après le premier appel et réutilisé ensuite) :

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

## Plans de test

looper exécute deux plans de vérification indépendants. Utilisez `--plan both` (par défaut)
pour tout exécuter, ou `--plan a` / `--plan b` pour un seul plan à la fois.

| Plan | Étapes | Ce qui est vérifié |
|------|--------|-------------------|
| A | T2 (A1–A7) | Conformité de l'interface `install.sh`, installation des fichiers, idempotence, désinstallation, dry-run |
| B | T2b (B1–B8) | Chemin `claude plugin install` (marketplace / `plugin.json` local) |

Ces tests s'exécutent toujours quelle que soit la valeur de `--plan` :

| Test | Ce qui est vérifié |
|------|-------------------|
| T0 | Validation du manifest `plugin.json` (hôte, une seule fois) |
| T1 | Disponibilité de CC dans le conteneur |
| T3 | Précision du déclenchement du skill (un seul appel `claude -p`) |
| T5 | Suite d'évaluation comportementale (exécute `evals/evals.json` dans le conteneur ; ignoré si `disable_t5: true`) |

## Développement

### Evals

`evals/evals.json` contient 7 cas de test pour la CLI actuelle `--plugin` uniquement :

| ID | Scénario | Ce qui est vérifié |
|----|----------|--------------------|
| 1 | `/looper --help` | Le texte d'aide contient les quatre flags et au moins un exemple d'utilisation ; aucun Docker exécuté |
| 2 | `/looper` (sans arguments) | Affiche le guide d'utilisation ; aucune opération Docker |
| 3 | `/looper --plugin xyz_nonexistent_...` | Affiche une erreur plugin introuvable ; aucun conteneur démarré |
| 4 | `/looper --plugin looper --plan a` | Plan A uniquement ; résultat T2b est skip |
| 5 | `/looper --plugin looper --plan b` | Plan B uniquement ; résultat T2 est skip |
| 6 | `/looper --plugin looper --image my-custom-registry:cc-runtime` | Flag `--image` ; stratégie user-specified ; le nom de l'image apparaît dans la sortie |
| 7 | `/looper --plugin looper` | Plugin introuvable dans le conteneur ; sortie d'erreur gracieuse |

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

## Structure du paquet

```
looper/
├── .claude-plugin/
│   ├── plugin.json             # manifest du plugin
│   └── marketplace.json        # entrée marketplace
├── DESIGN.md                   # notes d'architecture
├── skills/looper/
│   └── SKILL.md                # installé dans ~/.claude/skills/looper/
├── scripts/
│   ├── run.sh                  # logique de vérification principale
│   └── run_eval_suite.py       # runner d'eval T5 (injecté dans le conteneur)
├── assets/image/               # source de l'image cc-runtime-minimal
│   ├── Dockerfile
│   └── .github/workflows/build-push.yml
├── test/
│   ├── test-a.sh               # tests hôte Plan A
│   ├── test-b.sh               # tests hôte Plan B
│   └── test-all.sh
├── evals/evals.json
├── install.sh
└── package.json
```
