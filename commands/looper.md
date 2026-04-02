---
description: 在纯净 Docker CC 容器中对 packer/<pkg>/ 安装包做安装完整性和触发准确性的部署验证。当 skill-test pipeline 阶段 5 需要 looper 部署验证，或用户说"跑 looper 验证"、"纯净环境测试 <名称>"、"/looper --plugin <名称>"时使用。
allowed-tools: ["Bash", "Read", "Write"]
---
# Looper — 纯净 CC 环境部署验证

## 使用方式

```
/looper --plugin <pkg>                 # 安装并验证 packer/<pkg>/ 包
/looper --plugin <pkg> --image <img>   # 显式指定镜像（覆盖 devcontainer/缓存）
```

**示例**：
- `/looper --plugin news-digest` — 安装 news-digest 包后验证触发率
- `/looper --plugin news-digest --image node:20-slim` — 使用指定镜像验证

---

> **执行前提**：必须在包含 `packer/` 子目录的项目根目录下触发本命令。需先执行 `packer/looper/install.sh` 完成 looper 初始化安装（会安装 `.claude.json` 到 `~/.claude/looper/`）；缺失时 Step 4 会报错并提示完整路径。

## Step 0：解析参数

从 `$ARGUMENTS` 提取：
- `--plugin <name>` → NAME=`<name>`
- `--image <image>` → USER_IMAGE=`<image>`（可选，显式指定镜像；覆盖 devcontainer 和状态缓存）

```bash
NAME=$(echo "$ARGUMENTS" | grep -oP '(?<=--plugin\s)\S+' || echo "")
USER_IMAGE=$(echo "$ARGUMENTS" | grep -oP '(?<=--image\s)\S+' || echo "")
if [ -z "$NAME" ]; then
  echo "❌ 缺少 --plugin 参数"
  echo "用法：/looper --plugin <pkg> [--image <image>]"
  echo "示例："
  echo "  /looper --plugin news-digest                     — 验证 news-digest 安装包"
  echo "  /looper --plugin news-digest --image node:20-slim  — 使用指定镜像验证"
  exit 1
fi
```

若参数为空或格式不合法，输出用法说明后退出：

```
用法：/looper --plugin <pkg> [--image <image>]
示例：
  /looper --plugin news-digest                     — 验证 news-digest 安装包
  /looper --plugin news-digest --image node:20-slim  — 使用指定镜像验证
```

---

## Step 1：解析目标路径

```bash
# plugin：项目 packer 目录
PLUGIN_PATH="$(pwd)/packer/${NAME}"
```

```bash
# Locate evals.json for T5 (optional — T5 skipped if not found)
EVALS_JSON="${PLUGIN_PATH}/evals/evals.json"
[ -f "$EVALS_JSON" ] || EVALS_JSON=""
```

若目标不存在，输出后退出（**不启动容器**）：

```
❌ 目标未找到：plugin:<NAME>
  期望路径：<PLUGIN_PATH>
  请确认名称拼写，或检查 packer/ 目录后重试。
```

---

## Step 2：检查 Docker 可用性

```bash
docker info > /dev/null 2>&1
```

若 Docker 不可用：

```
⚠️ Docker 不可用，无法启动纯净 CC 容器。
  当前环境跳过 looper 部署验证。
  若需完整验证，请在安装了 Docker 的环境中执行：
    /looper --plugin <NAME>
```

输出提示后以 exit 0 退出（不算失败）。

---

## Step 3：镜像策略选择

> **优先级**：`--image` 参数 > 状态文件缓存（非首次调用）> devcontainer.json > 本地 cc-runtime-minimal > fallback 提示

```bash
LOOPER_STATE="$(pwd)/looper/.looper-state.json"
DEVCONTAINER="$(pwd)/.devcontainer/devcontainer.json"
IMAGE=""
IMAGE_STRATEGY=""

# 非首次调用：读取状态文件缓存（USER_IMAGE 存在时跳过）
if [ -f "$LOOPER_STATE" ] && [ -z "${USER_IMAGE:-}" ]; then
  _prev=$(LOOPER_STATE="$LOOPER_STATE" python3 -c "
import json, os, sys
try:
  d = json.load(open(os.environ['LOOPER_STATE']))
  print(d.get('image','') + '|||' + d.get('strategy',''))
except Exception as e:
  print(f'⚠️ 状态文件解析失败（将重新检测镜像）：{e}')
")
  if [ -n "$_prev" ]; then
    IMAGE="${_prev%%|||*}"
    IMAGE_STRATEGY="cached（沿用：${_prev##*|||}）"
  fi
fi

# 首次调用 / USER_IMAGE 强制覆盖
if [ -z "$IMAGE" ] || [ -n "${USER_IMAGE:-}" ]; then
  IMAGE=""
  IMAGE_STRATEGY=""

  # 优先级 1：--image 参数（最高优先级，覆盖一切）
  if [ -n "${USER_IMAGE:-}" ]; then
    IMAGE="$USER_IMAGE"
    IMAGE_STRATEGY="user-specified（--image 参数）"
  fi

  # 优先级 2：devcontainer.json（grep 提取，避免 // 在 URL 中破坏 JSON 解析）
  if [ -z "$IMAGE" ] && [ -f "$DEVCONTAINER" ]; then
    IMAGE=$(grep '"image"' "$DEVCONTAINER" | head -1 | sed 's/.*"image"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [ -n "$IMAGE" ] && IMAGE_STRATEGY="devcontainer（自动检测）"
  fi

  # 优先级 3：本地已有 cc-runtime-minimal
  if [ -z "$IMAGE" ] && docker image inspect cc-runtime-minimal > /dev/null 2>&1; then
    IMAGE="cc-runtime-minimal"
    IMAGE_STRATEGY="local-cached（cc-runtime-minimal）"
  fi

  # 优先级 4：fallback — 引导用户获取镜像
  if [ -z "$IMAGE" ]; then
    echo "⚠️  未检测到可用的 CC runtime 镜像。"
    echo "  选项 A（本地构建）：docker build -t cc-runtime-minimal $(pwd)/packer/looper/assets/"
    echo "  选项 B（指定镜像）：/looper --plugin ${NAME} --image <image>"
    exit 0
  fi

  # 持久化镜像策略到状态文件（--image 显式指定时不写入，避免临时测试镜像污染后续调用）
  if [ -z "${USER_IMAGE:-}" ]; then
    mkdir -p "$(dirname "$LOOPER_STATE")"
    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    LOOPER_STATE="$LOOPER_STATE" _IMAGE="$IMAGE" _STRATEGY="$IMAGE_STRATEGY" _TS="$_ts" python3 -c "
import json, os
d = {'image': os.environ['_IMAGE'], 'strategy': os.environ['_STRATEGY'], 'timestamp': os.environ['_TS']}
open(os.environ['LOOPER_STATE'], 'w').write(json.dumps(d, indent=2, ensure_ascii=False))
" || echo "⚠️ 镜像策略缓存写入失败（下次运行将重新检测）：$LOOPER_STATE" >&2
  fi
fi

# 从 devcontainer.json remoteEnv 读取代理配置，透传到容器
# ${localEnv:VAR} 格式从宿主机环境变量取值
PROXY_ENV_ARGS=()
if [ -f "$DEVCONTAINER" ]; then
  for key in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy; do
    val=$(grep "\"${key}\"" "$DEVCONTAINER" | head -1 | sed 's/.*"[^"]*"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    if echo "$val" | grep -q '^\${localEnv:'; then
      envvar=$(echo "$val" | sed 's/\${localEnv:\([^}]*\)}/\1/')
      val="${!envvar:-}"
    fi
    [ -n "$val" ] && PROXY_ENV_ARGS+=(-e "${key}=${val}")
  done
fi

# .claude.json（CC 入门跳过配置）——复制到 LOOPER_TMP 后以读写方式挂载
# CC 2.1.71+ 启动时需写入该文件；:ro 只读挂载会导致 EROFS 错误并静默退出
# 由 install.sh 安装到 ~/.claude/looper/.claude.json
CLAUDE_JSON_SRC="$HOME/.claude/looper/.claude.json"
```

---

## Step 4：构建纯净 CC 工作目录

> **纯净原则**：容器内 `~/.claude/` 只含 `settings.json`（API 凭证，以只读 volume 挂载，不复制到临时目录）+ 被测目标，不挂载宿主机完整 `~/.claude/`，确保零其他工具链干扰。

```bash
LOOPER_TMP=$(mktemp -d "${HOME}/looper_XXXXXX")
CLEAN_CLAUDE="$LOOPER_TMP/claude_home"
mkdir -p "$CLEAN_CLAUDE"

# 注册 trap：确保容器和临时目录在任意退出路径（含 SIGINT/SIGTERM）下均被清理
# CONTAINER 在 Step 5 赋值，此处引用时 trap 动态展开变量，先声明为空以防万一
CONTAINER=""
trap 'docker rm -f "${CONTAINER}" 2>/dev/null || true; rm -rf "${LOOPER_TMP:-}"' EXIT INT TERM

# settings.json 通过只读 volume 挂载进容器，不再复制到临时目录
# （避免 API token 在宿主机临时路径形成明文副本）
if [ ! -f "$HOME/.claude/settings.json" ]; then
  echo "❌ settings.json 不存在：$HOME/.claude/settings.json（请先完成 Claude Code 初始化）"
  exit 1
fi

# 复制 .claude.json 到 LOOPER_TMP（读写挂载，CC 启动时需写入此文件）
if [ ! -f "$CLAUDE_JSON_SRC" ]; then
  echo "❌ .claude.json 不存在：$CLAUDE_JSON_SRC"
  echo "  请先执行 install.sh 完成 looper 初始化安装。"
  exit 1  # EXIT trap 统一清理 LOOPER_TMP
fi
cp "$CLAUDE_JSON_SRC" "$LOOPER_TMP/.claude.json"

```

```bash
# Inject eval runner + evals.json into LOOPER_TMP (enables T5)
HAS_EVALS=false
DISABLE_T5="False"
if [ -n "$EVALS_JSON" ]; then
  DISABLE_T5=$(python3 -c "import json; d=json.load(open('$EVALS_JSON')); v=d.get('disable_t5',False); print('True' if str(v).lower()=='true' else 'False')" 2>/dev/null || echo "False")
fi
if [ -n "$EVALS_JSON" ] && [ "$DISABLE_T5" != "True" ]; then
  cp "$EVALS_JSON" "$LOOPER_TMP/evals.json"
  cat > "$LOOPER_TMP/run_eval_suite.py" << 'PYEOF'
#!/usr/bin/env python3
"""Looper T5: run evals.json inside clean CC container."""
import json, os, subprocess, sys

def run_claude(prompt, timeout=180):
    try:
        r = subprocess.run(
            ['claude', '--dangerously-skip-permissions', '-p', prompt],
            capture_output=True, text=True, timeout=timeout
        )
        return (r.stdout + r.stderr).strip(), True
    except subprocess.TimeoutExpired:
        return 'TIMEOUT', False
    except Exception as e:
        return str(e), False

def grade(assertion, output):
    prompt = (
        "Does the following output satisfy the assertion? "
        "Answer ONLY with YES or NO.\n\n"
        f"Assertion: {assertion}\n\nOutput:\n{output[:2000]}"
    )
    result, ok = run_claude(prompt, timeout=30)
    return ok and 'YES' in result.upper().split()

def main():
    evals_path = sys.argv[1] if len(sys.argv) > 1 else 'evals.json'
    work_dir   = sys.argv[2] if len(sys.argv) > 2 else os.getcwd()
    with open(evals_path) as f:
        data = json.load(f)
    cases = data.get('evals', [])
    skill = data.get('skill_name', '?')
    print(f'[T5] {skill} — {len(cases)} eval cases', flush=True)
    passed = 0
    for ev in cases:
        eid, prompt, asserts, files = (
            ev.get('id','?'), ev.get('prompt',''),
            ev.get('assertions',[]), ev.get('files',[])
        )
        for fspec in files:
            p = os.path.join(work_dir, fspec['path'])
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, 'w').write(fspec['content'])
        print(f'  [{eid}] {prompt[:60]}', flush=True)
        output, _ = run_claude(prompt)
        results = [grade(a if isinstance(a, str) else a.get('text', str(a)), output) for a in asserts]
        if all(results):
            passed += 1
        for a, r in zip(asserts, results):
            label = a if isinstance(a, str) else a.get('text', str(a))
            print(f'    {"✅" if r else "❌"} {label[:80]}', flush=True)
    total = len(cases)
    print(f'EVAL_SUITE_RESULT:{{"passed":{passed},"total":{total}}}', flush=True)
    sys.exit(0 if passed == total else 1)

if __name__ == '__main__':
    main()
PYEOF
  HAS_EVALS=true
  EVAL_COUNT=$(python3 -c "import json; d=json.load(open('$EVALS_JSON')); print(len(d['evals']))" 2>/dev/null || echo "?")
  echo "  eval suite: ${EVAL_COUNT} cases injected"
elif [ "$DISABLE_T5" = "True" ]; then
  echo "  eval suite: skipped (disable_t5=true in evals.json)"
else
  echo "  eval suite: skipped (no evals.json found)"
fi
```

输出进度：

```
[环境准备]
  镜像：<IMAGE>
  镜像策略：<IMAGE_STRATEGY>
  纯净 CC 目录：<LOOPER_TMP>
  目标：plugin:<NAME>
  plugin 源文件：只读挂载 <PLUGIN_PATH> → /plugin_src
  settings.json：只读挂载（API 凭证 + 模型配置，不落盘到临时目录）
  eval suite：<N 条用例已注入 / skipped>
```

---

## Step 5：启动容器

```bash
CONTAINER="looper_$(date +%s)"
WORK_DIR="/looper_work"

# settings.json 嵌套挂载：后挂载覆盖前挂载子路径，在 Docker 18.09+ 行为确定
docker run -d \
  --name "$CONTAINER" \
  -w "$WORK_DIR" \
  -v "${CLEAN_CLAUDE}:/root/.claude" \
  -v "$HOME/.claude/settings.json:/root/.claude/settings.json:ro" \
  -v "${LOOPER_TMP}/.claude.json:/root/.claude.json" \
  -v "${LOOPER_TMP}:${WORK_DIR}" \
  -v "${PLUGIN_PATH}:/plugin_src:ro" \
  "${PROXY_ENV_ARGS[@]}" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="64000" \
  -e IS_SANDBOX=1 \
  -e JINA_API_KEY="${JINA_API_KEY:-}" \
  -u root \
  "$IMAGE" \
  sleep infinity \
  || {
    echo "❌ 容器启动失败（镜像：$IMAGE）"
    echo "  常见原因：镜像不存在（docker pull $IMAGE）或 Docker 权限不足"
    exit 1
  }
```

---

## Step 6：运行测试套件

```bash
CC=(docker exec -w "$WORK_DIR" "$CONTAINER" claude --dangerously-skip-permissions)
```

### Test 1：CC 可用性

```bash
T1_OUT=$(docker exec "$CONTAINER" claude --version 2>&1)
T1_PASS=$(echo "$T1_OUT" | grep -qi "claude" && echo "pass" || echo "fail")
```

### Test 2 (Plan A)：install.sh 路径完整验证 — A1–A7

```bash
# A1: dry-run — 输出 N file(s) would be modified，无实际写入
A1_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh --dry-run 2>&1")
A1_COUNT=$(echo "$A1_OUT" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
echo "$A1_OUT" | grep -q "would be modified" && [[ "$A1_COUNT" -gt 0 ]] \
  && A1_PASS="pass" || A1_PASS="fail"

# A2: uninstall on empty env — 优雅处理 not found，exit 0
A2_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh --uninstall; echo \"EXIT:\$?\"" 2>&1)
echo "$A2_OUT" | grep -q "EXIT:0" && A2_PASS="pass" || A2_PASS="fail"

# A3: fresh install — Done! N file(s)/item(s) installed，exit 0
A3_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh 2>&1")
A3_COUNT=$(echo "$A3_OUT" | grep -oE 'Done! [0-9]+' | grep -oE '[0-9]+' || echo "0")
echo "$A3_OUT" | grep -q "Done!" && [[ "$A3_COUNT" -gt 0 ]] \
  && A3_PASS="pass" || A3_PASS="fail"

# A4: idempotency — re-install = Done! 0
A4_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh 2>&1")
echo "$A4_OUT" | grep -qE "Done! 0 (file|item)" \
  && A4_PASS="pass" || A4_PASS="fail"

# A5: file presence — commands/agents/skills 各有安装物
A5_OUT=$(docker exec "$CONTAINER" bash -c "
  find /root/.claude/commands /root/.claude/agents /root/.claude/skills \
    -mindepth 1 \( -type f -o -type d \) 2>/dev/null | head -20
")
[[ -n "$A5_OUT" ]] && A5_PASS="pass" || A5_PASS="fail"

# A6: uninstall — Removed N item(s)
A6_OUT=$(docker exec "$CONTAINER" bash -c "CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh --uninstall 2>&1")
A6_REMOVED=$(echo "$A6_OUT" | grep -c "Removed" || true)
[[ "$A6_REMOVED" -gt 0 ]] && A6_PASS="pass" || A6_PASS="fail"

# A7: verify clean — 安装物全部消失
A7_OUT=$(docker exec "$CONTAINER" bash -c "
  find /root/.claude/commands /root/.claude/agents /root/.claude/skills \
    -mindepth 1 2>/dev/null | head -5
")
[[ -z "$A7_OUT" ]] && A7_PASS="pass" || A7_PASS="fail"

# 汇总 T2：全部 pass 才算过
T2_OUT="A1:${A1_PASS} A2:${A2_PASS} A3:${A3_PASS} A4:${A4_PASS} A5:${A5_PASS} A6:${A6_PASS} A7:${A7_PASS}"
T2_PASS="pass"
for _p in $A1_PASS $A2_PASS $A3_PASS $A4_PASS $A5_PASS $A6_PASS $A7_PASS; do
  [[ "$_p" != "pass" ]] && T2_PASS="fail"
done
echo "  [T2] $T2_OUT"
```

### Test 2b (Plan B)：claude plugin install 路径完整验证 — B1–B9

```bash
# 构造 Plan B 专用 settings.json（仅 API 凭证，extraKnownMarketplaces 初始为空）
PLAN_B_CLAUDE="$LOOPER_TMP/claude_home_b"
PLAN_B_SETTINGS="$PLAN_B_CLAUDE/settings.json"
mkdir -p "$PLAN_B_CLAUDE"
python3 -c "
import json, sys
src = json.load(open('$HOME/.claude/settings.json'))
out = {}
if 'env' in src:
    out['env'] = src['env']
print(json.dumps(out, indent=2))
" > "$PLAN_B_SETTINGS"

# 启动 Plan B 专用容器（settings.json 可写，claude plugin marketplace add 需要写入）
CONTAINER_B="looper_b_$(date +%s)"
trap 'docker rm -f "${CONTAINER}" "${CONTAINER_B}" 2>/dev/null || true; rm -rf "${LOOPER_TMP:-}"' EXIT INT TERM

docker run -d \
  --name "$CONTAINER_B" \
  -v "${PLAN_B_CLAUDE}:/root/.claude" \
  -v "${LOOPER_TMP}/.claude.json:/root/.claude.json" \
  -v "${PLUGIN_PATH}:/plugin_src:ro" \
  "${PROXY_ENV_ARGS[@]}" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="64000" \
  -e IS_SANDBOX=1 \
  -u root \
  "$IMAGE" \
  sleep infinity \
  || { echo "❌ Plan B 容器启动失败"; T2B_PASS="fail"; T2B_OUT="container start failed"; }

CCB=(docker exec "$CONTAINER_B" claude --dangerously-skip-permissions)

# B1: marketplace add — settings.json 写入 extraKnownMarketplaces.<NAME>
B1_OUT=$("${CCB[@]}" plugin marketplace add "easyfan/$NAME" 2>&1)
B1_SETTINGS=$(python3 -c "
import json
d = json.load(open('$PLAN_B_SETTINGS'))
mkts = d.get('extraKnownMarketplaces', {})
print('yes' if '$NAME' in mkts else 'no')
" 2>/dev/null || echo "no")
echo "$B1_OUT" | grep -q "Successfully" && [[ "$B1_SETTINGS" == "yes" ]] \
  && B1_PASS="pass" || B1_PASS="fail"

# B2: marketplace update — Successfully updated
B2_OUT=$("${CCB[@]}" plugin marketplace update "$NAME" 2>&1)
echo "$B2_OUT" | grep -q "Successfully" && B2_PASS="pass" || B2_PASS="fail"

# B3: schema validation — plugin.json valid（marketplace.json 跳过，pending #42412）
B3_OUT=$("${CCB[@]}" plugin validate /plugin_src/.claude-plugin/plugin.json 2>&1)
echo "$B3_OUT" | grep -q "Validation passed" && B3_PASS="pass" || B3_PASS="fail"

# B4: install — Successfully installed
B4_OUT=$("${CCB[@]}" plugin install "$NAME" 2>&1)
echo "$B4_OUT" | grep -q "Successfully installed" && B4_PASS="pass" || B4_PASS="fail"

# B5: SHA verification — cache sha == marketplace registry sha
B5_OUT=$(docker exec "$CONTAINER_B" bash -c "
  reg=\$HOME/.claude/plugins/marketplaces/$NAME/.claude-plugin/marketplace.json
  [ -f \"\$reg\" ] || { echo 'registry not found'; exit 1; }
  reg_sha=\$(python3 -c \"import json; d=json.load(open('\$reg')); print(d['plugins'][0]['source']['sha'][:7])\" 2>/dev/null) \
    || { echo 'parse error'; exit 1; }
  cache_dir=\$(ls -d \$HOME/.claude/plugins/cache/$NAME/$NAME/*/ 2>/dev/null | head -1)
  [ -n \"\$cache_dir\" ] || { echo 'no cache dir'; exit 1; }
  inst_sha=\$(cd \"\$cache_dir\" && git log --oneline -1 2>/dev/null | awk '{print \$1}')
  if [[ \"\$inst_sha\" == \"\$reg_sha\"* ]] || [[ \"\$reg_sha\" == \"\$inst_sha\"* ]]; then
    echo \"match:\$inst_sha\"
  else
    echo \"mismatch:installed=\$inst_sha registry=\$reg_sha\"
  fi
" 2>&1)
echo "$B5_OUT" | grep -q "^match:" && B5_PASS="pass" || B5_PASS="fail"

# B6: file presence in plugin cache
B6_OUT=$(docker exec "$CONTAINER_B" bash -c "
  cache_dir=\$(ls -d \$HOME/.claude/plugins/cache/$NAME/$NAME/*/ 2>/dev/null | head -1)
  [ -n \"\$cache_dir\" ] || { echo 'no cache dir'; exit 1; }
  find \"\$cache_dir\" -mindepth 2 \( -type f -o -type d \) 2>/dev/null | head -20
" 2>&1)
[[ -n "$B6_OUT" ]] && B6_PASS="pass" || B6_PASS="fail"

# B7: uninstall — Successfully uninstalled；installed_plugins.json 条目移除
B7_OUT=$("${CCB[@]}" plugin uninstall "$NAME" 2>&1)
echo "$B7_OUT" | grep -q "Successfully uninstalled" && B7_PASS="pass" || B7_PASS="fail"
B7_ENTRY=$(docker exec "$CONTAINER_B" python3 -c "
import json, os
p = os.path.expanduser('~/.claude/plugins/installed_plugins.json')
if not os.path.exists(p): print('clean'); exit()
d = json.load(open(p))
print('dirty' if '$NAME' in d else 'clean')
" 2>/dev/null || echo "clean")
[[ "$B7_ENTRY" == "clean" ]] || B7_PASS="fail"

# B8: marketplace remove — Successfully removed
B8_OUT=$("${CCB[@]}" plugin marketplace remove "$NAME" 2>&1)
echo "$B8_OUT" | grep -q "Successfully removed" && B8_PASS="pass" || B8_PASS="fail"

# B9: verify settings.json clean — extraKnownMarketplaces.<NAME> 不存在
B9_CLEAN=$(python3 -c "
import json
d = json.load(open('$PLAN_B_SETTINGS'))
mkts = d.get('extraKnownMarketplaces', {})
print('clean' if '$NAME' not in mkts else 'dirty')
" 2>/dev/null || echo "dirty")
[[ "$B9_CLEAN" == "clean" ]] && B9_PASS="pass" || B9_PASS="fail"

# 汇总 T2b
T2B_OUT="B1:${B1_PASS} B2:${B2_PASS} B3:${B3_PASS} B4:${B4_PASS} B5:${B5_PASS} B6:${B6_PASS} B7:${B7_PASS} B8:${B8_PASS} B9:${B9_PASS}"
T2B_PASS="pass"
for _p in $B1_PASS $B2_PASS $B3_PASS $B4_PASS $B5_PASS $B6_PASS $B7_PASS $B8_PASS $B9_PASS; do
  [[ "$_p" != "pass" ]] && T2B_PASS="fail"
done
echo "  [T2b] $T2B_OUT"

docker rm -f "$CONTAINER_B" 2>/dev/null || true
```

### Test 3：触发测试（核心）

```bash
# 优先从宿主机源路径读 SKILL.md（不依赖 install.sh 是否写入 CLEAN_CLAUDE）
if [ -f "${PLUGIN_PATH}/SKILL.md" ]; then
  SKILL_MD_PATH="${PLUGIN_PATH}/SKILL.md"
else
  # fallback：install.sh 可能已将其写入 CLEAN_CLAUDE
  SKILL_MD_PATH=$(find "$CLEAN_CLAUDE" -name "SKILL.md" 2>/dev/null | head -1)
fi

if [ -f "$SKILL_MD_PATH" ]; then
  DESC=$(grep "^description:" "$SKILL_MD_PATH" 2>/dev/null | head -1 | sed 's/^description:[[:space:]]*//')
  TRIGGER_PROMPT="${DESC:0:80}：请处理一个简单示例，无交互直接完成"
else
  echo "  ⚠️ SKILL.md 未找到（NAME=${NAME}），T3 使用通用触发 prompt，结果可靠性降低"
  TRIGGER_PROMPT="${NAME}：请处理一个简单示例，无交互直接完成"
fi

echo "  [T3] 触发测试（容器内 CC 调用，预计 30-180 秒）..."
# 若代理未透传或 Docker 内 DNS 无法解析代理主机，CC 会报 ENOTFOUND → 判为 fail
T3_OUT=$("${CC[@]}" -p "$TRIGGER_PROMPT" 2>&1)

# 判断触发成功：不含拒绝词 / API 连接错误 / 空输出
if echo "$T3_OUT" | grep -qi "command not found\|no skill\|unknown command\|无法完成\|无法处理\|不知道如何\|无法识别\|抱歉\|我不能\|暂不支持\|没有该功能\|找不到\|不支持该\|无法找到"; then
  T3_PASS="fail"
elif echo "$T3_OUT" | grep -qi "Unable to connect to API\|ENOTFOUND\|ECONNREFUSED\|connection refused\|network error\|Could not connect\|API connection"; then
  T3_PASS="fail"
elif [ -z "$(echo "$T3_OUT" | tr -d '[:space:]')" ]; then
  T3_PASS="fail"
else
  T3_PASS="pass"
fi
```

### Test 5：eval suite（若 HAS_EVALS=true）

```bash
T5_PASS="skip"
T5_RATE="—"

if [ "$HAS_EVALS" = "true" ]; then
  echo "  [T5] 运行 eval 套件（${EVAL_COUNT} 个用例，预计数分钟）..."
  T5_TMP="$LOOPER_TMP/t5_out_$$.txt"
  # tee 方案：实时透出 run_eval_suite.py 的 flush=True 进度输出，同时写入临时文件
  docker exec -w "$WORK_DIR" "$CONTAINER" \
    python3 /looper_work/run_eval_suite.py /looper_work/evals.json /looper_work \
    2>&1 | tee "$T5_TMP"
  T5_OUT=$(cat "$T5_TMP")
  rm -f "$T5_TMP"

  # Extract structured result from marker line
  T5_JSON=$(echo "$T5_OUT" | grep "^EVAL_SUITE_RESULT:" | tail -1 | sed 's/^EVAL_SUITE_RESULT://')
  if [ -n "$T5_JSON" ]; then
    T5_PASSED=$(echo "$T5_JSON" | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['passed'])" 2>/dev/null)
    T5_TOTAL=$(echo "$T5_JSON"  | python3 -c "import json,sys; print(json.loads(sys.stdin.read())['total'])"  2>/dev/null)
    T5_RATE="${T5_PASSED}/${T5_TOTAL}"
    if [ "$T5_PASSED" = "$T5_TOTAL" ] && [ "${T5_TOTAL:-0}" -gt 0 ]; then
      T5_PASS="pass"
    else
      T5_PASS="fail"
    fi
  else
    T5_PASS="fail"
    T5_RATE="parse error"
  fi
fi
```

---

## Step 7：持久化报告

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_DIR="$(pwd)/looper/reports"
mkdir -p "$REPORT_DIR" || { echo "⚠️ 报告目录创建失败：$REPORT_DIR（请确认在项目根目录执行）"; REPORT_DIR="$HOME/looper_reports_fallback"; mkdir -p "$REPORT_DIR"; echo "  报告将写入备用路径：$HOME/looper_reports_fallback"; }
REPORT_FILE="${REPORT_DIR}/${TIMESTAMP}_looper_${NAME}.md"
```

将 Step 6 各测试结果写入 `$REPORT_FILE`：

```markdown
# Looper 报告：<NAME>
日期：<TIMESTAMP>  镜像：<IMAGE>  策略：<IMAGE_STRATEGY>

## 测试结果
| 测试 | 结果 | 详情 |
|------|------|------|
| T1 CC 可用性 | ✅/❌ | <T1_OUT> |
| T2 Plan A install.sh | ✅/❌ | <T2_OUT> |
| T2b Plan B plugin install | ✅/❌ | <T2B_OUT> |
| T3 触发测试 | ✅/❌ | <T3_OUT 节选> |
| T5 eval suite | ✅/❌/⏭️ | <T5_RATE>（若 ⏭️ 则无 evals.json）|
| 应用策略 | — | <IMAGE_STRATEGY> |

## 触发输出（完整，最多 4000 字符）
<T3_OUT 截取前 4000 字符：${T3_OUT:0:4000}>

## Eval Suite 输出（节选，若 T5 执行）
<T5_OUT 节选（最后 50 行）>

## 质量结论
<PASS/FAIL>
```

---

## Step 8：清理容器

```bash
docker rm -f "$CONTAINER" 2>/dev/null || true
rm -rf "$LOOPER_TMP"
```

---

## Step 9：最终输出

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🔁 Looper 部署验证报告
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
目标：plugin:<NAME>
镜像：<IMAGE>（策略：<IMAGE_STRATEGY>）

  T1  CC 可用性：          ✅ <version>
  T2  Plan A install.sh：  ✅ A1–A7 all pass
  T2b Plan B plugin install：✅ B1–B9 all pass
  T3  触发测试：            ✅ 触发成功（<输出摘要>）
  T5  eval suite：         ✅ <T5_RATE> passed  |  ⏭️ skipped (no evals.json)

报告：<REPORT_FILE>

质量结论：✅ PASS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

整体 PASS 条件：T1、T2、T2b、T3 全部 pass，且（T5 pass 或 T5 skip）。

**若 FAIL**，追加：

```
⚠️ looper 是终态验证工具，不迭代。
失败根因分类：
  触发率 0%            → description 未收敛，回溯到 eval 阶段：/skill-test --from-stage 3
  安装残缺              → 检查 SKILL.md 依赖声明，补全后重新安装
  CC 启动失败           → 检查镜像可用性：docker pull <IMAGE>
  eval suite 未通过 (T5) → clean 环境行为与宿主机不一致；检查 description 是否依赖
                          其他已安装 skill 或宿主机环境变量
```

---

## 附：容器内文件布局

```
容器 /root/
├── .claude/                  ← 纯净 CC home（Plan A 步骤通过 install.sh 写入）
│   ├── settings.json         ← API 凭证 + model（只读 volume 挂载）
│   ├── commands/             ← Plan A A3 安装后写入
│   ├── agents/               ← Plan A A3 安装后写入
│   └── skills/               ← Plan A A3 安装后写入
└── .claude.json              ← {"hasCompletedOnboarding":true}

/plugin_src/                  ← 被测 plugin 源文件（只读 volume 挂载自宿主机 PLUGIN_PATH）
├── install.sh
├── .claude-plugin/
└── <plugin 内容>

/looper_work/                 ← LOOPER_TMP 挂载点
├── run_eval_suite.py         ← T5 eval runner（注入，若 evals.json 存在）
└── evals.json                ← eval 套件（注入，若存在）
```
