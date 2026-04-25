# KodexLink Relay Tools

Local tooling for running a private KodexLink mobile relay on macOS with Docker
Compose, Tailscale Serve, and the upstream KodexLink desktop agent.

## Table of Contents

- [What It Does](#what-it-does)
- [Architecture](#architecture)
- [Quick Start](#quick-start)
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
- builds and runs the relay, PostgreSQL, and Redis with Docker Compose;
- keeps the relay bound to `127.0.0.1` on the Mac;
- publishes the relay privately over HTTPS with Tailscale Serve;
- installs the KodexLink desktop agent as a macOS LaunchAgent;
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
  -> Tailscale Serve on the Mac
  -> http://127.0.0.1:8787
  -> Docker relay
  -> PostgreSQL + Redis

KodexLink desktop agent
  -> same relay URL
  -> local Codex CLI / codex app-server
```

The relay itself is plain HTTP and does not load TLS certificates. Tailscale
Serve terminates HTTPS for the `*.ts.net` address and proxies to the local
relay port. That keeps Docker private to the Mac while giving iOS and iPadOS a
trusted HTTPS endpoint.

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
`make enable` starts Docker, configures Tailscale Serve, and installs the
desktop LaunchAgent.

## Daily Commands

```bash
make help              # show available targets
make status            # relay containers and desktop agent status
make health            # local relay health
make doctor            # relay, Tailscale, mobile URL, privacy checks
make measure           # one-shot Docker CPU and memory stats
make logs SERVICE=relay
make restart           # rebuild/reapply relay compose config
make disable           # stop services without deleting data
make enable            # start services again
```

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
from npm, rebuilds and restarts the relay container, and refreshes the
LaunchAgent. It does not delete Docker volumes, recreate `relay.env`, or change
the relay public URL, so already paired devices should remain paired. Any QR
pairing session open during the restart can expire; run `make pair` again.

## Boot Behavior

This project does not install a separate LaunchAgent to supervise Docker
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

Run the desktop agent on the Mac host, not in Docker. It launches
`codex app-server`, uses the host user's Codex login, stores credentials in
macOS Keychain when available, and installs a macOS LaunchAgent.

## Resource Use

Idle smoke tests on this Mac reported roughly:

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
- `docker-compose.kodexlink-relay.yml`: relay, PostgreSQL, and Redis stack.
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
