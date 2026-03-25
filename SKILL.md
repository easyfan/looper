---
name: looper
description: 在纯净 Docker CC 容器中对 command/skill/plugin 执行部署验证测试（安装完整性 + 触发准确性）。是 skill-test pipeline 的阶段 5 工具。
---

# looper 包

## 包含文件

- `commands/looper.md` → 安装到 `~/.claude/commands/looper.md`

## 前置依赖

- Docker（**宿主机**直接可用；在 devcontainer / 容器内运行时会检测并提示不支持 DinD，优雅退出）
- `/workspace/looper/.claude.json`（CC 入门跳过配置，已存在于 looper/ 目录）
- macOS：Docker Desktop 需开启 `/Users` 路径共享（默认已开启）；临时目录自动使用 `$HOME` 路径，避免 `/tmp` 挂载失败

## 镜像选择策略

looper 在项目**首次调用**时按以下优先级确定镜像，并持久化到 `looper/.looper-state.json`；**非首次调用**默认沿用缓存配置：

| 优先级 | 来源 | 触发条件 | 策略标识 |
|--------|------|----------|---------|
| 1（最高）| `.devcontainer/devcontainer.json` | 文件存在且含 `image` 字段 | `devcontainer（自动检测）` |
| 2 | `--image <image>` 参数 | 用户在调用时显式指定 | `user-specified（--image 参数）` |
| 3 | 本地已有 `cc-runtime-minimal` | 之前已构建或拉取 | `local-cached` |
| 4（fallback）| 引导用户获取 `cc-runtime-minimal` | 上述均不满足 | `fallback（引导构建/拉取）` |

> **fallback 行为**：looper 输出引导提示，供用户选择：
> - 从 `assets/Dockerfile` 本地构建：`docker build -t cc-runtime-minimal packer/looper/assets/`
> - 从 DockerHub 拉取预构建镜像：`docker pull <your-org>/cc-runtime-minimal:latest && docker tag ... cc-runtime-minimal`
>
> 选择完成后重新执行 `/looper` 命令，或使用 `--image` 参数直接指定。
>
> 非首次调用时如需切换镜像，使用 `--image <image>` 参数强制覆盖缓存。

所用镜像和策略在执行报告（Step 7 `.md` + Step 9 终端输出）中均有明确记录。

## 已知限制

| 场景 | 行为 |
|------|------|
| 在 devcontainer / 容器内运行 | Step 2 检测 `/.dockerenv`，输出 DinD 不支持提示后 exit 0 |
| macOS Docker Desktop + `/tmp` | Step 4 自动改用 `$HOME` 路径创建临时目录 |
| skill 搜索深度 | `find -maxdepth 8`，覆盖 `~/.claude/plugins/cache/.../skills/<name>` 路径（depth=7） |
| 镜像状态文件 | `looper/.looper-state.json`，非首次调用时自动读取；`--image` 参数可覆盖 |

## 用途

在 skill-test 流水线的阶段 5 验证 skill 在完全干净的 CC 环境（无其他工具链污染）中的行为，
确保安装后可触发、无安装残缺。
