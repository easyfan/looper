# looper

在纯净 Docker CC 容器中对 Claude Code 插件执行部署验证测试（安装完整性 + 触发准确性 + eval suite 行为验证 T5）。是 skill-test pipeline 的阶段 5 工具。

## 安装

```bash
bash install.sh
# 预览，不实际写入
bash install.sh --dry-run
# 卸载
bash install.sh --uninstall
# 指定 Claude 配置目录（参数或环境变量均可）
bash install.sh --target=~/.claude
CLAUDE_DIR=~/.claude bash install.sh
```

安装内容：
- `skills/looper/ → ~/.claude/skills/looper/`

> ✅ **已验证**：已通过 skill-test 流水线自动化验证（looper Stage 5）。

## 使用

```
/looper --plugin <name>                          # 验证 packer/<name>/
/looper --plugin <name> --plan a                 # 仅 Plan A（install.sh 路径）
/looper --plugin <name> --plan b                 # 仅 Plan B（claude plugin 安装路径）
/looper --plugin <name> --image <image>          # 显式指定容器镜像
/looper --help                                   # 查看用法说明
```

## 前置依赖

- **Docker**（宿主机直接可用；devcontainer 内运行时自动检测并优雅退出，输出提示）
- **CC runtime 镜像**（`cc-runtime-minimal`，见下；含 python3，供 T5 eval suite 执行）

## 镜像策略

looper 按以下优先级确定镜像（首次调用后持久化到 `packer/<name>/.looper-state.json`，后续调用复用）：

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

## 测试计划

looper 运行两个独立验证计划。默认 `--plan both` 全部执行，也可用 `--plan a` / `--plan b` 单独运行。

| 计划 | 步骤 | 验证内容 |
|------|------|---------|
| A | T2（A1–A7）| `install.sh` 接口合规性、文件安装、幂等性、卸载、dry-run |
| B | T2b（B1–B8）| `claude plugin install` 路径（marketplace / 本地 `plugin.json`）|

无论 `--plan` 取何值，以下测试始终运行：

| 测试 | 验证内容 |
|------|---------|
| T0 | `plugin.json` manifest 合法性检查（宿主机，仅一次）|
| T1 | 容器内 CC 可用性 |
| T3 | skill 触发准确性（单次 `claude -p` 调用）|
| T5 | 行为 eval suite（在容器内运行 `evals/evals.json`；`disable_t5: true` 时跳过）|

## 开发

### Evals

`evals/evals.json` 包含 7 个测试用例，覆盖当前 `--plugin` 专属 CLI 的主要场景：

| ID | 场景 | 验证重点 |
|----|------|---------|
| 1 | `/looper --help` | 用法文本包含四个参数说明和至少一个示例；不执行 Docker |
| 2 | `/looper`（无参数）| 输出用法说明；不执行任何 Docker 操作 |
| 3 | `/looper --plugin xyz_nonexistent_...` | 输出插件不存在错误；不启动容器 |
| 4 | `/looper --plugin looper --plan a` | 仅 Plan A；T2b 结果为 skip |
| 5 | `/looper --plugin looper --plan b` | 仅 Plan B；T2 结果为 skip |
| 6 | `/looper --plugin looper --image my-custom-registry:cc-runtime` | `--image` 参数；user-specified 策略；输出含镜像名 |
| 7 | `/looper --plugin looper` | 容器内找不到插件；优雅输出错误提示 |

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

## 包结构

```
looper/
├── .claude-plugin/
│   └── plugin.json             # 插件 manifest
├── skills/looper/
│   └── SKILL.md                # 安装到 ~/.claude/skills/looper/
├── scripts/
│   ├── run.sh                  # 核心验证逻辑
│   └── run_eval_suite.py       # T5 eval runner（注入容器执行）
├── assets/image/               # cc-runtime-minimal 镜像源
│   ├── Dockerfile
│   └── .github/workflows/build-push.yml
├── test/
│   ├── test-a.sh               # Plan A 宿主机测试
│   ├── test-b.sh               # Plan B 宿主机测试
│   └── test-all.sh
├── evals/evals.json
├── install.sh
└── package.json
```
