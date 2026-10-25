FROM node:22-bookworm-slim

# 国内服务器默认走 npmmirror；海外可以 --build-arg NPM_REGISTRY=https://registry.npmjs.org
ARG NPM_REGISTRY=https://registry.npmmirror.com
RUN npm install -g @anthropic-ai/claude-code --registry="$NPM_REGISTRY" && npm cache clean --force

ENV NODE_ENV=production \
    HOST=127.0.0.1 \
    PORT=8400 \
    DATA_DIR=/data \
    PERSONA_FILE=/lumi/CLAUDE.md \
    CLAUDE_CONFIG_DIR=/home/node/.claude \
    DISABLE_AUTOUPDATER=1

RUN mkdir -p /data /home/node/.claude && chown -R node:node /data /home/node/.claude

WORKDIR /app
COPY server.js frontend-prompt.md ./
COPY static ./static

USER node
EXPOSE 8400
CMD ["node", "server.js"]
