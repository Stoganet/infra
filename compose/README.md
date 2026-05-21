# compose — Stoganet service stack

Docker Compose stack for the home server. Private services accessible only via NetBird mesh, with Let's Encrypt wildcard certificates via DNS-01.

## TLS strategy

Wildcard certificate (`*.stoganet.com`) via DNS-01 challenge:
- **Privacy**: only `*.stoganet.com` appears in Certificate Transparency logs
- **No inbound ports**: DNS-01 is outbound-only, home server stays airgapped
- **Zero client config**: green padlock everywhere, no CA sideloading

## Architecture

```
Internet ──X──┐
              │ (blocked by NAT)
              ▼
        ┌─────────────┐
        │ Home Server │◀─── NetBird Mesh ───▶ Phones, Laptops, TVs
        └─────────────┘
              │
    ┌─────────┴─────────┐
    ▼                   ▼
Traefik             Services
(TLS + routing)
```

## Services

| Service | Purpose |
|---------|---------|
| **Traefik** | Reverse proxy with automatic wildcard TLS via DNS-01 |
| **Jellyfin** | Media server with Intel Quick Sync hardware transcoding |
| **Jellyseerr** | Media request and discovery frontend |
| **Gluetun** | WireGuard VPN container, provides netns for qBittorrent |
| **qBittorrent** | Torrent client, all traffic routed through Gluetun |
| **Sonarr / Radarr** | TV and movie automation |
| **Prowlarr** | Indexer manager for Sonarr/Radarr |
| **Bazarr** | Subtitle automation |
| **FlareSolverr** | Cloudflare challenge solver for Prowlarr |
| **Portainer** | Docker management UI |

The `stogad` daemon (file watcher / media scanner / photo organizer / push alerts) runs natively on the host and is maintained in [Stoganet/stogad](https://github.com/Stoganet/stogad).

## Security

- **No WAN exposure**: home server behind NAT, no port forwarding, NetBird-only access
- **TLS**: wildcard cert via DNS-01, no subdomain metadata in CT logs
- **Containers**: memory limits, `no-new-privileges:true`, capabilities dropped to minimum required
- **VPN-tunneled torrents**: qBittorrent shares Gluetun's netns; firewall kill-switch blocks all egress if the tunnel drops
- **Health checks**: all services monitored with restart policies

## DNS resolution

Configure NetBird DNS to resolve subdomains to the home server's NetBird IP:
- `*.stoganet.com` → `100.64.x.x` (home server's NetBird IP)
