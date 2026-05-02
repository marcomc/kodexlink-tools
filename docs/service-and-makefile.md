# Service And Makefile Operations

This guide covers the local services, Makefile workflow, pairing behavior,
updates, reboot behavior, and recovery notes for KodexLink Relay Tools.

## Table of Contents

- [Service Inventory](#service-inventory)
- [Makefile Workflow](#makefile-workflow)
- [Repository Clone Lifecycle](#repository-clone-lifecycle)
- [Install And Enable](#install-and-enable)
- [Update Without Re-Pairing](#update-without-re-pairing)
- [Pairing And Recovery](#pairing-and-recovery)
- [Remote Pairing](#remote-pairing)
- [Boot Behavior](#boot-behavior)
- [Why Docker Stays Localhost](#why-docker-stays-localhost)
- [Why The Desktop Agent Stays On The Host](#why-the-desktop-agent-stays-on-the-host)
- [Diagnostics](#diagnostics)
- [Privacy Rules](#privacy-rules)

## Service Inventory

The setup has three runtime parts:

- Docker Compose runs the relay, PostgreSQL, and Redis.
- Tailscale Serve publishes the local relay privately over HTTPS to the tailnet.
- The KodexLink desktop agent runs as a macOS LaunchAgent and connects Codex to
  the relay.

The relay stack stores durable mobile bindings in PostgreSQL. Redis stores
short-lived pairing sessions and idempotency state. The desktop agent is
installed through the upstream KodexLink CLI with `service-install`.

## Makefile Workflow

Show available commands:

```bash
make help
```

Common operations:

```bash
make install PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable
make doctor
make pair
make status
make measure
make update
make disable
```

Those `make` commands are the supported operational interface. In particular,
`make enable` already starts Docker, configures Tailscale Serve with the saved
HTTPS port, and refreshes the LaunchAgent. Direct `tailscale ...` commands are
mainly for verification and troubleshooting.

The private runtime environment file is created outside the repository:

```text
~/.config/kodexlink-tools/relay.env
```

This file is the supported place to persist relay networking settings.

- `KODEXLINK_RELAY_PUBLIC_BASE_URL` must be the same HTTPS URL entered in the
  mobile app Custom Address setting.
- `KODEXLINK_TAILSCALE_HTTPS_PORT` is the Tailscale Serve or Funnel HTTPS port.
- `KODEXLINK_RELAY_HOST_PORT` is only the local Docker port.

Do not edit the LaunchAgent plist to change relay URL or port. The LaunchAgent
only supervises the background desktop agent process.

Do not confuse the public URL with the local Docker port:

- `KODEXLINK_RELAY_PUBLIC_BASE_URL` is the address advertised to the desktop
  agent and mobile app. With Tailscale Serve, it should look like
  `https://machine-name.tailnet-name.ts.net`.
- `KODEXLINK_RELAY_HOST_PORT` is only the local Mac port bound by Docker, such
  as `8787`.

For the recommended Tailscale Serve setup, the public URL normally does not
include `:8787`, because the phone connects to HTTPS port `443` and Tailscale
proxies that traffic to `http://127.0.0.1:8787` on the Mac.

If another service already owns host port `443`, publish KodexLink on `8443`
or another HTTPS port instead. In that case,
`KODEXLINK_RELAY_PUBLIC_BASE_URL` should include the port, for example
`https://machine-name.tailnet-name.ts.net:8443`.

## Repository Clone Lifecycle

After installation, most runtime state lives outside the `kodexlink-tools`
repository clone:

- the managed upstream relay source checkout lives under
  `~/.local/share/kodexlink-tools/` by default;
- the private relay environment lives under `~/.config/kodexlink-tools/`;
- the relay database and Redis data live in Docker volumes;
- the KodexLink desktop CLI is installed by npm;
- the desktop agent LaunchAgent is installed by the upstream KodexLink CLI;
- the Tailscale Serve mapping is stored by Tailscale.

If the `kodexlink-tools` clone is deleted while the relay containers are already
running, those containers and Docker volumes can continue to exist. Docker can
also restart existing containers after Docker Desktop restarts if they were
running and still have `restart: unless-stopped`.

The clone should still be kept because it contains the Makefile, Compose file,
Dockerfile, scripts, and documentation used to manage the installation. Without
the clone, the user loses the supported commands for `make enable`,
`make disable`, `make update`, `make doctor`, rebuilds, and future maintenance.
If the relay containers are removed, the Docker image must be rebuilt, or the
environment needs to be changed, clone this repository again before managing the
setup.

## Install And Enable

First install:

```bash
make check-deps
make install PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make enable
make doctor
make pair
```

Alternative first install when `443` is already in use:

```bash
make check-deps
make install HTTPS_PORT=8443 PUBLIC_URL=https://machine-name.tailnet-name.ts.net:8443
make enable
make doctor
make pair
```

`make install` prepares the machine but does not enable runtime services. It:

- installs or refreshes the Tailscale CLI launcher;
- clones or updates the managed upstream relay source checkout;
- creates `relay.env` when missing;
- stores the relay public URL;
- installs the KodexLink desktop CLI when missing.

`make enable` starts the runtime services. It:

- starts Docker Desktop if needed;
- starts the Docker relay stack;
- configures Tailscale Serve;
- installs or refreshes the KodexLink desktop LaunchAgent.

`make disable` stops runtime services without deleting relay data:

```bash
make disable
```

It stops the desktop LaunchAgent, disables the Tailscale Serve mapping, and
stops the Docker Compose stack. PostgreSQL data remains in the Docker volume.

If only the relay URL changed:

```bash
make configure-url PUBLIC_URL=https://machine-name.tailnet-name.ts.net
make restart
make pair
```

If only the published HTTPS port changed:

```bash
make configure-https-port HTTPS_PORT=8443
make configure-url PUBLIC_URL=https://machine-name.tailnet-name.ts.net:8443
make enable
```

`make restart` reapplies the Docker Compose configuration so environment changes
are loaded into the running relay container.

## Update Without Re-Pairing

Use this when the upstream author publishes a new relay or desktop CLI version:

```bash
make update
```

It updates the managed relay checkout, updates the KodexLink desktop CLI from
npm, rebuilds and restarts the relay container, and refreshes the LaunchAgent.
It does not delete Docker volumes, recreate `relay.env`, or change
`KODEXLINK_RELAY_PUBLIC_BASE_URL`.

Existing paired devices should remain paired because their durable bindings live
in PostgreSQL and the relay URL remains the same. A relay restart can invalidate
active in-progress QR pairing sessions stored in Redis. Generate a fresh QR with
`make pair` after an update if a pairing flow was open.

## Pairing And Recovery

The QR code is not rendered by the relay. The flow is:

1. The desktop agent asks the relay to create a pairing session.
2. The relay returns a short-lived pairing payload that includes the configured
   public relay URL.
3. The desktop agent renders that payload as a QR code.
4. The desktop agent serves the pairing panel on a local-only URL like
   `http://127.0.0.1:<random-port>`.

Open a fresh pairing panel:

```bash
make pair
```

Before scanning on iPhone or iPad:

1. Connect Tailscale.
2. Open KodexLink Settings.
3. Open Relay Server.
4. In Relay Environment, select Custom Address.
5. Enter the Tailscale HTTPS relay URL.
6. Tap Save Custom Address.
7. Return to the pairing scanner and scan the Mac QR code.

The phone does not need to reach the local pairing panel URL. It only uses the
relay URL and enrollment material embedded in the QR payload.

Pairing payloads are temporary enrollment secrets. The relay stores each pairing
session in Redis with a five-minute TTL. The payload includes:

- the relay URL;
- a `pairingId`;
- a `pairingSecret`;
- an `expiresAt` timestamp;
- the desktop agent label.

The mobile app can claim the pairing only while the Redis session exists, the
secret matches, and the expiration time has not passed. After a successful
claim, the relay consumes the pairing session so it cannot be reused.

Do not store QR images, `pairingId`, `pairingSecret`, or full manual pairing
payloads in a password manager as future login methods. They expire quickly and
are sensitive while valid.

Useful recovery notes to store:

- the private relay HTTPS URL;
- the command to generate a fresh pairing session: `make pair`;
- the requirement that Tailscale must be connected on the mobile device;
- the reminder that pairing payloads expire after roughly five minutes;
- the reminder to select Custom Address in the mobile app before scanning.

## Remote Pairing

If a new phone or iPad must be paired while away from the Mac, generate a fresh
pairing session on the Mac and use it immediately.

Recommended options:

1. Use remote screen sharing to the Mac over Tailscale, run `make pair`, and
   scan the QR code shown on the Mac screen.
2. Use remote terminal access to the Mac, run `make pair`, and use the manual
   pairing payload within five minutes if the mobile app supports manual entry.
3. Temporarily publish the local pairing panel through a separate Tailscale
   Serve rule, pair the device, then disable that temporary rule immediately.

The normal Tailscale Serve rule for this project publishes only the relay:

```text
https://machine-name.tailnet-name.ts.net -> http://127.0.0.1:8787
```

It does not publish the local pairing panel. That is intentional: the local
panel exposes active enrollment material and should stay local except during a
short, deliberate remote pairing window.

## Boot Behavior

This project does not install a separate LaunchAgent to supervise Docker
Compose. Docker is the supervisor for the relay containers.

The Docker containers use `restart: unless-stopped`. The relay stack is
persistent across reboots only when both conditions are true:

- the relay stack was enabled with `make enable` and was still running when
  Docker stopped;
- Docker Desktop starts again after reboot or login.

If Docker Desktop is quit while the relay containers are running, Docker should
remember that state and restart them the next time Docker Desktop starts. If the
user intentionally stops the relay with `make disable`, `make stop`, or
`docker compose down`, Docker treats that as an explicit stop and will not
restart those containers automatically on the next Docker startup.

If Docker Desktop is not configured to start at login, start it manually:

```bash
make docker-start
make start
```

Tailscale Serve is configured in background mode by the script. Tailscale keeps
that Serve configuration and restores it when Tailscale is running again.

The desktop agent persists through the upstream KodexLink macOS LaunchAgent.
If it is not running:

```bash
make install-tool
```

## Why Docker Stays Localhost

The Compose file binds the relay to localhost on the Mac:

```text
127.0.0.1:8787
```

That keeps the raw relay port away from the LAN and internet. Docker could bind
to `0.0.0.0` or the Mac's Tailscale interface, but then the phone would reach a
plain HTTP relay. For iPhone and iPad use away from home, the cleaner endpoint
is OS-trusted HTTPS.

Tailscale Serve provides the reverse proxy and certificate layer:

```text
https://machine-name.tailnet-name.ts.net -> http://127.0.0.1:8787
```

That avoids a separate reverse proxy and certificate renewal process.

## Why The Desktop Agent Stays On The Host

The desktop agent should run directly on macOS, not inside Docker.

The agent launches `codex app-server`, uses the host user's Codex login, stores
credentials in macOS Keychain when available, and installs a LaunchAgent. A
containerized copy would be a separate Codex environment inside Docker, not the
normal Codex CLI and local workspace on the Mac.

Use Docker only for the relay-side services.

## Diagnostics

Health and diagnostics:

```bash
make health
make doctor
make doctor-relay
make doctor-tailscale
make doctor-mobile
make privacy-check
```

These are checks only. They help confirm that the saved `make` configuration is
healthy, but they are not additional setup steps required after a normal
`make enable`.

Logs and status:

```bash
make status
make logs SERVICE=relay
make measure
```

Troubleshooting:

- If Safari on the phone cannot open `/healthz`, confirm Tailscale is connected
  on the phone and the Mac is online in the Tailscale Machines page.
- If the mobile app points to an old relay URL, update Custom Address and
  re-pair.
- If `tailscale` is missing in Terminal, run `make install-tailscale-cli`.
- If the desktop agent reconnects to an old relay URL, run `make install-tool`
  after `make configure-url` and `make restart`.

## Privacy Rules

Do not commit the generated environment file, real tailnet DNS names, Tailscale
IPs, tokens, local user paths, hostnames, QR payloads, pairing IDs, or pairing
secrets to this repository.

Use placeholders in documentation and examples:

```text
https://machine-name.tailnet-name.ts.net
```
