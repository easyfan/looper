---
description: 在纯净 Docker CC 容器中对指定 command/skill/plugin 做安装完整性和触发准确性的部署验证。当 skill-test pipeline 阶段 5 需要 looper 部署验证，或用户说"跑 looper 验证"、"纯净环境测试 <名称>"、"/looper --command/--skill/--plugin <名称>"时使用。
allowed-tools: ["Bash", "Read", "Write", "Glob"]
---
# Looper — 纯净 CC 环境部署验证

## 使用方式

```
/looper --command <name>     # 验证 ~/.claude/commands/<name>.md
/looper --skill <name>       # 验证 ~/.claude/skills/<name>/ 或同名 plugin
/looper --plugin <pkg>       # 安装并验证 packer/<pkg>/ 包
```

**示例**：
- `/looper --command patterns` — 验证 patterns 命令在纯净环境可触发
- `/looper --skill skill-creator` — 验证 skill-creator 安装后可触发
- `/looper --plugin news-digest` — 安装 news-digest 包后验证触发率

---

## Step 0：解析参数

从 `$ARGUMENTS` 提取：
- `--command <name>` → TYPE=command，NAME=`<name>`
- `--skill <name>` → TYPE=skill，NAME=`<name>`
- `--plugin <name>` → TYPE=plugin，NAME=`<name>`

若参数为空或格式不合法，输出用法说明后退出：

```
用法：/looper --command <name> | --skill <name> | --plugin <pkg>
示例：
  /looper --command patterns       — 验证 patterns 命令
  /looper --skill skill-creator    — 验证 skill-creator 插件
  /looper --plugin news-digest     — 验证 news-digest 安装包
```

---

## Step 1：解析目标路径

根据 TYPE 查找源文件：

```bash
# command
COMMAND_PATH="$HOME/.claude/commands/${NAME}.md"

# skill：先找用户级 plugin cache，再找 skills/
SKILL_PATH=$(find "$HOME/.claude" -maxdepth 5 -name "${NAME}" -type d 2>/dev/null | head -1)

# plugin：项目 packer 目录
PLUGIN_PATH="$(pwd)/packer/${NAME}"
```

```bash
# Locate evals.json for T5 (optional — T5 skipped if not found)
EVALS_JSON=""
if [ "$TYPE" = "plugin" ]; then
  EVALS_JSON="${PLUGIN_PATH}/evals/evals.json"
elif [ "$TYPE" = "command" ]; then
  EVALS_JSON="$(pwd)/packer/${NAME}/evals/evals.json"
elif [ "$TYPE" = "skill" ]; then
  EVALS_JSON="${SKILL_PATH}/evals/evals.json"
fi
[ -f "$EVALS_JSON" ] || EVALS_JSON=""
```

若目标不存在，输出后退出（**不启动容器**）：

```
❌ 目标未找到：<TYPE>:<NAME>
  期望路径：<resolved_path>
  请确认名称拼写，或检查是否已安装后重试。
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
    /looper --command <NAME>
```

输出提示后以 exit 0 退出（不算失败）。

---

## Step 3：读取镜像和代理配置

```bash
# 从 devcontainer.json 读取镜像（去掉 JS 注释后解析）
DEVCONTAINER="$(pwd)/.devcontainer/devcontainer.json"
if [ -f "$DEVCONTAINER" ]; then
  IMAGE=$(python3 -c "
import json, re, sys
txt = open('$DEVCONTAINER').read()
txt = re.sub(r'//.*', '', txt)   # 去行注释
txt = re.sub(r',\s*}', '}', txt) # 去尾逗号
cfg = json.loads(txt)
print(cfg.get('image',''))
" 2>/dev/null)
fi

# fallback：从 loop.zsh 读取
if [ -z "$IMAGE" ] && [ -f "$(pwd)/looper/loop.zsh" ]; then
  IMAGE=$(grep '^IMAGE=' "$(pwd)/looper/loop.zsh" | cut -d'"' -f2)
fi

# 最终 fallback
IMAGE="${IMAGE:-cc-runtime-minimal}"

# looper/.claude.json（CC 入门跳过配置）
CLAUDE_JSON="$(pwd)/looper/.claude.json"
if [ ! -f "$CLAUDE_JSON" ]; then
  CLAUDE_JSON=$(mktemp "${HOME}/looper_claudejson_XXXXXX")
  echo '{"hasCompletedOnboarding":true}' > "$CLAUDE_JSON"
fi
```

---

## Step 4：构建纯净 CC 工作目录

> **纯净原则**：容器内 `~/.claude/` 只含 `settings.json`（API 凭证）+ 被测目标，不挂载宿主机完整 `~/.claude/`，确保零其他工具链干扰。

```bash
LOOPER_TMP=$(mktemp -d "${HOME}/looper_XXXXXX")
CLEAN_CLAUDE="$LOOPER_TMP/claude_home"
mkdir -p "$CLEAN_CLAUDE/commands"

# 复制 API 凭证（settings.json 含 ANTHROPIC_AUTH_TOKEN 和 model）
cp "$HOME/.claude/settings.json" "$CLEAN_CLAUDE/settings.json"

# 按类型安装目标
if [ "$TYPE" = "command" ]; then
  cp "$COMMAND_PATH" "$CLEAN_CLAUDE/commands/${NAME}.md"
  echo "  已安装：commands/${NAME}.md"

elif [ "$TYPE" = "skill" ]; then
  # plugin/skill 需要写入 settings.json 的 enabledPlugins 或放入 plugins/cache
  # 简化处理：将 skill 目录复制到 clean_home/skills/（CC 加载路径）
  mkdir -p "$CLEAN_CLAUDE/skills"
  cp -r "$SKILL_PATH" "$CLEAN_CLAUDE/skills/${NAME}"
  echo "  已安装：skills/${NAME}/"

elif [ "$TYPE" = "plugin" ]; then
  # 执行 packer 的 install.sh，通过 CLAUDE_DIR 环境变量指定安装目标
  # （packer install.sh 约定：CLAUDE_DIR=/path ./install.sh，不使用 --target flag）
  CLAUDE_DIR="$CLEAN_CLAUDE" bash "${PLUGIN_PATH}/install.sh" 2>&1 || true
  echo "  已执行安装：packer/${NAME}/install.sh → $CLEAN_CLAUDE"
fi
```

```bash
# Inject eval runner + evals.json into LOOPER_TMP (enables T5)
HAS_EVALS=false
if [ -n "$EVALS_JSON" ]; then
  DISABLE_T5=$(python3 -c "import json; d=json.load(open('$EVALS_JSON')); print(d.get('disable_t5', False))" 2>/dev/null)
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
        results = [grade(a, output) for a in asserts]
        if all(results):
            passed += 1
        for a, r in zip(asserts, results):
            print(f'    {"✅" if r else "❌"} {a[:80]}', flush=True)
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
  纯净 CC 目录：<LOOPER_TMP>
  目标：<TYPE>:<NAME>
  settings.json：已复制（API 凭证 + 模型配置）
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
  -v "${CLAUDE_JSON}:/root/.claude.json" \
  -v "${LOOPER_TMP}:${WORK_DIR}" \
  -e CLAUDE_CODE_MAX_OUTPUT_TOKENS="64000" \
  -e IS_SANDBOX=1 \
  -e JINA_API_KEY="${JINA_API_KEY:-}" \
  -u root \
  "$IMAGE" \
  sleep infinity
```

若 `docker run` 失败，直接跳到 Step 8 清理，输出：

```
❌ 容器启动失败，请检查镜像是否可用：<IMAGE>
```

---

## Step 6：运行测试套件

```bash
CC=(docker exec -w "$WORK_DIR" "$CONTAINER" claude --dangerously-skip-permissions)
```

### Test 1：CC 可用性

```bash
T1_OUT=$(docker exec "$CONTAINER" claude --version 2>&1)
T1_PASS=$(echo "$T1_OUT" | grep -q "claude" && echo "pass" || echo "fail")
```

### Test 2：安装完整性检查

```bash
# command：检查文件已挂载
if [ "$TYPE" = "command" ]; then
  T2_OUT=$(docker exec "$CONTAINER" ls /root/.claude/commands/ 2>&1)
  echo "$T2_OUT" | grep -q "${NAME}.md" && T2_PASS="pass" || T2_PASS="fail"
else
  # skill/plugin：检查对应目录
  T2_OUT=$(docker exec "$CONTAINER" ls /root/.claude/ 2>&1)
  T2_PASS="pass"  # install.sh 已验证，这里仅列目录
fi
```

### Test 3：触发测试（核心）

根据 TYPE 构造触发 prompt：

- **command**：`"/<NAME> 无交互直接完成，输出简短摘要"`
- **skill**：读取 SKILL.md 的 description，提取前 50 字构造触发 prompt
- **plugin**：读取 packer/<NAME>/SKILL.md 的 description 构造 prompt

```bash
if [ "$TYPE" = "command" ]; then
  TRIGGER_PROMPT="/${NAME} 无交互直接完成，输出简短摘要"
else
  # 从 SKILL.md 提取 description 字段
  SKILL_MD_PATH=$(find "$CLEAN_CLAUDE" -name "SKILL.md" | head -1)
  DESC=$(grep "^description:" "$SKILL_MD_PATH" 2>/dev/null | head -1 | sed 's/^description:[[:space:]]*//')
  TRIGGER_PROMPT="${DESC:0:80}：请处理一个简单示例，无交互直接完成"
fi

T3_OUT=$("${CC[@]}" -p "$TRIGGER_PROMPT" 2>&1 | tail -20)

# 判断触发成功：不含 "command not found" / "no skill" / 空输出
if echo "$T3_OUT" | grep -qi "command not found\|no skill\|unknown command\|Error"; then
  T3_PASS="fail"
elif [ -z "$(echo "$T3_OUT" | tr -d '[:space:]')" ]; then
  T3_PASS="fail"
else
  T3_PASS="pass"
fi
```

### Test 4：错误处理（仅 TYPE=command）

```bash
if [ "$TYPE" = "command" ]; then
  T4_OUT=$("${CC[@]}" -p "/${NAME} __looper_invalid_input_xyz__" 2>&1 | tail -10)
  # 期望：有输出（graceful fallback），无 Python/Node traceback
  if echo "$T4_OUT" | grep -qi "traceback\|TypeError\|ReferenceError\|segfault"; then
    T4_PASS="fail"
  else
    T4_PASS="pass"
  fi
else
  T4_PASS="skip"
fi
```

### Test 5：eval suite（若 HAS_EVALS=true）

```bash
T5_PASS="skip"
T5_RATE="—"

if [ "$HAS_EVALS" = "true" ]; then
  echo "  [T5] Running eval suite in container (may take several minutes)..."
  T5_OUT=$(docker exec -w "$WORK_DIR" "$CONTAINER" \
    python3 /looper_work/run_eval_suite.py /looper_work/evals.json /looper_work \
    2>&1)

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
mkdir -p "$REPORT_DIR"
REPORT_FILE="${REPORT_DIR}/${TIMESTAMP}_looper_${NAME}.md"
```

将 Step 6 各测试结果写入 `$REPORT_FILE`：

```markdown
# Looper 报告：<NAME>
日期：<TIMESTAMP>  镜像：<IMAGE>  类型：<TYPE>

## 测试结果
| 测试 | 结果 | 详情 |
|------|------|------|
| T1 CC 可用性 | ✅/❌ | <T1_OUT> |
| T2 安装完整性 | ✅/❌ | <T2_OUT> |
| T3 触发测试 | ✅/❌ | <T3_OUT 节选> |
| T4 错误处理 | ✅/⏭️ | <T4_OUT 节选> |
| T5 eval suite | ✅/❌/⏭️ | <T5_RATE>（若 ⏭️ 则无 evals.json）|

## 触发输出（节选）
<T3_OUT>

## Eval Suite 输出（节选，若 T5 执行）
<T5_OUT 节选>

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
目标：<TYPE>:<NAME>
镜像：<IMAGE>

  T1 CC 可用性：     ✅ <version>
  T2 安装完整性：     ✅ <NAME>.md 已挂载
  T3 触发测试：       ✅ 触发成功（<输出摘要>）
  T4 错误处理：       ✅ graceful fallback
  T5 eval suite：    ✅ <T5_RATE> passed  |  ⏭️ skipped (no evals.json)

报告：<REPORT_FILE>

质量结论：✅ PASS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

整体 PASS 条件：T1-T3 全部 pass，且（T5 pass 或 T5 skip）。T4 仅 command 类型强制；T5 skip 不计入失败。

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
│   ├── settings.json         ← API 凭证 + model（从宿主机复制）
│   └── commands/<NAME>.md    ← 被测命令（command 模式）
│       或 skills/<NAME>/     ← 被测技能（skill/plugin 模式）
└── .claude.json              ← {"hasCompletedOnboarding":true}

/looper_work/                 ← LOOPER_TMP 挂载点
├── run_eval_suite.py         ← T5 eval runner（注入，若 evals.json 存在）
└── evals.json                ← eval 套件（注入，若存在）
```
