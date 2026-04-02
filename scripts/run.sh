#!/usr/bin/env bash
# looper/scripts/run.sh — Deterministic plugin verification runner
# Usage: run.sh --plugin <name> [--image <image>] [--plan a|b|both]
# stdout: JSON result (machine-readable, for callers)
# stderr: human-readable progress
# exit:   0=all pass, 1=test fail, 2=environment error

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
NAME=""
USER_IMAGE=""
PLAN="both"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin) NAME="$2"; shift 2 ;;
    --image)  USER_IMAGE="$2"; shift 2 ;;
    --plan)   PLAN="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo '{"error":"missing --plugin argument","usage":"run.sh --plugin <name> [--image <img>] [--plan a|b|both]"}' 
  exit 2
fi

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Locate project root (contains packer/ dir)
PROJECT_ROOT="$(pwd)"
if [[ ! -d "$PROJECT_ROOT/packer/$NAME" ]]; then
  # Try walking up
  _d="$PROJECT_ROOT"
  while [[ "$_d" != "/" ]]; do
    if [[ -d "$_d/packer/$NAME" ]]; then
      PROJECT_ROOT="$_d"
      break
    fi
    _d="$(dirname "$_d")"
  done
fi

PLUGIN_PATH="$PROJECT_ROOT/packer/$NAME"
EVALS_JSON="$PLUGIN_PATH/evals/evals.json"
[[ -f "$EVALS_JSON" ]] || EVALS_JSON=""

LOOPER_STATE="$PLUGIN_ROOT/.looper-state.json"
DEVCONTAINER="$PROJECT_ROOT/.devcontainer/devcontainer.json"
CLAUDE_JSON_SRC="$HOME/.claude/looper/.claude.json"
REPORT_DIR="$PLUGIN_ROOT/reports"

# ── Helpers ───────────────────────────────────────────────────────────────────
log() { echo "$*" >&2; }
die() { echo "{\"error\":\"$1\"}" ; exit 2; }

# ── Preflight checks ──────────────────────────────────────────────────────────
[[ -d "$PLUGIN_PATH" ]] || die "plugin path not found: $PLUGIN_PATH"

if ! docker info > /dev/null 2>&1; then
  echo '{"skipped":true,"reason":"docker unavailable"}'
  exit 0
fi

if [[ ! -f "$HOME/.claude/settings.json" ]]; then
  die "settings.json not found: $HOME/.claude/settings.json"
fi

if [[ ! -f "$CLAUDE_JSON_SRC" ]]; then
  die ".claude.json not found: $CLAUDE_JSON_SRC — run looper/install.sh first"
fi

# ── Image selection ───────────────────────────────────────────────────────────
IMAGE=""
IMAGE_STRATEGY=""

if [[ -n "$USER_IMAGE" ]]; then
  IMAGE="$USER_IMAGE"
  IMAGE_STRATEGY="user-specified"
elif [[ -f "$LOOPER_STATE" ]]; then
  _prev=$(python3 -c "
import json,os
try:
  d=json.load(open('$LOOPER_STATE'))
  print(d.get('image','')+' '+d.get('strategy',''))
except: pass
" 2>/dev/null || true)
  IMAGE="${_prev%% *}"
  IMAGE_STRATEGY="local-cached"
fi

if [[ -z "$IMAGE" ]]; then
  if [[ -f "$DEVCONTAINER" ]]; then
    IMAGE=$(grep '"image"' "$DEVCONTAINER" | head -1 | sed 's/.*"image"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
    [[ -n "$IMAGE" ]] && IMAGE_STRATEGY="devcontainer"
  fi
fi

if [[ -z "$IMAGE" ]] && docker image inspect cc-runtime-minimal > /dev/null 2>&1; then
  IMAGE="cc-runtime-minimal"
  IMAGE_STRATEGY="local-cached"
fi

if [[ -z "$IMAGE" ]]; then
  echo "{\"error\":\"no CC runtime image found\",\"hint\":\"docker build -t cc-runtime-minimal $PLUGIN_ROOT/assets/ OR use --image flag\"}"
  exit 2
fi

# Persist image strategy (not for user-specified)
if [[ -z "$USER_IMAGE" ]]; then
  mkdir -p "$(dirname "$LOOPER_STATE")"
  python3 -c "
import json,os
d={'image':'$IMAGE','strategy':'$IMAGE_STRATEGY','timestamp':'$(date -u +%Y-%m-%dT%H:%M:%SZ)'}
open('$LOOPER_STATE','w').write(json.dumps(d,indent=2))
" 2>/dev/null || true
fi

# ── Proxy args ────────────────────────────────────────────────────────────────
PROXY_ENV_ARGS=()
if [[ -f "$DEVCONTAINER" ]]; then
  for key in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy; do
    val=$(grep "\"${key}\"" "$DEVCONTAINER" | head -1 | sed 's/.*"[^"]*"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
    if echo "$val" | grep -q '^\${localEnv:'; then
      envvar=$(echo "$val" | sed 's/\${localEnv:\([^}]*\)}/\1/')
      val="${!envvar:-}"
    fi
    [[ -n "$val" ]] && PROXY_ENV_ARGS+=(-e "${key}=${val}")
  done
fi

# ── Workdir setup ─────────────────────────────────────────────────────────────
LOOPER_TMP=$(mktemp -d "${HOME}/looper_XXXXXX")
CLEAN_CLAUDE="$LOOPER_TMP/claude_home"
mkdir -p "$CLEAN_CLAUDE"

CONTAINER=""
CONTAINER_B=""
cleanup() {
  docker rm -f "$CONTAINER" ${CONTAINER_B:+"$CONTAINER_B"} > /dev/null 2>&1 || true
  rm -rf "${LOOPER_TMP:-}"
}
trap cleanup EXIT INT TERM

# Construct Plan A settings.json (strip hooks, model overrides; alias AUTH_TOKEN→API_KEY)
python3 -c "
import json, re
src = json.load(open('$HOME/.claude/settings.json'))
out = {}
for key in ('env', 'apiKey', 'oauthAccount'):
    if key in src:
        out[key] = src[key]
env = out.get('env', {})
for k in list(env.keys()):
    if re.match(r'ANTHROPIC_(MODEL|DEFAULT_)', k):
        del env[k]
if 'ANTHROPIC_AUTH_TOKEN' in env and 'ANTHROPIC_API_KEY' not in env:
    env['ANTHROPIC_API_KEY'] = env['ANTHROPIC_AUTH_TOKEN']
out['env'] = env
print(json.dumps(out, indent=2))
" > "$CLEAN_CLAUDE/settings.json"

cp "$CLAUDE_JSON_SRC" "$LOOPER_TMP/.claude.json"

# Inject evals (T5)
HAS_EVALS=false
EVAL_COUNT=0
DISABLE_T5="False"
if [[ -n "$EVALS_JSON" ]]; then
  DISABLE_T5=$(python3 -c "import json; d=json.load(open('$EVALS_JSON')); v=d.get('disable_t5',False); print('True' if str(v).lower()=='true' else 'False')" 2>/dev/null || echo "False")
fi
if [[ -n "$EVALS_JSON" && "$DISABLE_T5" != "True" ]]; then
  cp "$EVALS_JSON" "$LOOPER_TMP/evals.json"
  cp "$PLUGIN_ROOT/scripts/run_eval_suite.py" "$LOOPER_TMP/run_eval_suite.py" 2>/dev/null || true
  EVAL_COUNT=$(python3 -c "import json; print(len(json.load(open('$EVALS_JSON'))['evals']))" 2>/dev/null || echo 0)
  HAS_EVALS=true
fi

log "[looper] plugin=$NAME image=$IMAGE strategy=$IMAGE_STRATEGY evals=${EVAL_COUNT:-0}"


# ── Container startup ─────────────────────────────────────────────────────────
CONTAINER="looper_$(date +%s)"
WORK_DIR="/looper_work"

docker run -d \
  --name "$CONTAINER" \
  -w "$WORK_DIR" \
  -v "${CLEAN_CLAUDE}:/root/.claude" \
  -v "${LOOPER_TMP}/.claude.json:/root/.claude.json" \
  -v "${LOOPER_TMP}:${WORK_DIR}" \
  -v "${PLUGIN_PATH}:/plugin_src:ro" \
  ${PROXY_ENV_ARGS:+"${PROXY_ENV_ARGS[@]}"} \
  -e ANTHROPIC_API_KEY="$(python3 -c "import json; e=json.load(open('$HOME/.claude/settings.json')).get('env',{}); print(e.get('ANTHROPIC_API_KEY', e.get('ANTHROPIC_AUTH_TOKEN','')))" 2>/dev/null)" \
  -e ANTHROPIC_BASE_URL="$(python3 -c "import json; print(json.load(open('$HOME/.claude/settings.json')).get('env',{}).get('ANTHROPIC_BASE_URL',''))" 2>/dev/null)" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="64000" \
  -e IS_SANDBOX=1 \
  -e JINA_API_KEY="${JINA_API_KEY:-}" \
  -u root \
  "$IMAGE" sleep infinity > /dev/null \
  || { echo '{"error":"container start failed","image":"'"$IMAGE"'"}'; exit 2; }

log "[looper] container $CONTAINER started"

# ── T0: plugin.json validation (host) ────────────────────────────────────────
T0_PASS="skip"
T0_OUT=""
if command -v claude > /dev/null 2>&1; then
  T0_OUT=$(claude --dangerously-skip-permissions plugin validate "${PLUGIN_PATH}/.claude-plugin/plugin.json" 2>&1 || true)
  echo "$T0_OUT" | grep -q "Validation passed" && T0_PASS="pass" || T0_PASS="fail"
  log "[T0] plugin.json: $T0_PASS"
else
  T0_PASS="skip"
  T0_OUT="claude CLI not found on host"
  log "[T0] skipped (no claude CLI on host)"
fi

# ── T1: CC availability ───────────────────────────────────────────────────────
T1_OUT=$(docker exec "$CONTAINER" claude --version 2>&1 || true)
echo "$T1_OUT" | grep -qi "claude" && T1_PASS="pass" || T1_PASS="fail"
log "[T1] CC version: $T1_OUT → $T1_PASS"

# ── T2: Plan A — install.sh full path ────────────────────────────────────────
T2_PASS="skip"
T2_OUT=""

if [[ "$PLAN" == "a" || "$PLAN" == "both" ]]; then

A1_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh --dry-run 2>&1")
A1_COUNT=$(echo "$A1_OUT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
echo "$A1_OUT" | grep -q "would be modified" && [[ "$A1_COUNT" -gt 0 ]] && A1_PASS="pass" || A1_PASS="fail"

A2_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh --uninstall; echo EXIT:\$?" 2>&1)
echo "$A2_OUT" | grep -q "EXIT:0" && A2_PASS="pass" || A2_PASS="fail"

A3_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh 2>&1")
A3_COUNT=$(echo "$A3_OUT" | grep -oE 'Done! [0-9]+' | grep -oE '[0-9]+' || echo "0")
echo "$A3_OUT" | grep -q "Done!" && [[ "$A3_COUNT" -gt 0 ]] && A3_PASS="pass" || A3_PASS="fail"

A4_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh 2>&1")
echo "$A4_OUT" | grep -qE "Done! 0" && A4_PASS="pass" || A4_PASS="fail"

A5_OUT=$(docker exec "$CONTAINER" bash -c "find /root/.claude/commands /root/.claude/agents /root/.claude/skills -mindepth 1 \( -type f -o -type d \) 2>/dev/null | head -20")
[[ -n "$A5_OUT" ]] && A5_PASS="pass" || A5_PASS="fail"

A6_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh --uninstall 2>&1")
A6_REMOVED=$(echo "$A6_OUT" | grep -c "Removed" || true)
[[ "$A6_REMOVED" -gt 0 ]] && A6_PASS="pass" || A6_PASS="fail"

A7_OUT=$(docker exec "$CONTAINER" bash -c "find /root/.claude/commands /root/.claude/agents /root/.claude/skills -mindepth 1 2>/dev/null | head -5")
[[ -z "$A7_OUT" ]] && A7_PASS="pass" || A7_PASS="fail"

T2_OUT="A1:${A1_PASS} A2:${A2_PASS} A3:${A3_PASS} A4:${A4_PASS} A5:${A5_PASS} A6:${A6_PASS} A7:${A7_PASS}"
T2_PASS="pass"
for _p in $A1_PASS $A2_PASS $A3_PASS $A4_PASS $A5_PASS $A6_PASS $A7_PASS; do
  [[ "$_p" != "pass" ]] && T2_PASS="fail"
done
log "[T2] $T2_OUT → $T2_PASS"

fi # end Plan A


# ── T2b: Plan B — claude plugin install path ──────────────────────────────────
T2B_PASS="skip"
T2B_OUT=""

if [[ "$PLAN" == "b" || "$PLAN" == "both" ]]; then

PLAN_B_CLAUDE="$LOOPER_TMP/claude_home_b"
PLAN_B_SETTINGS="$PLAN_B_CLAUDE/settings.json"
mkdir -p "$PLAN_B_CLAUDE"
python3 -c "
import json, re
src = json.load(open('$HOME/.claude/settings.json'))
out = {}
for key in ('env', 'apiKey', 'oauthAccount'):
    if key in src:
        out[key] = src[key]
env = out.get('env', {})
for k in list(env.keys()):
    if re.match(r'ANTHROPIC_(MODEL|DEFAULT_)', k):
        del env[k]
if 'ANTHROPIC_AUTH_TOKEN' in env and 'ANTHROPIC_API_KEY' not in env:
    env['ANTHROPIC_API_KEY'] = env['ANTHROPIC_AUTH_TOKEN']
out['env'] = env
print(json.dumps(out, indent=2))
" > "$PLAN_B_SETTINGS"

CONTAINER_B="looper_b_$(date +%s)"
docker run -d \
  --name "$CONTAINER_B" \
  -v "${PLAN_B_CLAUDE}:/root/.claude" \
  -v "${LOOPER_TMP}/.claude.json:/root/.claude.json" \
  -v "${PLUGIN_PATH}:/plugin_src:ro" \
  ${PROXY_ENV_ARGS:+"${PROXY_ENV_ARGS[@]}"} \
  -e ANTHROPIC_API_KEY="$(python3 -c "import json; e=json.load(open('$HOME/.claude/settings.json')).get('env',{}); print(e.get('ANTHROPIC_API_KEY', e.get('ANTHROPIC_AUTH_TOKEN','')))" 2>/dev/null)" \
  -e ANTHROPIC_BASE_URL="$(python3 -c "import json; print(json.load(open('$HOME/.claude/settings.json')).get('env',{}).get('ANTHROPIC_BASE_URL',''))" 2>/dev/null)" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="64000" \
  -e IS_SANDBOX=1 \
  -u root \
  "$IMAGE" sleep infinity > /dev/null \
  || { T2B_PASS="fail"; T2B_OUT="container start failed"; CONTAINER_B=""; }

if [[ "$T2B_PASS" == "fail" ]]; then
  log "[T2b] skipped — container start failed"
else

CCB=(docker exec "$CONTAINER_B" claude --dangerously-skip-permissions)

B1_OUT=$("${CCB[@]}" plugin marketplace add "easyfan/$NAME" 2>&1 || true)
B1_SETTINGS=$(python3 -c "
import json
d = json.load(open('$PLAN_B_SETTINGS'))
print('yes' if '$NAME' in d.get('extraKnownMarketplaces',{}) else 'no')
" 2>/dev/null || echo "no")
echo "$B1_OUT" | grep -q "Successfully" && [[ "$B1_SETTINGS" == "yes" ]] && B1_PASS="pass" || B1_PASS="fail"

B2_OUT=$("${CCB[@]}" plugin marketplace update "$NAME" 2>&1 || true)
echo "$B2_OUT" | grep -q "Successfully" && B2_PASS="pass" || B2_PASS="fail"

B3_OUT=$("${CCB[@]}" plugin install "$NAME" 2>&1 || true)
echo "$B3_OUT" | grep -q "Successfully installed" && B3_PASS="pass" || B3_PASS="fail"

B4_OUT=$(docker exec "$CONTAINER_B" bash -c "
  reg=\$HOME/.claude/plugins/marketplaces/$NAME/.claude-plugin/marketplace.json
  [ -f \"\$reg\" ] || { echo 'registry not found'; exit 1; }
  reg_sha=\$(python3 -c \"import json; d=json.load(open('\$reg')); print(d['plugins'][0]['source']['sha'])\" 2>/dev/null) || { echo 'parse error'; exit 1; }
  inst_sha=\$(python3 -c \"
import json,os
p=os.path.expanduser('~/.claude/plugins/installed_plugins.json')
d=json.load(open(p))
for k,vs in d.get('plugins',{}).items():
    for v in vs:
        if 'gitCommitSha' in v: print(v['gitCommitSha']); exit()
\" 2>/dev/null)
  [ \"\$reg_sha\" = \"\$inst_sha\" ] && echo \"match:\$inst_sha\" || echo \"mismatch:registry=\$reg_sha installed=\$inst_sha\"
" 2>&1 || true)
echo "$B4_OUT" | grep -q "^match:" && B4_PASS="pass" || B4_PASS="fail"

B5_OUT=$(docker exec "$CONTAINER_B" bash -c "
  cache_dir=\$(ls -d \$HOME/.claude/plugins/cache/$NAME/$NAME/*/ 2>/dev/null | head -1)
  [ -n \"\$cache_dir\" ] || { echo 'no cache dir'; exit 1; }
  found=0
  for sub in commands agents skills; do
    [ -d \"\$cache_dir/\$sub\" ] && found=\$((found + \$(find \"\$cache_dir/\$sub\" -mindepth 1 -type f | wc -l)))
  done
  echo \"files:\$found\"
" 2>&1 || true)
echo "$B5_OUT" | grep -qE "files:[1-9]" && B5_PASS="pass" || B5_PASS="fail"

B6_OUT=$("${CCB[@]}" plugin uninstall "$NAME" 2>&1 || true)
echo "$B6_OUT" | grep -q "Successfully uninstalled" && B6_PASS="pass" || B6_PASS="fail"
B6_ENTRY=$(docker exec "$CONTAINER_B" python3 -c "
import json,os
p=os.path.expanduser('~/.claude/plugins/installed_plugins.json')
if not os.path.exists(p): print('clean'); exit()
d=json.load(open(p))
print('dirty' if d.get('plugins') else 'clean')
" 2>/dev/null || echo "clean")
[[ "$B6_ENTRY" == "clean" ]] || B6_PASS="fail"

B7_OUT=$("${CCB[@]}" plugin marketplace remove "$NAME" 2>&1 || true)
echo "$B7_OUT" | grep -q "Successfully removed" && B7_PASS="pass" || B7_PASS="fail"

B8_CLEAN=$(python3 -c "
import json
d = json.load(open('$PLAN_B_SETTINGS'))
print('clean' if '$NAME' not in d.get('extraKnownMarketplaces',{}) else 'dirty')
" 2>/dev/null || echo "dirty")
[[ "$B8_CLEAN" == "clean" ]] && B8_PASS="pass" || B8_PASS="fail"

T2B_OUT="B1:${B1_PASS} B2:${B2_PASS} B3:${B3_PASS} B4:${B4_PASS} B5:${B5_PASS} B6:${B6_PASS} B7:${B7_PASS} B8:${B8_PASS}"
T2B_PASS="pass"
for _p in $B1_PASS $B2_PASS $B3_PASS $B4_PASS $B5_PASS $B6_PASS $B7_PASS $B8_PASS; do
  [[ "$_p" != "pass" ]] && T2B_PASS="fail"
done
log "[T2b] $T2B_OUT → $T2B_PASS"

docker rm -f "$CONTAINER_B" > /dev/null 2>&1 || true
CONTAINER_B=""

fi # end Plan B container

fi # end Plan B


# ── T3: Trigger test ──────────────────────────────────────────────────────────
# Re-install first (Plan A A6 uninstalled the plugin)
docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh 2>&1" > /dev/null || true

SKILL_MD_PATH=""
if [[ -f "${PLUGIN_PATH}/SKILL.md" ]]; then
  SKILL_MD_PATH="${PLUGIN_PATH}/SKILL.md"
else
  SKILL_MD_PATH=$(find "$CLEAN_CLAUDE" -name "SKILL.md" 2>/dev/null | head -1 || true)
fi

if [[ -f "$SKILL_MD_PATH" ]]; then
  DESC=$(grep "^description:" "$SKILL_MD_PATH" 2>/dev/null | head -1 | sed 's/^description:[[:space:]]*//')
  TRIGGER_PROMPT="${DESC:0:80}：请处理一个简单示例，无交互直接完成"
else
  TRIGGER_PROMPT="${NAME}：请处理一个简单示例，无交互直接完成"
fi

log "[T3] trigger test starting..."
T3_OUT=$(docker exec "$CONTAINER" bash -c "timeout 120 claude --dangerously-skip-permissions -p '$TRIGGER_PROMPT' 2>&1" || true)

T3_PASS="fail"
if echo "$T3_OUT" | grep -qi "command not found\|no skill\|unknown command\|无法完成\|无法处理\|不知道如何\|无法识别\|抱歉\|我不能\|暂不支持\|没有该功能\|找不到\|不支持该\|无法找到"; then
  T3_PASS="fail"
elif echo "$T3_OUT" | grep -qi "Unable to connect to API\|ENOTFOUND\|ECONNREFUSED\|connection refused\|network error\|Could not connect\|API connection"; then
  T3_PASS="fail"
elif [[ -z "$(echo "$T3_OUT" | tr -d '[:space:]')" ]]; then
  T3_PASS="fail"
else
  T3_PASS="pass"
fi
log "[T3] $T3_PASS"

# ── T5: Eval suite ────────────────────────────────────────────────────────────
T5_PASS="skip"
T5_RATE=""
T5_OUT=""

if [[ "$HAS_EVALS" == "true" ]]; then
  log "[T5] running $EVAL_COUNT eval cases..."
  T5_TMP="$LOOPER_TMP/t5_out_$$.txt"
  docker exec -w "$WORK_DIR" "$CONTAINER" \
    python3 /looper_work/run_eval_suite.py /looper_work/evals.json /looper_work \
    2>&1 | tee "$T5_TMP" >&2 || true
  T5_OUT=$(cat "$T5_TMP")
  rm -f "$T5_TMP"

  T5_JSON=$(echo "$T5_OUT" | grep "^EVAL_SUITE_RESULT:" | tail -1 | sed 's/^EVAL_SUITE_RESULT://')
  if [[ -n "$T5_JSON" ]]; then
    T5_PASSED=$(echo "$T5_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['passed'])" 2>/dev/null || echo 0)
    T5_TOTAL=$(echo "$T5_JSON"  | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['total'])"  2>/dev/null || echo 0)
    T5_RATE="${T5_PASSED}/${T5_TOTAL}"
    [[ "$T5_PASSED" == "$T5_TOTAL" && "${T5_TOTAL:-0}" -gt 0 ]] && T5_PASS="pass" || T5_PASS="fail"
  else
    T5_PASS="fail"
    T5_RATE="parse_error"
  fi
  log "[T5] $T5_RATE → $T5_PASS"
fi

# ── Overall result ────────────────────────────────────────────────────────────
OVERALL="pass"
for _t in "$T0_PASS" "$T1_PASS" "$T2_PASS" "$T2B_PASS" "$T3_PASS"; do
  [[ "$_t" == "fail" ]] && OVERALL="fail"
done
[[ "$T5_PASS" == "fail" ]] && OVERALL="fail"

# ── Persist report ────────────────────────────────────────────────────────────
mkdir -p "$REPORT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="${REPORT_DIR}/${TIMESTAMP}_looper_${NAME}.md"

cat > "$REPORT_FILE" << MDEOF
# Looper Report: ${NAME}

Date: ${TIMESTAMP}  
Image: ${IMAGE} (strategy: ${IMAGE_STRATEGY})  
Overall: ${OVERALL}

## Results

| Test | Result | Detail |
|------|--------|--------|
| T0 plugin.json validate | ${T0_PASS} | ${T0_OUT//|/\|} |
| T1 CC availability | ${T1_PASS} | ${T1_OUT} |
| T2 Plan A (A1–A7) | ${T2_PASS} | ${T2_OUT} |
| T2b Plan B (B1–B8) | ${T2B_PASS} | ${T2B_OUT} |
| T3 trigger test | ${T3_PASS} | (see below) |
| T5 eval suite | ${T5_PASS} | ${T5_RATE} |

## T3 Trigger Output

\`\`\`
${T3_OUT:0:4000}
\`\`\`

## T5 Eval Output

\`\`\`
${T5_OUT}
\`\`\`
MDEOF

log "[looper] report: $REPORT_FILE"

# ── JSON output (stdout) ──────────────────────────────────────────────────────
# Use env vars to pass text fields to python3, avoiding shell-quoting issues
LOOPER_JSON_OUT=$(
  PLUGIN="$NAME" OVERALL="$OVERALL" IMAGE="$IMAGE" \
  IMAGE_STRATEGY="$IMAGE_STRATEGY" TIMESTAMP="$TIMESTAMP" REPORT_FILE="$REPORT_FILE" \
  T0_PASS="$T0_PASS" T0_OUT="$T0_OUT" \
  T1_PASS="$T1_PASS" T1_OUT="$T1_OUT" \
  T2_PASS="$T2_PASS" T2_OUT="$T2_OUT" \
  T2B_PASS="$T2B_PASS" T2B_OUT="$T2B_OUT" \
  T3_PASS="$T3_PASS" T3_OUT="${T3_OUT:0:500}" \
  T5_PASS="$T5_PASS" T5_RATE="$T5_RATE" \
  python3 - << 'PYEOF'
import json, os
result = {
  "plugin":         os.environ["PLUGIN"],
  "overall":        os.environ["OVERALL"],
  "image":          os.environ["IMAGE"],
  "image_strategy": os.environ["IMAGE_STRATEGY"],
  "timestamp":      os.environ["TIMESTAMP"],
  "report_file":    os.environ["REPORT_FILE"],
  "tests": {
    "T0":  {"pass": os.environ["T0_PASS"],  "detail":         os.environ["T0_OUT"]},
    "T1":  {"pass": os.environ["T1_PASS"],  "detail":         os.environ["T1_OUT"]},
    "T2":  {"pass": os.environ["T2_PASS"],  "detail":         os.environ["T2_OUT"]},
    "T2b": {"pass": os.environ["T2B_PASS"], "detail":         os.environ["T2B_OUT"]},
    "T3":  {"pass": os.environ["T3_PASS"],  "output_snippet": os.environ["T3_OUT"]},
    "T5":  {"pass": os.environ["T5_PASS"],  "rate":           os.environ["T5_RATE"]},
  }
}
print(json.dumps(result, indent=2, ensure_ascii=False))
PYEOF
)
echo "$LOOPER_JSON_OUT"

[[ "$OVERALL" == "pass" ]] && exit 0 || exit 1

