# cc-runtime-minimal
# 最小可用 Claude Code runtime，供 looper 等工具在纯净容器中验证 skill/command。
#
# 构建：
#   docker build -t cc-runtime-minimal packer/looper/assets/
#
# 推送（维护者）：
#   docker tag cc-runtime-minimal <your-org>/cc-runtime-minimal:latest
#   docker push <your-org>/cc-runtime-minimal:latest

FROM node:20-slim

RUN npm install -g @anthropic-ai/claude-code --quiet

# 验证安装
RUN claude --version

USER root
WORKDIR /root
