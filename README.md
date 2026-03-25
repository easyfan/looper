# looper

在纯净 Docker CC 容器中对 command/skill/plugin 执行部署验证测试（安装完整性 + 触发准确性）。是 skill-test pipeline 的阶段 5 工具。

## 安装

```bash
bash install.sh
# 或指定 claude 目录
bash install.sh --target ~/.claude
```

安装内容：`commands/looper.md → ~/.claude/commands/looper.md`

## 使用

```
/looper --command <name>     # 验证 ~/.claude/commands/<name>.md
/looper --skill <name>       # 验证 ~/.claude/skills/<name>/
/looper --plugin <pkg>       # 安装并验证 packer/<pkg>/ 包
```

可选 `--image <image>` 参数显式指定镜像。

## 前置依赖

- Docker（宿主机直接可用；devcontainer 内运行时自动跳过并提示）
- CC runtime 镜像（`cc-runtime-minimal`，见下）

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
