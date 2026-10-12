# vpndogs

One command deploys the whole routing stack on any machine:

```sh
git clone git@github.com:nimaboubanian/vpndogs.git && cd vpndogs
cp .env.example .env    # then edit it (see table below)
docker compose up -d
```

The images are built and published from the separate `dogs/` repositories and
pulled from Docker Hub: `nimaboubanian/sing-box-router`,
`nimaboubanian/sing-box-client`, `nimaboubanian/sing-box-lb`,
`nimaboubanian/softether-vpn-client`.

## Architecture

```
host :1070 ──► vpndogs-router            (sing-box-router)   socks5+http inbound
                 route: reject rulesets ────────────────► block (blackhole)
                 route: geoip-ir / geosite-ir / private ► direct (host gateway)
                 everything else ───────────────────────► proxy-out
                 │
                 ▼
               vpndogs-selector            (haproxy:lts-alpine + configs/selector/haproxy.cfg)  :1080
                 ├─ default: vpndogs-sb-clients-lb   (sing-box-lb)   :1081   roundrobin
                 │             ├─► vpndogs-sb-client-1   (sing-box-client)  SUB_URL_1   always on
                 │             ├─► vpndogs-sb-client-2   (sing-box-client)  SUB_URL_2   profile sb-client-2
                 │             ├─► vpndogs-sb-client-3   (sing-box-client)  SUB_URL_3   profile sb-client-3
                 │             └─► vpndogs-sb-client-4   (sing-box-client)  SUB_URL_4   profile sb-client-4
                 └─ backup:  vpndogs-softether          (softether-vpn-client) :1082   gost egress
                               mounts ./vpn-profiles (read-only), NET_ADMIN + /dev/net/tun
```

Only `127.0.0.1:1070` is published to the host. Traffic entering there takes
one of three exits:

- **Domestic** — Iran-domain/IP rulesets go out through the host's gateway.
- **Remote** — everything else goes out through the proxy chain (sb-cluster).
- **Blackhole** — reject-listed domains (ads, …) are dropped.

When the sb-cluster dies, the selector automatically fails over to the
SoftEther fallback and returns to the cluster when it recovers.

## Prerequisites

- Docker Engine with **compose v2.20+** (long-syntax `depends_on` with
  `required: false`).
- `curl` and `bash` on the host, for the verification script.

## The `.env` file (copy of `.env.example`)

| Variable | Meaning |
|---|---|
| `SUB_URL_1` | **Required.** Subscription link for `sb-client-1` (the always-on client). Compose refuses to start without it. |
| `SUB_URL_2..4` | Optional; only read when the matching profile is enabled. |
| `COMPOSE_PROFILES` | Which extra clients to run, e.g. `sb-client-2,sb-client-4`. |
| `VPN_PROFILE` | SoftEther profile name (without the `.vpn` extension) in `vpn-profiles/` — e.g. `DEFAULT-main`. |
| `SE_HOST`, `SE_PORT`, `SE_HUB`, `SE_USER`, `SE_PASSWORD` | SoftEther connection as env vars — alternative to a `.vpn` profile file. Most users leave these empty. |

> Run an extra client (`COMPOSE_PROFILES=sb-client-2` etc.) *without* a
> matching `SUB_URL_n` and that container will fail its subscription fetch and
> restart in a loop. The rest of the stack is unaffected.

## `vpn-profiles/`

The gitignored `vpn-profiles/` directory holds SoftEther `*.vpn` profile files
(exported from the SoftEther Manager panel) for the fallback client: they look
like `dogs/softether-client-docker/vpn-profiles/DEFAULT-main.vpn`. The
directory is invisible to git — create it if absent.

**The fallback must be configured or it restart-loops.** With neither a
profile nor `SE_*` vars, the image's entrypoint exits (`SE_HUB is required for
environment-based VPN setup`) and docker restarts it forever. Routing through
the sb-cluster is unaffected — but there is no failover until you configure it,
and `configs/check.sh --failover` will say so explicitly:

```sh
mkdir -p vpn-profiles
cp /path/to/your-profile.vpn vpn-profiles/       # then in .env:
VPN_PROFILE=your-profile                         # (name without the .vpn extension)
docker compose up -d vpndogs-softether
```

## `user-configs/`

Draft directory for config overrides, **not wired in**. Wiring it in (config
overrides, compose overrides) is a future feature.

## Verifying

```sh
configs/check.sh              # remote egress, domestic egress, blackhole
configs/check.sh --failover   # plus: stop sb-clients -> softether takes over -> they come back
```

Each check must print `PASS: …` and the script exits 0. `--failover` damage:
the sb-clients are stopped and started again — no ledger left behind.

## Troubleshooting

- `docker compose logs <service>` — the usual first look.
- Every dogs image ships a `report.sh`; paste its output into an issue:
  `docker exec vpndogs-sb-client-1 ./report.sh`
- `docker compose ps` — health states. `start_period` is generous (up to 90s
  on the clients: subscription fetch + render + run), so patience first
  before diagnosing.

## Where the images come from

The container images live in the gitignored `dogs/` repositories in this
parent directory. Each commit of *this* repo defines one deployable
architecture; changes to the topology happen here, image changes in `dogs/`.
