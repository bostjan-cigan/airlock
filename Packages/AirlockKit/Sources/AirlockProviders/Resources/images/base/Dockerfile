# AIrlock base image: shared by every agent provider.
# Non-root `node` user (uid 1000), no sudo, tools agents commonly need,
# plus the AIrlock init, firewall and hook helpers.
# FROM_IMAGE is a project's own agent image (`.airlock/compose.yaml`); it must be
# Debian or Ubuntu based. Node comes along for installing the agent.
ARG FROM_IMAGE=node:22-bookworm-slim
FROM node:22-bookworm-slim AS node
FROM ${FROM_IMAGE}
USER root
RUN command -v apt-get >/dev/null || { echo "AIrlock needs a Debian or Ubuntu based image for the agent." >&2; exit 1; }
COPY --from=node /usr/local/bin/node /opt/airlock-node/bin/node
COPY --from=node /usr/local/lib/node_modules/npm /opt/airlock-node/lib/node_modules/npm
RUN command -v node >/dev/null || ln -s /opt/airlock-node/bin/node /usr/local/bin/node; \
    command -v npm >/dev/null || ln -s /opt/airlock-node/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
    id node >/dev/null 2>&1 || useradd -m -s /bin/zsh -u 1000 node 2>/dev/null || useradd -m -s /bin/zsh node

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl dnsmasq-base dnsutils gh git git-lfs jq less locales nftables procps \
        ripgrep socat tmux util-linux xz-utils zsh \
    && rm -rf /var/lib/apt/lists/*

# mise installs a project's tools (Python, Go, Rust, Java…) into a cached image layer.
RUN curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh \
    && mise --version

ENV LANG=C.UTF-8 \
    TERM=xterm-256color \
    SHELL=/bin/zsh \
    PATH=/home/node/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    MISE_YES=1 \
    MISE_TRUSTED_CONFIG_PATHS=/workspace

COPY airlock-init airlock-firewall airlock-hook airlock-install airlock-install-handler airlock-proxy airlock-inspect /usr/local/bin/
COPY tmux.conf /etc/tmux.conf
COPY zshrc /home/node/.zshrc
# Worktree mounts are owned by the host user; let git operate on them anyway.
# The credential proxy's own user: the agent (node) can't read its files or its process.
RUN useradd --system --no-create-home --shell /usr/sbin/nologin airlock-proxy \
    && git config --system safe.directory '*' \
    && git config --system init.defaultBranch main \
    && chmod 0755 /usr/local/bin/airlock-* \
    && git lfs install --system --skip-repo \
    && mkdir -p /workspace /airlock/events /home/node/.claude /home/node/.cache \
    && chown -R node:node /workspace /airlock /home/node

WORKDIR /workspace
# PID 1 (under Docker's init) is airlock-init as root: it applies the network
# policy, then drops to `node` for good.
# A project image's own entrypoint would swallow it.
ENTRYPOINT []
CMD ["/usr/local/bin/airlock-init"]
