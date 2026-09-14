FROM ubuntu:24.04

ARG RUNNER_VERSION="2.337.0"
ARG DEBIAN_FRONTEND=noninteractive

# Update and upgrade the system
RUN apt update -y && apt upgrade -y && rm -rf /var/lib/apt/lists/*

# Add a user named docker
RUN useradd -m docker

# Install necessary packages, GitHub CLI, and Docker CLI
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    build-essential docker-buildx-plugin docker-ce-cli docker-compose-plugin gh git jq libffi-dev libssl-dev \
    python3 python3-dev python3-pip python3-venv ssh sudo \
    && rm -rf /var/lib/apt/lists/*

# Chromium's shared libraries, for Playwright.
#
# FAILURE THIS PREVENTS: `playwright install --with-deps` needs root, and a job in this image runs
# as `docker` with a password-protected sudo — so it falls back to installing the BROWSER without
# the system packages, and the browser then dies at launch with
#   chrome-headless-shell: error while loading shared libraries: libglib-2.0.so.0
# four minutes into the run, inside a fixture, under sixty lines of Chrome flags. Measured
# 2026-09-14 on the first run of stoxly.ai.mvp's `web-e2e` job — the first job on this pool ever to
# launch a browser.
#
# The list is Playwright's own for `ubuntu24.04-x64` / chromium
# (`playwright-core/lib/server/registry/nativeDeps.js`), not a hand-picked one. `fonts-liberation`
# is added so text renders rather than falling back to boxes in screenshots.
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-liberation libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
    libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 \
    libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 \
    libxkbcommon0 libxrandr2 \
    && rm -rf /var/lib/apt/lists/*

# Set up the actions runner
RUN cd /home/docker && mkdir actions-runner && cd actions-runner \
    && curl -o actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz \
    && tar xzf actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz

# Change ownership to docker user and install dependencies
RUN chown -R docker /home/docker && /home/docker/actions-runner/bin/installdependencies.sh

# Copy the start script and make it executable
COPY --chmod=+x start.sh /start.sh

# NOTE: no USER directive on purpose. start.sh needs root to align the mounted
# Docker socket's group, then drops to the unprivileged `docker` user via
# setpriv before ever touching config.sh/run.sh.

# Define the entrypoint
ENTRYPOINT ["/start.sh"]
