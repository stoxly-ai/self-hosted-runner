# Self-Hosted GitHub Actions Runner

Dockerized GitHub Actions self-hosted runners for Linux (x64) and macOS (ARM64). Deploy in minutes, scale with replicas, deregister cleanly on shutdown.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/stoxly-ai/self-hosted-runner?style=social)](https://github.com/stoxly-ai/self-hosted-runner/stargazers)

---

## Quick Start

```sh
git clone https://github.com/stoxly-ai/self-hosted-runner.git
cd self-hosted-runner
cp .env.example .env        # fill in REPO and REG_TOKEN
```

**Linux (x64)**
```sh
docker compose -f docker/linux/docker-compose.yml up -d
```

**macOS / ARM64**
```sh
docker compose -f docker/mac/docker-compose.yml up -d
```

Those use the host's Docker daemon via a socket mount. If your jobs need a
Docker daemon of their own, use the Docker-in-Docker compose files instead —
see [Docker Access Modes](#docker-access-modes).

> **REG_TOKEN expires after 1 hour.** Generate a fresh one from
> GitHub → Settings → Actions → Runners → "New self-hosted runner" before each deploy.

---

## Pre-built Image vs Local Build

Both variants support pre-built images from GHCR. By default, `docker-compose up` pulls the pre-built image — no build step required.

| Variant | Image | Tag |
|---------|-------|-----|
| **Linux (x64)** | `ghcr.io/stoxly-ai/self-hosted-runner` | `latest` |
| **macOS / ARM64** | `ghcr.io/stoxly-ai/self-hosted-runner` | `latest-arm64` |

| Mode | How | When to use |
|------|-----|-------------|
| **Pre-built** (default) | Just run `docker-compose up` | Quick setup, no customization needed |
| **Local build** | Uncomment `build: .` in the compose file | Custom Dockerfile changes, runner version overrides |

---

## Features

- **Zero-config start** — set 2 env vars and run
- **Clean shutdown** — SIGINT/SIGTERM deregisters the runner automatically
- **Two Docker modes** — host socket mount, or an isolated Docker-in-Docker sidecar
- **Ephemeral mode** — run once and self-destruct (`EPHEMERAL=true`)
- **GitHub CLI** — `gh` pre-installed from official repos on both variants
- **Docker CLI** — official Docker CE CLI with buildx and compose plugins on both variants
- **Healthchecks** — built-in `pgrep run.sh` health monitoring on both variants

---

## Architecture

```
docker/
├── linux/          Ubuntu 24.04, x64
│   ├── Dockerfile               user: docker, workdir: /home/docker/actions-runner
│   ├── docker-compose.yml       host socket mount (DooD)
│   ├── docker-compose.dind.yml  isolated dockerd sidecar (DinD)
│   ├── dind-daemon.json         per-stack daemon config (GC budget, pools)
│   └── start.sh
└── mac/            Ubuntu 24.04, ARM64
    ├── Dockerfile               user: runner, workdir: /home/runner/actions-runner
    ├── docker-compose.yml       host socket mount (DooD)
    ├── docker-compose.dind.yml  isolated dockerd sidecar (DinD)
    ├── dind-daemon.json         per-stack daemon config (GC budget, pools)
    └── start.sh
scripts/
└── runner-pool.sh  deploy/scale/upgrade/clean N DinD slots (see Runner pool)
```

The pinned runner version lives in `ARG RUNNER_VERSION` in both Dockerfiles and
is bumped automatically by `.github/workflows/update-runner-version.yml`.

Both `start.sh` scripts run in two stages:

1. **as root** — align the mounted Docker socket's group, prepare `WORK_DIR`,
   then `exec setpriv` to drop to the unprivileged runner user
2. **as the runner user** — wait for the daemon (DinD only) → `config.sh` →
   trap SIGINT/SIGTERM for deregistration → `run.sh`

---

## Docker Access Modes

Jobs that run `docker build` / `docker run` need a daemon. Pick one:

| | **Socket mount (DooD)** | **Docker-in-Docker (DinD)** |
|---|---|---|
| File | `docker-compose.yml` | `docker-compose.dind.yml` |
| Daemon | the host's | a private one in a `dind` sidecar |
| Isolation | none — a job can start a privileged container on the host, i.e. it is effectively host root | jobs cannot reach the host daemon |
| Image cache | shared with the host, always warm | lives in the `dind-storage` volume |
| Requires `privileged` | no | yes, on the `dind` sidecar |
| Speed | faster | slower cold start |

Use **DooD** on a machine you already trust with your workflows. Use **DinD**
when jobs are untrusted, when they must not see host images or containers, or
when the host has no daemon to share.

### Running in DinD mode

```sh
cp .env.example .env        # fill in REPO and REG_TOKEN

# Linux (x64)
docker compose -f docker/linux/docker-compose.dind.yml up -d

# macOS / ARM64
docker compose -f docker/mac/docker-compose.dind.yml up -d
```

#### Runner pool: one stack per concurrent job

One stack = one runner = one job at a time = one private daemon. To run N jobs
concurrently, deploy N stacks from the same checkout and `.env`. The
`scripts/runner-pool.sh` helper manages the whole pool:

```sh
./scripts/runner-pool.sh up 3      # ensure slots 1..3 run; removes any above 3
./scripts/runner-pool.sh status    # per-slot containers + busy/idle
./scripts/runner-pool.sh up 5      # scale up (new slots need a REG_TOKEN <1h old)
./scripts/runner-pool.sh up 2      # scale down — busy slots are skipped, not killed
./scripts/runner-pool.sh upgrade   # pull newer images, recreate idle slots
./scripts/runner-pool.sh down      # stop + deregister everything, keep warm caches
./scripts/runner-pool.sh clean     # down + delete volumes (asks for confirmation)
```

It auto-picks the variant for the OS (`--variant linux|mac` to override) and
refuses to touch a slot that is mid-job unless you pass `--force`. Under the
hood each slot is just a compose project — the manual equivalent is:

```sh
docker compose -p runner-1 -f docker/linux/docker-compose.dind.yml up -d
docker compose -p runner-2 -f docker/linux/docker-compose.dind.yml up -d
```

Every job then executes against the private daemon of the runner it landed on,
which is what makes parallel jobs stop interfering with each other — and with
the host:

- **Builds don't block across jobs.** BuildKit's build graph, cache, and GC
  lock are per-daemon; two heavy builds proceed independently.
- **Fixed service ports don't collide.** A job's published ports
  (`services:` with `5432:5432`, `docker run -p ...`) bind inside its own
  stack's network namespace — two parallel jobs can both claim 5432, and
  neither touches the host's port space.
- **Prunes stay local.** A job running `docker system prune -af` (or a PaaS
  scheduled cleanup on the host, e.g. Dokploy/Coolify) can no longer delete
  another job's images or stall its builds.
- **The host daemon stays clean.** It never executes CI workloads, so
  anything else it serves (deploy tooling, app containers) behaves as if the
  runners weren't there.

Per-stack knobs live in `docker/<variant>/dind-daemon.json` (build-cache GC
budget, address pools, pull concurrency) and in the `deploy.resources` limits
on the `dind` service (CPU/RAM cap per job's docker workloads).

Verify the runner reached its private daemon:

```sh
docker compose -f docker/linux/docker-compose.dind.yml logs runner | grep -i docker
# Waiting for Docker daemon at tcp://docker:2376...
# Docker daemon ready.
```

Tear down, discarding the private image cache:

```sh
docker compose -f docker/linux/docker-compose.dind.yml down -v
```

**How it is wired.** The `dind` service runs `docker:28-dind` with
`privileged: true` and `DOCKER_TLS_CERTDIR=/certs`, so dockerd generates its own
CA and listens on TLS port 2376. The client certs are shared to the runner
through the `docker-certs-client` volume, and the runner is pointed at it with:

```yaml
environment:
  DOCKER_HOST: tcp://docker:2376
  DOCKER_TLS_VERIFY: "1"
  DOCKER_CERT_PATH: /certs/client
  WORK_DIR: /home/docker/_work     # /home/runner/_work on ARM64
```

**Why the host is `docker` and not `dind`.** dind issues its server certificate
for the hostname `docker`, so dialing `tcp://dind:2376` fails TLS verification
with `certificate is valid for docker, ..., not dind`. The sidecar therefore
carries a `docker` network alias; the service keeps the clearer name `dind`.

`start.sh` sees `DOCKER_HOST` set and skips socket handling entirely, then
blocks until the daemon answers (up to 2 minutes) before registering.

**Why `WORK_DIR` is pinned.** With a separate daemon, bind mounts are resolved
on the **dind** container's filesystem, not the runner's. A job step doing
`docker run -v "$PWD:/src" ...` would otherwise mount an empty directory. The
compose file mounts the shared `runner-work` volume at the *same absolute path*
in both containers and sets `WORK_DIR` to it, so `$GITHUB_WORKSPACE` paths
resolve identically on both sides. Don't override `WORK_DIR` in `.env` for this
mode.

**Caveats.**
- `privileged: true` on the sidecar is unavoidable — dockerd needs to manage
  cgroups, network namespaces and iptables. It is confined to the sidecar; the
  runner container stays unprivileged.
- Ports published by a job (`docker run -p 8080:80`, workflow `services:`)
  bind inside the stack's shared network namespace, not on the host. The
  runner lives in that same namespace (`network_mode: service:dind`), so job
  steps reach them at `localhost:8080` — exactly what
  `localhost:${{ job.services.<name>.ports[...] }}` in workflows expects.
  They are not reachable from outside the stack.
- If your host filesystem cannot back overlay2 (e.g. ZFS), uncomment
  `DOCKER_DRIVER: vfs` in the `dind` service.

---

## Configuration

Copy `.env.example` to `.env` and set your values. The `.env` file is gitignored.

### Required

| Variable | Description |
|----------|-------------|
| `REPO` | `owner/repo` for repo-level or `owner` for org-level runners |
| `REG_TOKEN` | Registration token from GitHub Settings (expires in 1 hour) |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `NAME` | _(container hostname)_ | Display name in the GitHub UI. Leave unset for `replicas > 1` — see [Scaling](#scaling). |
| `LABELS` | _(none)_ | Comma-separated labels, e.g. `self-hosted,linux,x64,gpu` |
| `RUNNER_GROUP` | _(default)_ | Runner group name — org/enterprise only |
| `WORK_DIR` | `_work` | Workspace directory inside the container. Set by the DinD compose files — don't override it there. |
| `EPHEMERAL` | `false` | `true` → deregister after one job |
| `DISABLE_AUTO_UPDATE` | `false` | `true` → prevent runner self-updates |

### Override Runner Version

```sh
docker build --build-arg RUNNER_VERSION=2.332.0 -t custom-github-runner:latest ./docker/linux
```

---

## Registering to an Organization

Set `REPO` to just the org name:

```env
REPO=my-org
```

The runner will register at org level and be available to all repositories in that org.

---

## Workflows Example

Reference your runner in any workflow file:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted runner"
```

Use your custom labels to target specific runners:

```yaml
runs-on: [self-hosted, linux, gpu]
```

---

## Scaling

Leave `NAME` unset and raise `deploy.replicas`. Each runner then registers under
its container hostname, which Docker makes unique per container, so replicas
never collide:

```yaml
deploy:
  replicas: 4       # 4 concurrent runners, each self-named
```

Set `NAME` only when running a **single** runner and you want a specific label
in the GitHub UI — a fixed `NAME` pins every replica to the same identity, and
they will displace one another.

The DinD compose files are the exception: keep them at one replica. `WORK_DIR`
there is a volume shared with the dind sidecar at a fixed path, so a second
replica would run jobs out of the same `_work` tree. Add capacity with another
stack instead — this is the recommended pattern, since every stack brings its
own daemon and jobs stop contending entirely (see
[Runner pool](#runner-pool-one-stack-per-concurrent-job)):

```sh
docker compose -p runner-2 -f docker/linux/docker-compose.dind.yml up -d
```

GitHub distributes jobs across all registered runners automatically. Tune each
runner's footprint under `deploy.resources`:

```yaml
deploy:
  resources:
    limits:
      cpus: '0.5'
      memory: 512M
```

---

## Publishing Images

GitHub Actions workflows automatically build and publish both images to GHCR on
version tag pushes (`v*`). The tag name becomes the image tag verbatim, so it
must be a valid Docker tag — `+` is not allowed.

### Tag scheme

| Tag | Cut by | Means |
|-----|--------|-------|
| `v2.337.0` | `update-runner-version.yml`, automatically | `actions/runner` was bumped to 2.337.0 |
| `v2.337.0-1`, `-2`, … | a human | image-only change on top of runner 2.337.0 |

Bare `v<runner_version>` tags mirror the upstream runner release. When the image
changes but the runner version doesn't — a Dockerfile or `start.sh` fix —
append an incrementing revision instead.

```sh
git tag -a v2.337.0-1 -m "…"
git push origin v2.337.0-1
```

**Never re-point a tag that has already been pushed.** Republishing the same
name leaves every host that already pulled it running stale code: `docker
compose up -d` does not re-check the registry for an image tag it already has
locally. A fresh tag has no local cache anywhere, so it is always pulled.

| Image | Tag | Platform |
|-------|-----|----------|
| `ghcr.io/<owner>/self-hosted-runner` | `latest` / `v2.337.0-1` | linux/amd64 |
| `ghcr.io/<owner>/self-hosted-runner` | `latest-arm64` / `v2.337.0-1-arm64` | linux/arm64 |

### Upgrading a running runner

`latest` is a moving target, so `up -d` alone won't pick up a new build:

```sh
docker compose -f docker/linux/docker-compose.yml pull
docker compose -f docker/linux/docker-compose.yml up -d --force-recreate
```

Pinning the revision tag instead of `latest` avoids the ambiguity entirely.

---

## Troubleshooting

**`permission denied while trying to connect to the Docker API at unix:///var/run/docker.sock`**

The runner user isn't in a group that owns the mounted socket. `start.sh`
handles this automatically: as root it reads the socket's GID, creates or reuses
a matching group, adds the runner user to it, and only then drops privileges
with `setpriv --init-groups`. The re-exec is the load-bearing part — `usermod`
cannot change the credentials of an already-running process, so a group added
after startup has no effect until a fresh `exec`.

If you still hit it:

```sh
# 1. Confirm the socket is actually mounted and note its GID
docker compose -f docker/linux/docker-compose.yml exec runner stat -c '%g %n' /var/run/docker.sock

# 2. Confirm the runner user picked up that GID
docker compose -f docker/linux/docker-compose.yml exec -u docker runner id
```

The GID from step 1 must appear in step 2's group list. If it doesn't, you're
probably on a stale image — rebuild or `docker compose pull`. Note the container
now starts as root by design; `docker compose exec` without `-u docker` gives
you a root shell and won't reproduce the runner's own permissions.

On Docker Desktop and OrbStack the socket is root-owned, so the startup log
reads `added docker to group root` rather than naming a `docker`/`dockerhost`
group — that is expected, not a misconfiguration.

On SELinux hosts the socket mount also needs a relabel:
`- /var/run/docker.sock:/var/run/docker.sock:z`.

If you'd rather not share the host daemon at all, switch to
[DinD mode](#running-in-dind-mode) — it sidesteps socket permissions entirely.

**`Cannot connect to the Docker daemon at tcp://docker:2376`**
- The sidecar may still be starting. `depends_on: service_healthy` plus the
  wait loop in `start.sh` covers up to ~2 minutes; check `docker compose -f docker/linux/docker-compose.dind.yml logs dind`.
- Certs out of sync after recreating only one service — `down -v` then `up -d`
  regenerates them.

**`tls: failed to verify certificate: x509: certificate is valid for docker, ..., not dind`**

`DOCKER_HOST` must use the `docker` alias, not the service name — dind's
self-signed cert is only issued for `docker`. Don't override `DOCKER_HOST` in
`.env`; the compose file already sets it correctly.

**Runner doesn't appear in GitHub Settings**
- Check `REG_TOKEN` — it expires after 1 hour. Generate a new one.
- Verify `REPO` format: `owner/repo` (no leading slash, no trailing slash).

**Logs**
```sh
docker compose -f docker/linux/docker-compose.yml logs -f
```

**Health status**
```sh
docker compose -f docker/linux/docker-compose.yml ps
```

**Runner stuck / won't deregister**
```sh
docker compose -f docker/linux/docker-compose.yml down
```
`down` sends SIGTERM → `start.sh` cleanup → runner deregisters cleanly.

---

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability reporting policy.

Key practices in this project:
- Runners execute as non-root users (`docker` on Linux, `runner` on ARM64). The
  entrypoint starts as root only to align the Docker socket group and prepare
  the work dir, then drops privileges with `setpriv` before `config.sh` runs.
- Secrets live in `.env` (gitignored) — never hardcoded in compose files
- `REG_TOKEN` is used only at registration time; not stored after config

⚠️ **Mounting `/var/run/docker.sock` (the default `docker-compose.yml`) grants
workflows root-equivalent control of the host.** Any job that can run
`docker run --privileged -v /:/host ...` owns the machine. Only use it for
workflows you fully trust — for anything else, run
[DinD mode](#running-in-dind-mode), which keeps the host daemon out of reach.

---

## Contributing

Contributions welcome. Please:

1. Fork the repo and create a branch from `main`
2. Keep changes scoped — one feature or fix per PR
3. Test your change by actually spinning up the container
4. Open a pull request with a clear description of what and why

For bugs or feature requests, [open an issue](https://github.com/stoxly-ai/self-hosted-runner/issues).

---

## License

[MIT](LICENSE) — use freely, attribution appreciated.
