#!/bin/bash
set -uo pipefail

RUNNER_USER="docker"
RUNNER_HOME="/home/docker"
RUNNER_DIR="/home/docker/actions-runner"

: "${REPO:?REPO env var required}"
: "${REG_TOKEN:?REG_TOKEN env var required}"

# ---------------------------------------------------------------------------
# Stage 1 — root. Grant Docker access, then drop to the unprivileged runner.
#
# The container starts as root purely so this stage can run; the GitHub runner
# itself never executes as root (config.sh/run.sh refuse to).
# ---------------------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    # Socket-mount (DooD) mode. Skipped when DOCKER_HOST points at a remote
    # daemon, which is how the docker-compose.dind.yml sidecar is wired up.
    if [ -z "${DOCKER_HOST:-}" ] && [ -S /var/run/docker.sock ]; then
        SOCK_GID="$(stat -c '%g' /var/run/docker.sock)"
        # Reuse whatever group already holds that GID before inventing one.
        # On Docker Desktop / OrbStack the socket is root-owned (gid 0), so this
        # resolves to `root`; on a plain Linux host it is usually the host's
        # `docker` group and a matching `dockerhost` group gets created.
        SOCK_GROUP="$(getent group "${SOCK_GID}" | cut -d: -f1)"

        if [ -z "${SOCK_GROUP}" ]; then
            SOCK_GROUP="dockerhost"
            groupadd -g "${SOCK_GID}" "${SOCK_GROUP}"
        fi

        # Supplementary membership only — never remap the user's primary group,
        # which would orphan everything already chowned in /home/docker.
        usermod -aG "${SOCK_GROUP}" "${RUNNER_USER}"
        echo "Docker socket owned by gid ${SOCK_GID}; added ${RUNNER_USER} to group ${SOCK_GROUP}"
    fi

    # A bind-mounted or named-volume work dir arrives owned by root.
    if [ -n "${WORK_DIR:-}" ]; then
        mkdir -p "${WORK_DIR}"
        chown "${RUNNER_USER}:${RUNNER_USER}" "${WORK_DIR}"
    fi

    # --init-groups is the fix for "permission denied ... /var/run/docker.sock":
    # usermod cannot retroactively change the credentials of a running process,
    # so the group membership has to be picked up by a fresh exec.
    exec setpriv --reuid "${RUNNER_USER}" --regid "${RUNNER_USER}" --init-groups "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Stage 2 — unprivileged runner user.
# ---------------------------------------------------------------------------

# There is no USER directive in the Dockerfile, so Docker hands us HOME=/root
# and setpriv does not rewrite it. Without this, anything that touches the home
# directory — git config, ~/.docker/config.json, npm, actions/checkout — fails
# with permission denied.
export HOME="${RUNNER_HOME}"
export USER="${RUNNER_USER}"
export LOGNAME="${RUNNER_USER}"

if [ -n "${DOCKER_HOST:-}" ]; then
    echo "Waiting for Docker daemon at ${DOCKER_HOST}..."
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && break
        sleep 2
    done
    if docker info >/dev/null 2>&1; then
        echo "Docker daemon ready."
    else
        echo "WARNING: Docker daemon at ${DOCKER_HOST} is not reachable." >&2
    fi
fi

cd "${RUNNER_DIR}" || exit 1

CONFIG_ARGS="--url https://github.com/${REPO} --token ${REG_TOKEN} --unattended --replace"

# Leave NAME unset to let the runner default to the container hostname, which
# Docker makes unique per container — that is what allows deploy.replicas > 1.
# Setting NAME pins every replica to the same identity, so only use it when
# running a single runner.
[ -n "${NAME:-}" ]         && CONFIG_ARGS="${CONFIG_ARGS} --name ${NAME}"

if [ -n "${NAME:-}" ]; then
    echo "NOTE: NAME is set to '${NAME}'. Every container sharing this value registers as"
    echo "      the same runner and evicts the previous one, which then fails with"
    echo "      'the runner registration has been deleted from the server'. Unset NAME"
    echo "      when running more than one replica."
fi
[ -n "${LABELS:-}" ]       && CONFIG_ARGS="${CONFIG_ARGS} --labels ${LABELS}"
[ -n "${RUNNER_GROUP:-}" ] && CONFIG_ARGS="${CONFIG_ARGS} --runnergroup ${RUNNER_GROUP}"
[ -n "${WORK_DIR:-}" ]     && CONFIG_ARGS="${CONFIG_ARGS} --work ${WORK_DIR}"
[ "${EPHEMERAL:-}" = "true" ]            && CONFIG_ARGS="${CONFIG_ARGS} --ephemeral"
[ "${DISABLE_AUTO_UPDATE:-}" = "true" ]  && CONFIG_ARGS="${CONFIG_ARGS} --disableupdate"

# The container filesystem survives a restart, so a runner that registered
# successfully once still has .runner on the next start and config.sh refuses
# to run again ("Cannot configure the runner because it is already
# configured"). The stored credentials stay valid long after REG_TOKEN's
# one-hour expiry, so reuse them instead of trying to re-register.
if [ -f .runner ]; then
    echo "Runner already configured; reusing the existing registration."
else
    ./config.sh ${CONFIG_ARGS} || exit 1
fi

cleanup() {
  echo "Removing runner..."
  ./config.sh remove --unattended --token ${REG_TOKEN}
}

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

./run.sh & wait $!
RC=$?

# run.sh retries transient failures itself, so a non-zero exit here is terminal.
# The usual cause is the server-side registration having been deleted — most
# often by another container registering under the same NAME — which leaves
# .runner permanently unusable. Discard it so the next start registers afresh
# rather than replaying the identical failure forever.
if [ "${RC}" -ne 0 ]; then
    echo "Runner exited with status ${RC}; discarding local configuration so the next start re-registers."
    rm -f .runner .credentials .credentials_rsaparams
fi

exit "${RC}"
