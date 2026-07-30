#!/usr/bin/env bash
#
# runner-pool.sh — manage a pool of DinD runner stacks (one stack = one
# concurrent job slot with its own private Docker daemon).
#
#   ./scripts/runner-pool.sh up 3        ensure slots 1..3 run, remove any above
#   ./scripts/runner-pool.sh status      show each slot's containers + busy/idle
#   ./scripts/runner-pool.sh upgrade     pull newer images, recreate idle slots
#   ./scripts/runner-pool.sh down        stop + deregister all slots, keep caches
#   ./scripts/runner-pool.sh clean       down + DELETE volumes (caches go cold)
#
# Slots are compose projects named <prefix>-<n>, all sharing this checkout and
# its .env. Scale-down, upgrade and down skip slots that are mid-job unless
# --force is given. Options: --variant linux|mac, --prefix NAME, --force, --yes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

PREFIX="${RUNNER_POOL_PREFIX:-runner}"
case "$(uname -s)" in
    Darwin) VARIANT="${RUNNER_POOL_VARIANT:-mac}" ;;
    *)      VARIANT="${RUNNER_POOL_VARIANT:-linux}" ;;
esac
FORCE=0
ASSUME_YES=0

usage() {
    sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() { echo "ERROR: $*" >&2; exit 1; }

compose_p() {
    local slot="$1"; shift
    docker compose -p "${slot}" -f "${COMPOSE_FILE}" "$@"
}

# Slots are discovered from container labels, so the pool survives this script
# knowing nothing between invocations. Stopped containers count; slots taken
# fully `down` disappear (their volumes may still exist until `clean`).
list_slots() {
    docker ps -a --format '{{.Label "com.docker.compose.project"}}' \
        | grep -E "^${PREFIX}-[0-9]+$" | sort -t- -k2 -n -u || true
}

# The runner spawns Runner.Worker only while a job is executing.
is_busy() {
    compose_p "$1" exec -T runner pgrep -f 'Runner.Worker' >/dev/null 2>&1
}

check_env() {
    [ -f "${ENV_FILE}" ] \
        || die ".env not found — run: cp .env.example .env  (then set REPO and REG_TOKEN)"
    grep -Eq '^REPO=[^<[:space:]]+' "${ENV_FILE}" \
        || die "REPO is unset or a placeholder in .env"
    grep -Eq '^REG_TOKEN=.+' "${ENV_FILE}" && ! grep -q '^REG_TOKEN=your_registration_token_here' "${ENV_FILE}" \
        || die "REG_TOKEN is unset or a placeholder in .env"
}

remove_slot() {
    local slot="$1" wipe="${2:-}"
    if is_busy "${slot}" && [ "${FORCE}" -ne 1 ]; then
        echo ">> ${slot}: BUSY (job running) — skipped. Re-run with --force to kill it."
        return 0
    fi
    echo ">> ${slot}: down${wipe:+ + removing volumes}"
    # `down` SIGTERMs the runner, whose trap deregisters it from GitHub.
    compose_p "${slot}" down ${wipe}
}

cmd_up() {
    local n="$1" existing slot num is_new
    [[ "${n}" =~ ^[0-9]+$ ]] || die "up needs a replica count, e.g.: $0 up 3"
    check_env
    existing="$(list_slots)"
    for i in $(seq 1 "${n}"); do
        slot="${PREFIX}-${i}"
        is_new=1
        echo "${existing}" | grep -qx "${slot}" && is_new=0
        if [ "${is_new}" -eq 1 ]; then
            echo ">> ${slot}: creating (registers with GitHub — needs a REG_TOKEN <1h old)"
        else
            echo ">> ${slot}: reconciling"
        fi
        # `up -d` is idempotent and also applies compose/dind-daemon.json edits.
        compose_p "${slot}" up -d
    done
    for slot in ${existing}; do
        num="${slot##*-}"
        [ "${num}" -gt "${n}" ] && remove_slot "${slot}"
    done
    echo "Pool at ${n} slot(s). Verify on GitHub: Settings → Actions → Runners."
}

cmd_status() {
    local slots slot
    slots="$(list_slots)"
    [ -n "${slots}" ] || { echo "No ${PREFIX}-N slots found."; return 0; }
    for slot in ${slots}; do
        if is_busy "${slot}"; then echo "== ${slot} [BUSY: job running]";
        else echo "== ${slot} [idle]"; fi
        compose_p "${slot}" ps --format 'table {{.Service}}\t{{.Status}}' | sed 's/^/   /'
    done
}

cmd_upgrade() {
    local slots slot
    slots="$(list_slots)"
    [ -n "${slots}" ] || die "no slots to upgrade — deploy first: $0 up N"
    check_env
    for slot in ${slots}; do
        if is_busy "${slot}" && [ "${FORCE}" -ne 1 ]; then
            echo ">> ${slot}: BUSY — skipped (re-run later or use --force)"
            continue
        fi
        echo ">> ${slot}: pull + recreate"
        compose_p "${slot}" pull --quiet
        compose_p "${slot}" up -d --force-recreate
    done
}

cmd_down() {
    local slot
    for slot in $(list_slots); do remove_slot "${slot}"; done
}

cmd_clean() {
    local slots slot answer
    slots="$(list_slots)"
    [ -n "${slots}" ] || { echo "Nothing to clean."; return 0; }
    if [ "${ASSUME_YES}" -ne 1 ]; then
        echo "This removes ALL slot volumes — image caches, work dirs, TLS certs."
        echo "Slots: $(echo "${slots}" | tr '\n' ' ')"
        printf 'Type "yes" to continue: '
        read -r answer
        [ "${answer}" = "yes" ] || die "aborted"
    fi
    for slot in ${slots}; do remove_slot "${slot}" "-v"; done
}

CMD="${1:-}"
[ -n "${CMD}" ] || { usage; exit 1; }
shift
N=""
while [ $# -gt 0 ]; do
    case "$1" in
        --force)   FORCE=1 ;;
        --yes|-y)  ASSUME_YES=1 ;;
        --variant) VARIANT="$2"; shift ;;
        --prefix)  PREFIX="$2"; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         N="$1" ;;
    esac
    shift
done

COMPOSE_FILE="${REPO_ROOT}/docker/${VARIANT}/docker-compose.dind.yml"
ENV_FILE="${REPO_ROOT}/.env"
[ -f "${COMPOSE_FILE}" ] || die "unknown variant '${VARIANT}' (no ${COMPOSE_FILE})"

case "${CMD}" in
    up|scale) cmd_up "${N}" ;;
    status)   cmd_status ;;
    upgrade)  cmd_upgrade ;;
    down)     cmd_down ;;
    clean)    cmd_clean ;;
    -h|--help|help) usage ;;
    *) usage; die "unknown command '${CMD}'" ;;
esac
