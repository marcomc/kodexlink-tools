# KodexLink Relay Tools

Local tooling for running a private KodexLink mobile relay on macOS or Linux
with Docker Compose or a native host service, Tailscale Serve, and the upstream
KodexLink desktop agent.

## Table of Contents

- [What It Does](#what-it-does)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Platform Install Guides](#platform-install-guides)
- [Runtime Selection](#runtime-selection)
- [Daily Commands](#daily-commands)
- [Pairing](#pairing)
- [Updates](#updates)
- [Boot Behavior](#boot-behavior)
- [Security Model](#security-model)
- [Resource Use](#resource-use)
- [Documentation](#documentation)
- [Project Files](#project-files)
- [License](#license)
- [References](#references)

## What It Does

This project gives one command surface for a private KodexLink relay setup:

- clones or updates the upstream relay source;
- builds and runs the relay, PostgreSQL, and Redis with Docker Compose by
  default;
- can alternatively run the relay as a native host service against existing
  PostgreSQL and Redis connection URLs;
- keeps the relay bound to `127.0.0.1` on the host;
- publishes the relay privately over HTTPS with Tailscale Serve;
- installs the KodexLink desktop agent as the upstream host service;
- opens the local QR pairing panel when a phone or iPad needs pairing;
- checks health, resources, diagnostics, and repository privacy.

The generated runtime environment lives outside this repository:

```text
~/.config/kodexlink-tools/relay.env
```

In that file, `KODEXLINK_RELAY_PUBLIC_BASE_URL` is the mobile-facing URL, while
`KODEXLINK_RELAY_HOST_PORT` is only the local Docker port. With Tailscale Serve,
the public URL should normally be `https://machine-name.tailnet-name.ts.net`
without `:8787`; Tailscale proxies HTTPS port `443` to the local Docker port.

Do not commit real tailnet names, Tailscale IPs, tokens, local user paths,
hostnames, generated pairing payloads, or generated env files.

## Architecture

```text
iPhone / iPad
  -> Tailscale HTTPS URL
  -> Tailscale Serve on the host
  -> http://127.0.0.1:8787
  -> Docker or native relay
  -> PostgreSQL + Redis

KodexLink desktop agent
  -> same relay URL
  -> local Codex CLI / codex app-server
```

The relay itself is plain HTTP and does not load TLS certificates. Tailscale
Serve terminates HTTPS for the `*.ts.net` address and proxies to the local
relay port. That keeps the raw relay private to the host while giving iOS and
iPadOS a trusted HTTPS endpoint.

`RELAY_PUBLIC_BASE_URL` is critical. The relay embeds it into pairing payloads,
and the mobile app stores it when pairing succeeds. Set the final Tailscale
HTTPS URL before pairing.

## Quick Start

Enable MagicDNS and HTTPS certificates in the Tailscale admin console first,
then run:

```bash
make check-deps
make install PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable
make doctor
make pair
```

On iPhone or iPad, before scanning the QR code:

1. Connect Tailscale.
2. Open KodexLink Settings.
3. Open Relay Server.
4. Select Custom Address.
5. Enter the same Tailscale HTTPS URL.
6. Tap Save Custom Address.
7. Return to the pairing scanner and scan the Mac QR code.

`make install` prepares the machine but does not start runtime services.
`make enable` starts the selected relay runtime, configures Tailscale Serve, and
installs the desktop service.

## Platform Install Guides

Replace `https://machine-name.tailnet-name.ts.net` with the host machine's
Tailscale HTTPS name.

### macOS With Docker

Prerequisites:

- macOS with Docker Desktop installed.
- Docker Desktop configured to start at login if the relay should recover after
  reboot.
- Tailscale installed, logged in, and MagicDNS plus HTTPS certificates enabled
  in the Tailscale admin console.
- Node.js/npm available for the upstream `kodexlink` CLI.
- `git`, `make`, `curl`, `markdownlint`, and `shellcheck` available if the
  user will run repository checks.

Install and enable:

```bash
git clone https://github.com/<owner>/kodexlink-tools.git
cd kodexlink-tools

make check-deps
make install PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable
make doctor
make pair
```

Expected behavior:

- Docker Compose runs PostgreSQL, Redis, and the relay.
- The relay listens only on `127.0.0.1:8787`.
- Tailscale Serve maps
  `https://machine-name.tailnet-name.ts.net` to `http://127.0.0.1:8787`.
- Docker restarts the relay containers after Docker Desktop restarts, provided
  they were not stopped with `make disable`, `make stop`, or
  `docker compose down`.

Useful checks:

```bash
make status
make health
tailscale serve status
curl -fsS http://127.0.0.1:8787/healthz
```

### Ubuntu With Docker

Prerequisites:

- Ubuntu with Docker Engine and the Docker Compose plugin installed.
- The user can run Docker commands, or is prepared to use the local Docker
  permission model already configured on that host.
- Tailscale installed and logged in.
- MagicDNS and HTTPS certificates enabled in the Tailscale admin console.
- Node.js/npm available for the upstream `kodexlink` CLI.
- `git`, `make`, and `curl` installed.

Example prerequisite install commands:

```bash
sudo apt-get update
sudo apt-get install -y git make curl nodejs npm
```

Install Docker and Tailscale using their official Ubuntu instructions, then
verify:

```bash
docker info
docker compose version
tailscale status
```

Install and enable:

```bash
git clone https://github.com/<owner>/kodexlink-tools.git
cd kodexlink-tools

make check-deps
make install PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable
make doctor
make pair
```

Expected behavior:

- Docker Compose runs PostgreSQL, Redis, and the relay with
  `restart: unless-stopped`.
- The relay binds to `127.0.0.1:8787` on the Ubuntu host.
- Tailscale Serve publishes the relay over the machine's private HTTPS
  `*.ts.net` URL.
- After reboot, the relay comes back when the Docker service starts again,
  provided the containers were not explicitly stopped.

Useful checks:

```bash
make status
make health
tailscale serve status
curl -fsS http://127.0.0.1:8787/healthz
```

### macOS Native With External Services

Use this when PostgreSQL and Redis are already managed outside this installer,
for example by Homebrew, another local service manager, or remote services.
This mode does not install or configure PostgreSQL or Redis.

Prerequisites:

- macOS with Tailscale installed and logged in.
- MagicDNS and HTTPS certificates enabled in the Tailscale admin console.
- Node.js/npm and `pnpm` available.
- PostgreSQL and Redis reachable from the Mac.
- `DATABASE_URL` and `REDIS_URL` values for those existing services.

Install and enable:

```bash
git clone https://github.com/<owner>/kodexlink-tools.git
cd kodexlink-tools

make install RELAY_RUNTIME=native \
  DATABASE_URL=postgres://user:password@127.0.0.1:5432/codex_mobile \
  REDIS_URL=redis://127.0.0.1:6379 \
  PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable RELAY_RUNTIME=native
make doctor RELAY_RUNTIME=native
make pair
```

Expected behavior:

- launchd supervises the native relay with
  `~/Library/LaunchAgents/com.kodexlink.relay.plist`.
- The relay connects to the supplied PostgreSQL and Redis URLs.
- Tailscale Serve publishes `http://127.0.0.1:8787` as the private HTTPS
  `*.ts.net` URL.

### macOS Native With Managed Local Services

Use this only when this helper should install and start local PostgreSQL and
Redis through Homebrew.

Prerequisites:

- macOS with Homebrew installed.
- Tailscale installed and logged in.
- MagicDNS and HTTPS certificates enabled in the Tailscale admin console.
- Node.js/npm available for the upstream `kodexlink` CLI.

Install and enable:

```bash
git clone https://github.com/<owner>/kodexlink-tools.git
cd kodexlink-tools

make install RELAY_RUNTIME=native NATIVE_DEPS=managed \
  PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable RELAY_RUNTIME=native NATIVE_DEPS=managed
make doctor RELAY_RUNTIME=native NATIVE_DEPS=managed
make pair
```

Expected behavior:

- Homebrew installs and starts PostgreSQL and Redis if they are missing.
- launchd supervises the native relay.
- The relay binds to `127.0.0.1:8787` and uses local PostgreSQL and Redis.

### Ubuntu Native With External Services

Use this when PostgreSQL and Redis are already managed outside this installer,
for example by system packages, another host, or managed database services.
This mode does not install or configure PostgreSQL or Redis.

Prerequisites:

- Ubuntu with Tailscale installed and logged in.
- MagicDNS and HTTPS certificates enabled in the Tailscale admin console.
- Node.js/npm and `pnpm` available.
- PostgreSQL and Redis reachable from the Ubuntu host.
- `DATABASE_URL` and `REDIS_URL` values for those existing services.

Install and enable:

```bash
git clone https://github.com/<owner>/kodexlink-tools.git
cd kodexlink-tools

make install RELAY_RUNTIME=native \
  DATABASE_URL=postgres://user:password@127.0.0.1:5432/codex_mobile \
  REDIS_URL=redis://127.0.0.1:6379 \
  PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable RELAY_RUNTIME=native
make doctor RELAY_RUNTIME=native
make pair
```

Expected behavior:

- systemd supervises the user service at
  `~/.config/systemd/user/kodexlink-relay.service`.
- The relay connects to the supplied PostgreSQL and Redis URLs.
- The installer attempts to enable user lingering with `loginctl` so the relay
  can survive logout.

### Ubuntu Native With Managed Local Services

Use this only when this helper should install and start local PostgreSQL and
Redis through `apt-get`.

Prerequisites:

- Ubuntu with Tailscale installed and logged in.
- MagicDNS and HTTPS certificates enabled in the Tailscale admin console.
- Node.js/npm and `pnpm` available.
- `sudo` access for installing packages and enabling services.

Install and enable:

```bash
git clone https://github.com/<owner>/kodexlink-tools.git
cd kodexlink-tools

make install RELAY_RUNTIME=native NATIVE_DEPS=managed \
  PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable RELAY_RUNTIME=native NATIVE_DEPS=managed
make doctor RELAY_RUNTIME=native NATIVE_DEPS=managed
make pair
```

Expected behavior:

- `apt-get` installs PostgreSQL and Redis if they are missing.
- systemd starts PostgreSQL, Redis, and the user-level relay service.
- The relay binds to `127.0.0.1:8787` and uses local PostgreSQL and Redis.

## Runtime Selection

Docker remains the default runtime:

```bash
make install PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable
```

Use the native runtime explicitly when Docker is not wanted:

```bash
make install RELAY_RUNTIME=native \
  DATABASE_URL=postgres://user:password@127.0.0.1:5432/codex_mobile \
  REDIS_URL=redis://127.0.0.1:6379 \
  PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable RELAY_RUNTIME=native
```

The native runtime defaults to `NATIVE_DEPS=external`, so it does not install
or configure PostgreSQL or Redis. Provide existing `DATABASE_URL` and
`REDIS_URL` values, or store them in `~/.config/kodexlink-tools/relay.env`.

Use `NATIVE_DEPS=managed` only when the installer should manage local
PostgreSQL and Redis:

```bash
make install RELAY_RUNTIME=native NATIVE_DEPS=managed \
  PUBLIC_URL=https://machine-name.tailnet-name.ts.net
```

The native runtime detects macOS or Linux. It installs a LaunchAgent on macOS
or a systemd user service on Linux, then runs the upstream relay migration and
`node runtime-apps/relay-server/dist/server.js serve`. The relay still binds to
`127.0.0.1:8787`; Tailscale Serve remains the HTTPS layer.

## Daily Commands

```bash
make help              # show available targets
make status            # relay runtime and desktop agent status
make health            # local relay health
make doctor            # relay, Tailscale, mobile URL, privacy checks
make measure           # one-shot relay CPU and memory stats
make logs SERVICE=relay
make restart           # restart selected relay runtime
make disable           # stop services without deleting data
make enable            # start services again
```

Pass `RELAY_RUNTIME=native` to these commands to manage the native relay
service instead of the Docker Compose stack.

The lower-level script remains available for direct operations:

```bash
./scripts/kodexlink-relay.sh help
```

Prefer Makefile targets for normal use.

Keep the `kodexlink-tools` clone after installation. Runtime data lives outside
the clone, so already-created containers, Docker volumes, Tailscale Serve, and
the desktop LaunchAgent can continue to exist if the clone is deleted. However,
the clone contains the supported Makefile, Compose file, Dockerfile, scripts,
and docs needed for updates, diagnostics, rebuilds, and service management.

## Pairing

Open a fresh pairing panel with:

```bash
make pair
```

The QR code is rendered by the desktop agent, not by the relay. The phone does
not need to reach the local pairing panel URL; it only uses the relay URL and
short-lived enrollment secret inside the QR payload.

Pairing payloads expire after roughly five minutes and are consumed after a
successful claim. Do not store QR images, `pairingId`, `pairingSecret`, or full
manual pairing payloads as recovery credentials. It is useful to store only:

- the private relay HTTPS URL;
- the command `make pair`;
- the reminder to connect Tailscale first;
- the reminder to set the mobile app Custom Address before scanning.

## Updates

When the upstream relay or desktop CLI changes:

```bash
make update
```

This updates the managed upstream checkout, updates the KodexLink desktop CLI
from npm, rebuilds and restarts the selected relay runtime, and refreshes the
desktop service. It does not recreate `relay.env` or change the relay public
URL, so already paired devices should remain paired. Any QR pairing session
open during the restart can expire; run `make pair` again.

## Boot Behavior

With Docker, this project does not install a separate LaunchAgent to supervise
Compose. Docker owns relay container restart behavior through
`restart: unless-stopped`.

The relay comes back after reboot when:

- it was enabled and running before Docker stopped;
- Docker Desktop starts again after reboot or login.

If Docker Desktop is quit while the relay containers are running, Docker should
restart them the next time Docker Desktop starts. If the relay is intentionally
stopped with `make disable`, `make stop`, or `docker compose down`, Docker will
not restart it automatically until `make enable` or `make start` runs again.

If Docker Desktop is not configured to start at login:

```bash
make docker-start
make start
```

Tailscale Serve persists in Tailscale background mode. The desktop agent
persists through the upstream KodexLink macOS LaunchAgent.

With `RELAY_RUNTIME=native`, the relay is supervised by launchd on macOS or a
systemd user service on Linux. On Linux the installer also attempts to enable
user lingering so the relay can start before an interactive login.

## Security Model

Recommended private path:

```text
Tailscale Serve HTTPS -> localhost relay HTTP
```

Tailscale Funnel is available but public. Use it only when public exposure is
acceptable:

```bash
make tailscale-funnel
make tailscale-funnel-off
```

The relay has bearer tokens and short-lived pairing secrets, but no global admin
password. Treat public exposure as an internet-facing API. Keep
`RELAY_ENABLE_DEV_RESET` disabled outside local development.

Run the desktop agent on the host, not in Docker. It launches
`codex app-server`, uses the host user's Codex login, stores credentials in the
host credential store when available, and installs the upstream host service.

## Resource Use

Idle measurements on this Mac reported roughly:

- `relay`: 31-36 MiB memory;
- `postgres`: 25-28 MiB memory;
- `redis`: 4 MiB memory.

Expect short CPU spikes during image builds and migrations, then low idle CPU.
Actual memory can grow with active WebSocket sessions, thread traffic, and
PostgreSQL cache.

## Documentation

- [docs/tailscale-private-relay.md](docs/tailscale-private-relay.md): Tailscale
  admin setup, HTTPS, Serve, optional exit nodes, and mobile setup.
- [docs/service-and-makefile.md](docs/service-and-makefile.md): Makefile
  workflow, boot behavior, pairing, updates, diagnostics, and recovery notes.
- [docs/cloudflare-zero-trust-research.md](docs/cloudflare-zero-trust-research.md):
  research notes for a future Cloudflare Zero Trust publishing mode.
- [CHANGELOG.md](CHANGELOG.md): release history.

## Project Files

- `Makefile`: primary command entrypoint.
- `docker-compose.kodexlink-relay.yml`: Docker relay, PostgreSQL, and Redis
  stack.
- `docker/relay-server.Dockerfile`: relay image build from upstream source.
- `scripts/kodexlink-relay.sh`: lifecycle, publishing, and measurement helper.
- `scripts/tailscale-cli-launcher`: `/usr/local/bin/tailscale` wrapper.
- `.env.example`: non-secret configuration template.
- `LICENSE.md`: license, upstream notice, and Tailscale disclaimer.

## License

This tooling is distributed under `AGPL-3.0-only` and references the upstream
KodexLink / Codex Mobile Relay project by David699. See [LICENSE.md](LICENSE.md)
for the upstream notice and Tailscale disclaimer.

## References

- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Tailscale Funnel](https://tailscale.com/kb/1223/funnel)
- [Tailscale CLI](https://tailscale.com/docs/reference/tailscale-cli)
- [Tailscale HTTPS certificates](https://tailscale.com/kb/1153/enabling-https)
- [Tailscale MagicDNS](https://tailscale.com/docs/features/magicdns)
