# TODO

## Propositions

- [ ] **Cloudflare Zero Trust Relay Publishing**

  Label: `idea:cloudflare-zero-trust-relay`

  Assessment: Add an optional Cloudflare publishing mode for users who prefer
  Cloudflare One over Tailscale. The promising path is not Mesh alone, but a
  Cloudflare Tunnel and Zero Trust design that preserves HTTPS for the mobile
  client while keeping the local relay bound to localhost. The main risk is
  whether the native KodexLink mobile app can complete requests through
  Cloudflare Access or private hostname routing without browser-style
  authentication redirects.

  Research notes:
  [docs/cloudflare-zero-trust-research.md](docs/cloudflare-zero-trust-research.md)

  Actions:

  - Define supported Cloudflare modes separately from the existing Tailscale
    Serve mode: public hostname with Access, private hostname via WARP and
    `cloudflared`, and Mesh-only IP connectivity as an experimental note.
  - Add a Cloudflare configuration document that preserves the research
    findings: Mesh IP behavior, Tunnel versus Mesh responsibilities, private
    hostname routing requirements, Access policy constraints, WARP enrollment,
    and WebSocket support.
  - Add a `cloudflared` deployment option that proxies from Cloudflare to
    `http://127.0.0.1:8787` so Docker can remain localhost-only.
  - Add environment variables for Cloudflare mode, such as relay public URL,
    tunnel hostname, Access/private-hostname mode, and local origin target.
  - Add Makefile targets for Cloudflare setup and operations, for example
    `cloudflare-check`, `cloudflare-tunnel-up`, `cloudflare-tunnel-down`, and
    `cloudflare-doctor`.
  - Add diagnostics that verify WARP enrollment, Tunnel status, private
    hostname reachability, `/healthz`, and WebSocket compatibility.
  - Create an explicit mobile compatibility test plan for KodexLink Custom
    Address using Cloudflare Access-protected hostnames and WARP/private
    hostnames.
  - Document the expected HTTPS story for each Cloudflare mode, including when
    Cloudflare terminates TLS, when the origin remains HTTP, and when a trusted
    origin certificate would be required.
