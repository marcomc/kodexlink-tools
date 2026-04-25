# License

Copyright (c) 2026 Marco Massari Calderone <marco@marcomc.com>

This repository contains local setup and operations tooling for running a
private KodexLink mobile relay. Unless a file states otherwise, this repository
is distributed under the GNU Affero General Public License version 3 only
(`AGPL-3.0-only`).

## Upstream Project Notice

This tooling is designed to build and run the upstream KodexLink / Codex Mobile
Relay project.

- Upstream repository: <https://github.com/David699/codex-mobile-relay>
- Upstream author: David699
- Upstream license declared by the project: `AGPL-3.0-only`

No upstream source code is vendored in this repository. The Docker setup builds
from a local clone of the upstream project path configured in the private
runtime environment file.

## Tailscale Disclaimer

This project is not affiliated with, sponsored by, endorsed by, or maintained by
Tailscale Inc. Tailscale is referenced only as an optional network transport for
private access to a locally hosted relay.

Tailscale names, trademarks, services, and documentation belong to Tailscale
Inc. Use of Tailscale is subject to Tailscale's own terms, policies, and
documentation.

## AGPL Notice

The AGPL-3.0-only license requires that users who interact with modified
network software can receive the corresponding source code under the same
license terms. If you modify this tooling or the upstream relay and provide
network access to it, review the AGPL obligations before distributing or
operating the modified service.

The full license text is available from the GNU project:

<https://www.gnu.org/licenses/agpl-3.0.html>
