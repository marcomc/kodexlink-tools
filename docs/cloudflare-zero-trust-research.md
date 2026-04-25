# Cloudflare Zero Trust Research Notes

This document supports the TODO proposition `idea:cloudflare-zero-trust-relay`.
It records the current research findings and the design conclusions for a
possible future Cloudflare publishing mode.

## Table of Contents

- [Purpose](#purpose)
- [Current Supported Baseline](#current-supported-baseline)
- [Confirmed Cloudflare Findings](#confirmed-cloudflare-findings)
- [Unconfirmed Questions](#unconfirmed-questions)
- [Design Conclusions For KodexLink](#design-conclusions-for-kodexlink)
- [Candidate Cloudflare Modes](#candidate-cloudflare-modes)
- [Expected Repository Changes](#expected-repository-changes)
- [Validation Plan](#validation-plan)
- [References](#references)

## Purpose

The current project supports Tailscale Serve as the operational private
publishing path. Cloudflare support is not implemented.

The goal of a future Cloudflare mode would be to keep the local relay private
on the Mac while giving the KodexLink mobile app a trusted HTTPS relay address.
The key question is whether Cloudflare Zero Trust can provide that HTTPS
address without making the relay publicly usable.

## Current Supported Baseline

Tailscale Serve currently provides the complete publishing layer:

```text
https://machine-name.tailnet-name.ts.net -> http://127.0.0.1:8787
```

Docker stays bound to localhost. Tailscale terminates HTTPS and proxies to the
local relay. The mobile app stores the HTTPS URL during pairing.

This is why `KODEXLINK_RELAY_PUBLIC_BASE_URL` is normally:

```text
https://machine-name.tailnet-name.ts.net
```

and `KODEXLINK_RELAY_HOST_PORT` remains the local Docker port:

```text
8787
```

## Confirmed Cloudflare Findings

Cloudflare Mesh assigns enrolled devices a private Mesh IP and supports private
connectivity between enrolled devices and nodes.

Cloudflare documents Mesh as private IP connectivity. It is not documented as a
drop-in equivalent to Tailscale Serve's HTTPS reverse proxy.

Cloudflare distinguishes Mesh and Tunnel:

- Mesh provides private IP connectivity between enrolled devices and nodes.
- Tunnel publishes or connects services through `cloudflared`.

Cloudflare documents private hostname routing through `cloudflared`. In the
private hostname documentation, WARP can be the client-side on-ramp, while
`cloudflared` is the supported service-side connector.

Cloudflare Tunnel supports WebSocket traffic.

Cloudflare Access can protect self-hosted applications and private resources
with Zero Trust policies. Those policies can involve identity, device posture,
WARP enrollment, and Gateway controls.

For native mobile apps, Access policies that require browser redirects can be a
compatibility risk. Cloudflare documents non-browser/private application
patterns, but KodexLink-specific compatibility must be tested.

## Unconfirmed Questions

The following points were not confirmed by the Cloudflare documentation alone:

- Whether a service bound only to `127.0.0.1:8787` is reachable from another
  device through Mesh IP without running `cloudflared` on the Mac.
- Whether KodexLink iOS accepts `http://<mesh-ip>:8787` as a Custom Address for
  a remote relay.
- Whether KodexLink iOS requires HTTPS for all non-local relay addresses.
- Whether Cloudflare Access-protected HTTPS hostnames work transparently with
  the KodexLink native app.
- Whether Cloudflare private hostnames over WARP provide the exact TLS/SNI
  behavior the KodexLink mobile app expects.

These require practical tests.

## Design Conclusions For KodexLink

Cloudflare Mesh alone should not be treated as a supported replacement for
Tailscale Serve.

The most promising Cloudflare design is:

```text
Cloudflare One Client on iPhone/iPad
  -> Access-protected or WARP-private HTTPS hostname
  -> Cloudflare Tunnel / cloudflared on the Mac
  -> http://127.0.0.1:8787
  -> relay container
```

This preserves the current Docker security model because `cloudflared` runs on
the Mac and can reach localhost. Docker does not need to bind to `0.0.0.0` or a
private Mesh IP.

The future implementation should therefore be a separate Cloudflare Zero Trust
mode, not a small variation of the Tailscale Serve mode.

## Candidate Cloudflare Modes

### Public Hostname With Cloudflare Access

```text
https://klr.example.com
  -> Cloudflare Access policy
  -> cloudflared tunnel
  -> http://127.0.0.1:8787
```

Benefits:

- Cloudflare terminates public HTTPS.
- No router ports are opened.
- Docker can remain localhost-only.
- WebSocket support is documented for Cloudflare Tunnel.

Risks:

- The hostname is public, even if access is protected.
- KodexLink may not handle Access browser redirects.
- Requires a mobile compatibility test for Access policy choices.

### Private Hostname Over WARP And Cloudflared

```text
https://private-relay.internal.example
  -> WARP/private routing
  -> cloudflared
  -> http://127.0.0.1:8787
```

Benefits:

- Closer to the desired "only enrolled devices" model.
- Keeps the relay away from normal public internet access.
- Docker can remain localhost-only.

Risks:

- TLS and hostname behavior must be validated.
- Cloudflare private hostname routing is more complex than Tailscale Serve.
- Requires enrolled Cloudflare One clients on mobile devices.

### Mesh-Only IP Connectivity

```text
http://<mac-mesh-ip>:8787
```

Benefits:

- Private IP connectivity is the simplest Mesh concept.
- No public hostname.

Risks:

- No documented automatic HTTPS endpoint.
- May require Docker to bind outside localhost.
- Mobile app HTTPS requirements are not confirmed.
- Not recommended as the primary Cloudflare design.

## Expected Repository Changes

Future Cloudflare support should add:

- a Cloudflare setup guide separate from the Tailscale guide;
- a `cloudflared` deployment option, either host-managed or Docker-managed;
- environment variables for Cloudflare mode, hostname, local origin, and Access
  or private-hostname strategy;
- Makefile targets such as `cloudflare-check`, `cloudflare-tunnel-up`,
  `cloudflare-tunnel-down`, and `cloudflare-doctor`;
- diagnostics for WARP enrollment, Tunnel status, `/healthz`, and WebSocket
  reachability;
- a mobile compatibility test plan for KodexLink Custom Address;
- clear warnings for modes that require public hostnames or do not provide
  trusted HTTPS.

## Validation Plan

Before implementing Cloudflare as a supported mode:

1. Confirm whether the KodexLink mobile app requires HTTPS for remote relay
   addresses.
2. Test Cloudflare Tunnel public hostname with WebSocket traffic to the relay.
3. Test Cloudflare Access policies that do not require an interactive browser
   redirect from the KodexLink app.
4. Test private hostname routing over WARP with `cloudflared` as the connector.
5. Confirm that `KODEXLINK_RELAY_PUBLIC_BASE_URL` can be set to the selected
   Cloudflare HTTPS hostname and used successfully during pairing.
6. Confirm that existing paired devices survive `make update` and relay
   container rebuilds with the Cloudflare mode enabled.
7. Decide whether Mesh-only IP connectivity should remain unsupported,
   experimental, or documented only as a research path.

## References

- [Cloudflare Mesh](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/)
- [Cloudflare Mesh client devices](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-mesh/client-devices/)
- [Cloudflare Tunnel private networks](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/)
- [Cloudflare private hostname routing](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/private-net/cloudflared/connect-private-hostname/)
- [Cloudflare Tunnel FAQ](https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/)
- [Cloudflare Access private applications](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/self-hosted-private-app/)
