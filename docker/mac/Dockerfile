FROM --platform=linux/arm64 ubuntu:24.04

ARG RUNNER_VERSION="2.336.0"
ARG DEBIAN_FRONTEND=noninteractive

# Add a user for the runner
RUN useradd -m -s /bin/bash runner

# Install necessary packages, GitHub CLI, and Docker CLI.
# Docker CE *client* only — the daemon is provided either by the host socket
# mount or by the dind sidecar, so shipping an engine here would be dead weight.
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
    build-essential docker-buildx-plugin docker-ce-cli docker-compose-plugin gh git jq \
    iputils-ping libicu-dev libkrb5-3 openssh-client python3 sudo zlib1g \
    && rm -rf /var/lib/apt/lists/*

# Set up the runner user
WORKDIR /home/runner

# Set up the actions runner for ARM64
RUN mkdir -p /home/runner/actions-runner && cd /home/runner/actions-runner \
    && curl -o actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz -L https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz \
    && tar xzf actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz

# Install dependencies, then hand the tree to the runner user — config.sh writes
# .runner/.credentials/_diag/_work into it and root-owned dirs would break that.
RUN cd /home/runner/actions-runner \
    && ./bin/installdependencies.sh \
    && chown -R runner:runner /home/runner

# Copy the start script and make it executable
COPY start.sh /home/runner/start.sh
RUN chown runner:runner /home/runner/start.sh && chmod +x /home/runner/start.sh

# NOTE: no USER directive on purpose. start.sh needs root to align the mounted
# Docker socket's group, then drops to the unprivileged `runner` user via
# setpriv before ever touching config.sh/run.sh.

# Define the entrypoint
ENTRYPOINT ["/home/runner/start.sh"]
