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

> **执行前提**：必须在包含 `packer/` 子目录的项目根目录下触发本命令。

## Step 0：解析参数

从 `$ARGUMENTS` 提取：
- `--plugin <name>` → NAME=`<name>`
- `--image <image>` → USER_IMAGE=`<image>`（可选，显式指定镜像；覆盖 devcontainer 和状态缓存）

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
  print(f'⚠️ 状态文件解析失败（将重新检测镜像）：{e}', file=sys.stderr)
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
mkdir -p "$CLEAN_CLAUDE/commands"

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

# 执行 packer 的 install.sh，通过 CLAUDE_DIR 环境变量指定安装目标
# （packer install.sh 约定：CLAUDE_DIR=/path ./install.sh，不使用 --target flag）
INSTALL_OUT=$(CLAUDE_DIR="$CLEAN_CLAUDE" bash "${PLUGIN_PATH}/install.sh" 2>&1)
INSTALL_RC=$?
if [ $INSTALL_RC -ne 0 ]; then
  echo "  ❌ install.sh 执行失败（exit $INSTALL_RC）："
  echo "$INSTALL_OUT" | tail -10
  # 写入最简失败报告（保持所有失败路径均有持久记录）
  _FAIL_REPORT_DIR="$(pwd)/looper/reports"
  mkdir -p "$_FAIL_REPORT_DIR"
  _FAIL_REPORT="${_FAIL_REPORT_DIR}/$(date +%Y%m%d_%H%M%S)_looper_${NAME}.md"
  printf '# Looper 报告：%s\n日期：%s\n\n## 结果\nFAIL — install.sh 退出码 %s\n\n## 错误输出（最后 10 行）\n```\n%s\n```\n' \
    "$NAME" "$(date)" "$INSTALL_RC" "$(echo "$INSTALL_OUT" | tail -10)" > "$_FAIL_REPORT"
  echo "  报告：$_FAIL_REPORT"
  exit 1  # EXIT trap 统一清理 LOOPER_TMP（容器尚未启动，docker rm 静默跳过）
fi
echo "  已执行安装：packer/${NAME}/install.sh → $CLEAN_CLAUDE"
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
  settings.json：只读挂载（API 凭证 + 模型配置，不落盘到临时目录）
  eval suite：<N 条用例已注入 / skipped>
```

---

## Step 5：启动容器

```bash
CONTAINER="looper_$(date +%s)"
WORK_DIR="/looper_work"

docker run -d \
  --name "$CONTAINER" \
  -w "$WORK_DIR" \
  -v "${CLEAN_CLAUDE}:/root/.claude" \
  -v "$HOME/.claude/settings.json:/root/.claude/settings.json:ro" \
  -v "${LOOPER_TMP}/.claude.json:/root/.claude.json" \
  -v "${LOOPER_TMP}:${WORK_DIR}" \
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

### Test 2：安装完整性检查

```bash
# plugin：有意义的完整性验证：检查除 settings.json 以外是否存在安装物
# -type f 确保只检测实际文件，排除空目录结构
T2_TMPFILE=$(mktemp "$LOOPER_TMP/t2_XXXXXX")
if docker exec "$CONTAINER" find /root/.claude/ -mindepth 1 -type f -not -name "settings.json" > "$T2_TMPFILE" 2>&1; then
  T2_OUT=$(head -5 "$T2_TMPFILE")
  rm -f "$T2_TMPFILE"
  if [ -n "$T2_OUT" ]; then
    T2_PASS="pass"
  else
    T2_PASS="fail"
  fi
else
  T2_OUT="docker exec 失败：$(cat "$T2_TMPFILE")"
  rm -f "$T2_TMPFILE"
  T2_PASS="fail"
fi
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
if echo "$T3_OUT" | grep -qi "command not found\|no skill\|unknown command\|无法完成\|无法处理\|不知道如何\|无法识别"; then
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
| T2 安装完整性 | ✅/❌ | <T2_OUT> |
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

  T1 CC 可用性：     ✅ <version>
  T2 安装完整性：     ✅ 安装物已挂载
  T3 触发测试：       ✅ 触发成功（<输出摘要>）
  T5 eval suite：    ✅ <T5_RATE> passed  |  ⏭️ skipped (no evals.json)

报告：<REPORT_FILE>

质量结论：✅ PASS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

整体 PASS 条件：T1-T3 全部 pass，且（T5 pass 或 T5 skip）。

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
├── .claude/                  ← 纯净 CC home（仅含被测目标）
│   ├── settings.json         ← API 凭证 + model（只读 volume 挂载自宿主机原位）
│   └── <install.sh 安装物>   ← commands/, skills/, agents/ 等
└── .claude.json              ← {"hasCompletedOnboarding":true}

/looper_work/                 ← LOOPER_TMP 挂载点
├── run_eval_suite.py         ← T5 eval runner（注入，若 evals.json 存在）
└── evals.json                ← eval 套件（注入，若存在）
```
