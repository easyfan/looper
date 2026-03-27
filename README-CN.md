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

安装内容：`commands/looper.md → ~/.claude/commands/looper.md`

> ✅ **已验证**：已通过 skill-test 流水线自动化验证（looper Stage 5）。

## 使用

```
/looper --command <name>     # 验证 ~/.claude/commands/<name>.md
/looper --skill <name>       # 验证 ~/.claude/skills/<name>/
/looper --plugin <pkg>       # 安装并验证 packer/<pkg>/ 包
```

可选 `--image <image>` 参数显式指定镜像。

## 前置依赖

- Docker（宿主机直接可用；devcontainer 内运行时自动跳过并提示）
- CC runtime 镜像（`cc-runtime-minimal`，见下；含 python3，供 T5 eval suite 执行）

## 镜像策略

looper 按以下优先级确定镜像（首次调用后持久化到 `looper/.looper-state.json`）：

| 优先级 | 来源 | 说明 |
|--------|------|------|
| 1 | `.devcontainer/devcontainer.json` | 自动读取项目标准镜像 |
| 2 | `--image <image>` 参数 | 显式指定 |
| 3 | 本地已有 `cc-runtime-minimal` | 之前构建或拉取的缓存 |
| 4 | fallback 引导 | 输出获取 `cc-runtime-minimal` 的指令 |

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
| 1 | `/looper --command patterns` | 解析参数、检查目标文件存在、Docker 可用性检测；Docker 不可用时优雅退出；Docker 可用时 T5 触发（evals.json 存在） |
| 2 | `/looper --command xyz_nonexistent_...` | 目标不存在时输出"❌ 目标未找到"，不尝试启动容器 |
| 3 | `/looper --plugin patterns` | TYPE=plugin 路径：查找 packer/ 目录，执行 install.sh 后测试 |
| 4 | `/looper`（无参数）| 输出完整用法说明（含四种参数），不执行任何 Docker 操作 |
| 5 | `/looper --skill skill-creator` | TYPE=skill 路径：在 ~/.claude 下搜索目录，构建纯净环境测试触发 |
| 6 | `/looper --command patterns --image my-custom-registry:cc-runtime` | `--image` 显式指定镜像，策略为 user-specified，跳过 devcontainer 检测 |
| 7 | 同上（前置 `.looper-state.json`）| 读取缓存状态文件，直接沿用已记录镜像，不重新检测 |
| 8 | 镜像策略输出验证 | 执行过程中输出含镜像名和策略说明（devcontainer/user-specified/fallback/cached 之一） |
| 9 | T5 激活路径 — `/looper --plugin patterns`（evals.json 存在）| Step 4 注入 eval runner + evals.json；Docker 可用时 T5 执行并输出 EVAL_SUITE_RESULT |
| 10 | T5 跳过路径 — `/looper --skill skill-creator`（skill 路径无 evals.json）| Step 4 输出 "eval suite: skipped"；T5 行显示 ⏭️；整体结果不因 T5 跳过而失败 |

手动测试（在 Claude Code 会话中）：
```bash
/looper --command patterns     # 对应 eval 1
/looper                        # 对应 eval 4（查看用法说明）
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
├── commands/looper.md      # 安装到 ~/.claude/commands/
├── assets/
│   └── image/              # cc-runtime-minimal 镜像源
│       ├── Dockerfile
│       └── .github/workflows/build-push.yml
├── evals/evals.json
├── install.sh
└── SKILL.md
```
