# agents-slim

Minimal Docker images for AI agent tooling. Each image ships only what a specific runtime needs — no dev tools, no bloat.

## Images

| Tag | Base | Description |
|-----|------|-------------|
| `cc-runtime-minimal` | `node:20-slim` | Claude Code CLI runtime with git and CA certificates for isolated plugin verification |
| `cc-runtime-minimal-YYYY-MM` | same | Dated tag for version pinning |

## Usage

```bash
# Pull latest
docker pull easyfan/agents-slim:cc-runtime-minimal

# Pin to a specific month
docker pull easyfan/agents-slim:cc-runtime-minimal-2026-03
```

## Build from source

```bash
docker build -t cc-runtime-minimal .
```

## Design principles

- **Minimal** — only the runtime, nothing else
- **Auditable** — Dockerfile is the source of truth; the published image is a pre-built artifact of it
- **Stable tags** — `cc-runtime-minimal` (latest) + monthly dated tags for pinning
