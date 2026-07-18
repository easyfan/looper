# Looper 设计文档

looper 是 packer 插件体系的**发布前验证工具**，在隔离的 Docker CC 容器中验证安装包的完整性和行为正确性。

---

## 1. 核心设计原则

### 容器隔离
所有测试在干净的 Docker CC 容器内执行，容器内 `~/.claude/` 仅含被测目标，无宿主机其他工具链干扰。这确保了"零依赖纯净安装"场景的可重复性。

### 两条安装路径
plugin 有两条交付路径，looper 对两者都需要验证：

| 路径 | 入口 | 用户场景 |
|------|------|---------|
| Plan A | `bash install.sh` | 手动安装、本地开发、CI 直接部署 |
| Plan B | `claude plugin install` | 通过 CC marketplace UI 安装（主要用户路径） |

两条路径互相独立，覆盖点不同，缺一不可。

### settings.json 分层构造
容器内 settings.json 按需构造，不直接挂载宿主机配置：
- **API 凭证**（`ANTHROPIC_API_KEY`、`ANTHROPIC_BASE_URL` 等）：按 `~/.claude/looper/credentials.env` → 宿主机 `settings.json` env 的优先级解析后注入容器；两处均无 key 时 T3/T5 自动降级为 skip（见 §5.1）
- **`extraKnownMarketplaces`**：Plan A 中为空；Plan B 中从空开始，通过测试步骤内的 `claude plugin marketplace add` 写入
- 目的：测试的是 CC 工具链自身的配置写入能力，而不是继承宿主机已有配置

---

## 2. Plan A — install.sh 路径

**测试对象**：`bash install.sh` 的安装脚本行为  
**容器内执行**：plugin 源文件以只读 volume 挂载到 `/plugin_src`，通过 `docker exec` 运行 install.sh

```bash
# docker run 额外参数
-v $PLUGIN_PATH:/plugin_src:ro

# 容器内执行
CLAUDE_DIR=/root/.claude bash /plugin_src/install.sh [--dry-run|--uninstall]
```

### 为何选择容器内执行（而非宿主机执行）

looper 的使用者是 plugin 的开发者——而开发者同时也是 plugin 的深度用户，其 `~/.claude/` 
里装着日常依赖的工具。若在宿主机上反复执行 install/uninstall，每次跑测试都在破坏自己的
工作台：已安装的 skills/commands/agents 会被卸载，再装回来时状态未必一致。

容器隔离不只是工程上的"更纯粹"，而是对使用这个工具的开发者的基本尊重：
测试环境和开发环境彼此独立，自动化测试可以放心地高频运行。

| 步骤 | 操作 | 断言 |
|------|------|------|
| A1 | `install.sh --dry-run` | 输出 N file(s) would be modified，无实际写入 |
| A2 | `install.sh --uninstall`（空环境）| 优雅处理 not found，exit 0 |
| A3 | `install.sh` 全新安装 | Done! N file(s) installed，exit 0 |
| A4 | `install.sh` 重复安装（幂等性）| Done! 0 file(s) installed |
| A5 | 验证已安装文件 | commands/agents/skills 各文件存在于 `$CLEAN_CLAUDE` |
| A6 | `install.sh --uninstall` | 各文件 Removed，exit 0 |
| A7 | 验证卸载后干净 | 已安装文件全部不存在 |

**注**：Plan A 对应现有 looper T2（安装完整性），将 T2 扩展为覆盖以上全部步骤。

---

## 3. Plan B — claude plugin install 路径

**测试对象**：CC marketplace 安装机制的完整用户路径  
**容器内执行，settings.json 可写（非 `:ro`），extraKnownMarketplaces 初始为空**

| 步骤 | 操作 | 断言 |
|------|------|------|
| B1 | `claude plugin marketplace add easyfan/<name>` | settings.json 写入 `extraKnownMarketplaces.<name>` |
| B2 | `claude plugin marketplace update <name>` | 返回 Successfully updated |
| B3 | `claude plugin install <name>` | 返回 Successfully installed |
| B4 | SHA 验证 | cache 里的 git sha == marketplace registry sha（防 stale cache）|
| B5 | 文件完整性 | commands/agents/skills 各文件存在于 plugin cache 目录 |
| B6 | `claude plugin uninstall <name>` | 返回 Successfully uninstalled；installed_plugins.json 条目移除（cache 目录由 CC 保留，不作断言）|
| B7 | `claude plugin marketplace remove <name>` | 返回 Successfully removed |
| B8 | 验证干净 | settings.json 中 `extraKnownMarketplaces.<name>` 不存在 |

**plugin.json schema 验证（T0）**：从 Plan B 移出，在宿主机执行一次，A/B 共用。  
`claude plugin validate` 对 marketplace.json 的 `$schema`/`description` 字段报 unrecognized（validator bug，已报 anthropics/claude-code#42412），T0 仅验证 plugin.json。

**marketplace add 参数格式**（已验证，CC v2.1.90）：
```bash
claude plugin marketplace add easyfan/<name>   # github shorthand
# 写入 settings.json: {"source": "github", "repo": "easyfan/<name>"}
```

---

## 4. settings.json 容器内构造方式

```
宿主机 settings.json
  ├── env (API 凭证)      → 注入容器 settings.json ✓
  ├── extraKnownMarketplaces → Plan A: 不写入；Plan B: 初始不写入，由测试步骤写入
  ├── hooks               → 不注入（测试环境不需要）
  └── permissions         → 不注入
```

容器内 settings.json 由 looper 在 Step 4 构造，而不是直接复制宿主机文件。Plan B 需要可写挂载（不能 `:ro`），因为 `claude plugin marketplace add` 需要写入该文件。

---

## 5. 与现有 T1–T5 的关系

| 测试 | 现状 | 变更 |
|------|------|------|
| T1 CC 可用性 | 保留 | 不变 |
| T2 安装完整性 | 仅检查文件存在 | 扩展为 Plan A 全步骤（A1–A7）|
| T2b marketplace 路径 | 无 | 新增 Plan B 全步骤（B1–B9）|
| T3 触发测试 | 保留 | 不变 |
| T4 错误处理 | 保留 | 不变 |
| T5 eval suite | 保留 | 不变 |

Plan A 和 Plan B 可通过 `--plan a`/`--plan b` 单独运行，默认两者都跑。

### 5.1 凭证缺失降级（T3/T5）

T3/T5 需要容器内 claude 实际调用 API。凭证按以下顺序解析后经 `docker -e` 注入：

1. **`~/.claude/looper/credentials.env`**（looper 专属凭证源，`KEY=VALUE` 格式，建议 600 权限）：
   让宿主机保持订阅 OAuth 的同时给容器独立 API key（如 OpenRouter relay），互不干扰
2. **宿主机 `settings.json` env**：`ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`（历史行为）

两处均无 key 时：

- **run.sh 启动时探测**：`NO_CRED=true`
- **T3**：整段跳过（省 120s 超时），标 `skip`，`output_snippet` 写明 no credentials 原因
- **T5**：不跑 eval，标 `skip`，`rate` 为 `no_credentials`
- **overall**：skip 不计入 fail——环境缺失≠插件回归，报告保持诚实

有凭证时行为不变；此外 T3 的失败关键词表包含 `Not logged in`/`Please run /login`：
有凭证但容器内仍未认证成功时判 fail，不允许静默 pass。

**空输出重试护栏**：relay 后端（如 OpenRouter）下 `claude -p` 存在间歇性空输出，
其中一部分是"模型以 tool_use 结尾、终局文本为空"的行为怪癖——agent 实际写了文件
但 stdout 为空。因此 T5 的判定规则是：文本空**且**零文件变更才算调用失败（重试一
次，仍失败则跳过 judge 直接全 fail，防止负向断言真空通过）；文本空但有文件变更视
为可判定，连同文件证据交给 judge。T3 空输出重试一次；judge 空输出同样重试一次。
诊断行记录 claude 退出码（rc=0 静默完成 / 137 OOM 被杀 / None 超时）。

---

## 6. 已知限制与 open questions

| 项 | 说明 |
|----|------|
| marketplace.json validator bug | `$schema`/`description` 被报 unrecognized，已报 #42412，修复后 B3 补全 |
| `claude plugin update` bug | 返回 "not found"，已报 anthropics/claude-code#42411；Plan B 不使用 update |
| CC 不执行 install.sh | `plugin.json` 的 `install` 字段被 CC 忽略（schema 不认），已从三个 plugin 删除 |
| CC plugin install 不 copy commands/agents | CC 从 plugin cache 动态加载，不写入 `~/.claude/commands/`；Plan B B6 验证 cache 而非 `~/.claude/` |
