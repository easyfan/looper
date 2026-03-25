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
- `--image <image>` → USER_IMAGE=`<image>`（可选，显式指定镜像；首次调用时覆盖 devcontainer，非首次调用时覆盖缓存配置）

若参数为空或格式不合法，输出用法说明后退出：

```
用法：/looper --command <name> | --skill <name> | --plugin <pkg> [--image <image>]
示例：
  /looper --command patterns                              — 验证 patterns 命令
  /looper --skill skill-creator                          — 验证 skill-creator 插件
  /looper --plugin news-digest                           — 验证 news-digest 安装包
  /looper --command patterns --image node:20-slim        — 使用指定镜像验证
```

---

## Step 1：解析目标路径

根据 TYPE 查找源文件：

```bash
# command
COMMAND_PATH="$HOME/.claude/commands/${NAME}.md"

# skill：先找用户级 plugin cache，再找 skills/
SKILL_PATH=$(find "$HOME/.claude" -maxdepth 8 -name "${NAME}" -type d 2>/dev/null | head -1)

# plugin：项目 packer 目录
PLUGIN_PATH="$(pwd)/packer/${NAME}"
```

若目标不存在，输出后退出（**不启动容器**）：

```
❌ 目标未找到：<TYPE>:<NAME>
  期望路径：<resolved_path>
  请确认名称拼写，或检查是否已安装后重试。
```

---

## Step 2：检查 Docker 可用性

**先检测是否在容器内运行（DinD 不支持）**：

```bash
# 检测是否在 devcontainer / Docker 容器内
if [ -f "/.dockerenv" ] || grep -q "docker\|lxc\|containerd" /proc/1/cgroup 2>/dev/null; then
  # 容器内环境：Docker-in-Docker 不支持
  echo "⚠️ 当前 CC 运行于容器/devcontainer 内，不支持 Docker-in-Docker (DinD)。"
  echo "  若需完整验证，请在宿主机直接运行："
  echo "    /looper --<TYPE> <NAME>"
  echo "  或仅运行静态分析（无容器测试）。"
  # 退出（不算失败）
  exit 0
fi
```

**再检查宿主机 Docker 守护进程**：

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

## Step 3：镜像策略选择

> **三级优先级（首次调用）**：devcontainer.json 自动检测 → 用户 `--image` 显式指定 → 最小 CC runtime fallback
> **非首次调用**：默认沿用项目状态文件中的上次配置；`--image` 参数可强制覆盖。

```bash
# 项目级镜像状态文件（跨调用持久化）
LOOPER_STATE="$(pwd)/looper/.looper-state.json"
IMAGE=""
IMAGE_STRATEGY=""

# ── 非首次调用：优先读取缓存配置 ──────────────────────────────────────────
if [ -f "$LOOPER_STATE" ] && [ -z "${USER_IMAGE:-}" ]; then
  _prev=$(python3 -c "
import json, sys
try:
  d = json.load(open('$LOOPER_STATE'))
  print(d.get('image','') + '|||' + d.get('strategy',''))
except:
  pass
" 2>/dev/null)
  if [ -n "$_prev" ]; then
    IMAGE="${_prev%%|||*}"
    IMAGE_STRATEGY="cached（沿用首次配置：${_prev##*|||}）"
  fi
fi

# ── 首次调用 / --image 强制覆盖 ────────────────────────────────────────────
if [ -z "$IMAGE" ] || [ -n "${USER_IMAGE:-}" ]; then
  IMAGE=""
  IMAGE_STRATEGY=""

  # 优先级 1：devcontainer.json（项目标准环境，自动检测）
  DEVCONTAINER="$(pwd)/.devcontainer/devcontainer.json"
  if [ -f "$DEVCONTAINER" ]; then
    IMAGE=$(python3 -c "
import json, re, sys
try:
  txt = open('$DEVCONTAINER').read()
  txt = re.sub(r'//.*', '', txt)    # 去行注释
  txt = re.sub(r',\s*}', '}', txt)  # 去尾逗号
  cfg = json.loads(txt)
  print(cfg.get('image',''))
except:
  pass
" 2>/dev/null)
    [ -n "$IMAGE" ] && IMAGE_STRATEGY="devcontainer（自动检测）"
  fi

  # 优先级 2：用户明确指定（--image 参数）
  if [ -z "$IMAGE" ] && [ -n "${USER_IMAGE:-}" ]; then
    IMAGE="$USER_IMAGE"
    IMAGE_STRATEGY="user-specified（--image 参数）"
  fi

  # 优先级 3：本地已有 cc-runtime-minimal（之前构建或拉取的缓存）
  if [ -z "$IMAGE" ]; then
    if docker image inspect cc-runtime-minimal > /dev/null 2>&1; then
      IMAGE="cc-runtime-minimal"
      IMAGE_STRATEGY="local-cached（cc-runtime-minimal）"
    fi
  fi

  # 优先级 4：fallback — 引导用户获取 cc-runtime-minimal
  if [ -z "$IMAGE" ]; then
    echo ""
    echo "⚠️  未检测到可用的 CC runtime 镜像。"
    echo ""
    echo "  请选择获取 cc-runtime-minimal 的方式，然后重新运行 /looper："
    echo ""
    echo "  [A] 本地构建（可审计，首次约 3-5 分钟）："
    echo "      docker build -t cc-runtime-minimal $(pwd)/packer/looper/assets/"
    echo ""
    echo "  [B] 拉取预构建镜像（快速）："
    echo "      docker pull <your-org>/cc-runtime-minimal:latest"
    echo "      docker tag <your-org>/cc-runtime-minimal:latest cc-runtime-minimal"
    echo ""
    echo "  [C] 直接指定已有镜像（跳过此提示）："
    echo "      /looper --$(echo $TYPE) $(echo $NAME) --image <image>"
    echo ""
    exit 0
  fi

  # 持久化到状态文件（供后续调用沿用）
  mkdir -p "$(dirname "$LOOPER_STATE")"
  python3 -c "
import json
d = {
  'image': '$IMAGE',
  'strategy': '$IMAGE_STRATEGY',
  'timestamp': '$(date -u +%Y-%m-%dT%H:%M:%SZ)'
}
with open('$LOOPER_STATE', 'w') as f:
  json.dump(d, f, indent=2, ensure_ascii=False)
" 2>/dev/null || true
fi

# 代理（继承宿主机环境变量，未设置则为空）
PROXY="${HTTP_PROXY:-${http_proxy:-}}"
NO_PROXY_LIST="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1,::1}}"

# looper/.claude.json（CC 入门跳过配置）
CLAUDE_JSON="$(pwd)/looper/.claude.json"
if [ ! -f "$CLAUDE_JSON" ]; then
  CLAUDE_JSON=$(mktemp /tmp/looper_claudejson_XXXXXX)
  echo '{"hasCompletedOnboarding":true}' > "$CLAUDE_JSON"
fi
```

---

## Step 4：构建纯净 CC 工作目录

> **纯净原则**：容器内 `~/.claude/` 只含 `settings.json`（API 凭证）+ 被测目标，不挂载宿主机完整 `~/.claude/`，确保零其他工具链干扰。

```bash
# macOS Docker Desktop 默认只共享 /Users，/tmp 挂载可能失败
# 优先使用 $HOME 下的路径；fallback 到 /tmp
_TMP_BASE="${HOME:-}"
if [ -z "$_TMP_BASE" ] || [ "$(uname)" != "Darwin" ]; then
  _TMP_BASE="/tmp"
fi
LOOPER_TMP=$(mktemp -d "${_TMP_BASE}/looper_XXXXXX")
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

输出进度：

```
[环境准备]
  镜像：<IMAGE>
  镜像策略：<IMAGE_STRATEGY>
  纯净 CC 目录：<LOOPER_TMP>
  目标：<TYPE>:<NAME>
  settings.json：已复制（API 凭证 + 模型配置）
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
  -e HTTP_PROXY="$PROXY" \
  -e HTTPS_PROXY="$PROXY" \
  -e http_proxy="$PROXY" \
  -e https_proxy="$PROXY" \
  -e NO_PROXY="$NO_PROXY_LIST" \
  -e no_proxy="$NO_PROXY_LIST" \
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
日期：<TIMESTAMP>  类型：<TYPE>

## 镜像配置
| 字段 | 值 |
|------|----|
| 镜像 | `<IMAGE>` |
| 应用策略 | <IMAGE_STRATEGY> |

## 测试结果
| 测试 | 结果 | 详情 |
|------|------|------|
| T1 CC 可用性 | ✅/❌ | <T1_OUT> |
| T2 安装完整性 | ✅/❌ | <T2_OUT> |
| T3 触发测试 | ✅/❌ | <T3_OUT 节选> |
| T4 错误处理 | ✅/⏭️ | <T4_OUT 节选> |

## 触发输出（节选）
<T3_OUT>

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
镜像策略：<IMAGE_STRATEGY>

  T1 CC 可用性：     ✅ <version>
  T2 安装完整性：     ✅ <NAME>.md 已挂载
  T3 触发测试：       ✅ 触发成功（<输出摘要>）
  T4 错误处理：       ✅ graceful fallback

报告：<REPORT_FILE>

质量结论：✅ PASS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**若 FAIL**，追加：

```
⚠️ looper 是终态验证工具，不迭代。
失败根因分类：
  触发率 0%      → description 未收敛，回溯到 eval 阶段：/skill-test --from-stage 3
  安装残缺        → 检查 SKILL.md 依赖声明，补全后重新安装
  CC 启动失败     → 检查镜像可用性：docker pull <IMAGE>
                   镜像策略为 <IMAGE_STRATEGY>，如需切换请用 --image 参数
                   如使用 cc-runtime-minimal，可本地重建：
                     docker build -t cc-runtime-minimal $(pwd)/packer/looper/assets/
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
```
