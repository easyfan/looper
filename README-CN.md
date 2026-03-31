# looper

在纯净 Docker CC 容器中对 command/skill/plugin 执行部署验证测试（安装完整性 + 触发准确性 + eval suite 行为验证 T5）。是 skill-test pipeline 的阶段 5 工具。

## 安装

```bash
bash install.sh
# 或指定 claude 目录
bash install.sh --target ~/.claude
# 或使用 CLAUDE_DIR 约定
CLAUDE_DIR=~/.claude bash install.sh
```

安装内容：
- `commands/looper.md → ~/.claude/commands/looper.md`
- `assets/config/.claude.json → ~/.claude/looper/.claude.json`

> ✅ **已验证**：已通过 skill-test 流水线自动化验证（looper Stage 5）。

## 使用

```
/looper --plugin <pkg>                    # 安装并验证 packer/<pkg>/
/looper --plugin <pkg> --image <image>   # 显式指定容器镜像
```

## 前置依赖

- **Docker**（宿主机直接可用；devcontainer 内运行时自动检测并优雅退出，输出提示）
- **CC runtime 镜像**（`cc-runtime-minimal`，见下；含 python3，供 T5 eval suite 执行）

## 镜像策略

looper 按以下优先级确定镜像（首次调用后持久化到 `looper/.looper-state.json`，后续调用复用）：

| 优先级 | 来源 | 说明 |
|--------|------|------|
| 1 | `--image <image>` 参数 | 显式指定，最高优先级；不写入状态缓存 |
| 2 | `.looper-state.json` 缓存 | 复用上次调用的镜像 |
| 3 | `.devcontainer/devcontainer.json` | 自动读取项目标准镜像 |
| 4 | 本地已有 `cc-runtime-minimal` | 之前构建或拉取的缓存 |
| 5 | Fallback 引导 | 输出获取 `cc-runtime-minimal` 的指令 |

### 获取 cc-runtime-minimal

**拉取（推荐）**：
```bash
docker pull easyfan/agents-slim:cc-runtime-minimal
docker tag easyfan/agents-slim:cc-runtime-minimal cc-runtime-minimal
```

**本地构建**（安全审计场景）：
```bash
docker build -t cc-runtime-minimal assets/image/
```

镜像源码：[easyfan/agents-slim](https://github.com/easyfan/agents-slim)

## 开发

### Evals

`evals/evals.json` 包含 10 个测试用例，覆盖参数解析、目标查找、Docker 可用性检测、镜像策略和 T5 eval suite 执行的主要分支：

| ID | 场景 | 验证重点 |
|----|------|---------|
| 1 | `/looper --plugin patterns` | 解析参数、检查目标路径存在、Docker 可用性检测；Docker 不可用时优雅退出；Docker 可用时触发 T5（evals.json 存在） |
| 2 | `/looper --plugin xyz_nonexistent_...` | 目标不存在时输出"❌ target not found"，不尝试启动容器 |
| 3 | `/looper --plugin patterns`（完整流程）| 定位 `packer/patterns/`，执行 `install.sh`，构建纯净环境，运行 T1–T3 |
| 4 | `/looper`（无参数）| 输出用法说明；不执行任何 Docker 操作 |
| 5 | `/looper --plugin patterns --image my-custom-registry:cc-runtime` | `--image` 参数设置 user-specified 策略（优先级 1），跳过 devcontainer 检测和缓存 |
| 6 | 同上（前置 `.looper-state.json`）| 读取缓存状态文件，直接复用已记录镜像，不重新检测 |
| 7 | 镜像策略输出验证 | 执行过程中输出含镜像名和策略说明（devcontainer / user-specified / fallback / cached 之一） |
| 8 | T5 激活路径 — `/looper --plugin patterns`（evals.json 存在）| Step 4 注入 eval runner + evals.json；Docker 可用时 T5 执行并输出 EVAL_SUITE_RESULT |
| 9 | T5 跳过路径 — `disable_t5: true` in evals.json | Step 4 输出"eval suite: skipped (disable_t5=true)"；T5 行显示 ⏭️；整体结果不因此失败 |

### 跳过 T5

在 `evals.json` 顶层加 `"disable_t5": true` 可阻止 looper 在容器内执行 eval suite。适用场景：被测工具是 looper 自身（容器内运行 `/looper` 需要 Docker-in-Docker），或其他无法在干净环境中执行的工具。

```json
{
  "skill_name": "looper",
  "disable_t5": true,
  "evals": [ ... ]
}
```

Step 4 进度输出将显示 `eval suite: skipped (disable_t5=true in evals.json)`，整体结果不因此标记为 FAIL。

手动测试（在 Claude Code 会话中）：
```bash
/looper --plugin patterns     # 对应 eval 1
/looper                       # 对应 eval 4（查看用法说明）
```

使用 skill-creator 的 eval loop 批量运行（如已安装）：
```bash
python ~/.claude/skills/skill-creator/scripts/run_loop.py \
  --skill-path ~/.claude/commands/looper.md \
  --evals-path evals/evals.json
```

## 包结构

```
looper/
├── commands/looper.md          # 安装到 ~/.claude/commands/
├── assets/
│   ├── config/.claude.json     # 安装到 ~/.claude/looper/
│   └── image/                  # cc-runtime-minimal 镜像源
│       ├── Dockerfile
│       └── .github/workflows/build-push.yml
├── evals/evals.json
├── install.sh
└── SKILL.md
```
