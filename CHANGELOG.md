# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed

- `make install` and `make configure-url` now reuse the existing
  `~/.config/kodexlink-tools/relay.env` relay URL instead of prompting again
  after a reinstall or refresh, while still prompting on first install when the
  env file only contains the bootstrap localhost placeholder.
- `make doctor` now reports a clearer remediation hint when the configured
  mobile-facing HTTPS URL fails because the node hostname or certificate no
  longer matches.

### New

- Added `make curl` for quickly fetching relay JSON locally or through the
  configured public HTTPS URL.
- Added configurable Tailscale HTTPS publishing ports, so the relay can be
  exposed on `8443` or `10000` when host port `443` is already in use.

## [0.1.0] - 2026-04-25

### Added

- Added a Docker Compose relay stack for running the KodexLink relay,
  PostgreSQL, and Redis locally on macOS.
- Added a managed upstream relay source checkout workflow, so the relay server
  can be cloned or updated from the original GitHub project before building the
  local Docker image.
- Added a localhost-only Docker publishing model that keeps the raw relay HTTP
  port off the LAN and internet by default.
- Added Tailscale Serve support for private HTTPS access from iPhone and iPad
  without opening router ports or managing separate TLS certificates.
- Added optional Tailscale Funnel commands for deliberate public HTTPS
  publishing when private tailnet access is not enough.
- Added a Makefile command surface for install, enable, disable, pairing,
  status, logs, health checks, resource measurement, diagnostics, and linting.
- Added a split install and enable workflow: `make install` prepares the
  machine, while `make enable` starts Docker, Tailscale Serve, and the
  KodexLink desktop LaunchAgent.
- Added a safe update workflow with `make update` for refreshing the upstream
  relay source and desktop CLI without deleting relay data or changing the
  configured public URL.
- Added automatic installation support for the Tailscale CLI launcher and the
  KodexLink desktop CLI.
- Added macOS LaunchAgent integration for the KodexLink desktop agent so it can
  reconnect after login and continue bridging Codex to the relay.
- Added QR pairing documentation that explains where the QR code comes from,
  why pairing payloads expire, and why old pairing payloads should not be stored
  as reusable credentials.
- Added iPhone and iPad setup documentation for selecting Relay Server >
  Custom Address before scanning a private-relay QR code.
- Added remote pairing guidance for screen sharing, remote terminal use, and
  short-lived pairing-panel exposure.
- Added diagnostics commands for relay health, Tailscale Serve availability,
  mobile-facing HTTPS reachability, and repository privacy checks.
- Added resource measurement commands and baseline idle-memory expectations for
  the relay, PostgreSQL, and Redis containers.
- Added English operational documentation for Tailscale MagicDNS, HTTPS
  certificates, optional exit nodes, reboot behavior, and daily operations.
- Added compact documentation structure with the README as a quick entrypoint
  and dedicated guides for Tailscale setup and service operations.
- Added an AGPL-3.0-only license file with upstream attribution and a Tailscale
  affiliation disclaimer.
