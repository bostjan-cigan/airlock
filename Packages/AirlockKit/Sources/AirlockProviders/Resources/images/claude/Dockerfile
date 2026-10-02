# Claude Code layered on the AIrlock base image.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG CLAUDE_CODE_VERSION=latest
# --prefix: on a project's own image Node is AIrlock's copy, whose default prefix isn't on PATH.
RUN npm install -g --prefix /usr/local "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force

# Managed settings take precedence over anything in ~/.claude or the repo, so
# the agent can't remove the hooks AIrlock relies on.
COPY managed-settings.json /etc/claude-code/managed-settings.json

ENV CLAUDE_CONFIG_DIR=/home/node/.claude \
    DISABLE_AUTOUPDATER=1
