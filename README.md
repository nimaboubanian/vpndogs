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

An optional inbound node accepts connections *from* remote clients and feeds
them into that same chain:

```
phone ──UDP 500/4500/1061──► vpndogs-ipsec-inbound   (strongswan-server)  profile ipsec-inbound
                                 charon + kernel XFRM decrypt
                                 policy route ──► tun0 ──socks──► vpndogs-router :1070
```

```
laptop ──UDP 1062──► vpndogs-wg-inbound              (wireguard-server)   profile wg-inbound
                        kernel wireguard decrypt
                        policy route ──► tun0 ──socks──► vpndogs-router :1070
```

```
tablet ──UDP 1063──► vpndogs-awg-inbound             (amneziawg-server)   profile awg-inbound
                        userspace amneziawg-go decrypt (obfuscated 3.1 protocol)
                        policy route ──► tun0 ──socks──► vpndogs-router :1070
```

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
| `IPSEC_USERS`, `IPSEC_PSK`, `VPN_SERVER_ADDR` | **Required for the inbound IPsec node only** (profile `ipsec-inbound`). EAP credentials, the IKEv1 shared secret, and the address clients dial. |
| `VPN_POOL`, `CLIENT_DNS` | Address pool and DNS pushed to inbound IPsec clients. |
| `WG_PEERS` | **Required for the inbound WireGuard node only** (profile `wg-inbound`). `name:PUBLIC_KEY` pairs, comma-separated; BYO public keys only. |
| `WG_POOL` | Address pool for inbound WireGuard clients (server takes the first address). |
| `AWG_PEERS` | **Required for the inbound AmneziaWG node only** (profile `awg-inbound`). Same format as `WG_PEERS`. |
| `AWG_POOL` | Address pool for inbound AmneziaWG clients (server takes the first address). |
| `AWG_HPK` | Optional shared HeaderProtectionKey (empty = off); must be identical in every client conf. |

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

## Inbound IPsec node (optional)

Remote clients can dial into the stack instead of the host using a SOCKS proxy
it already runs. Add `ipsec-inbound` to `COMPOSE_PROFILES`, set `IPSEC_USERS`,
`IPSEC_PSK` and `VPN_SERVER_ADDR` in `.env`, and bring it up:

```sh
docker compose up -d vpndogs-ipsec-inbound
```

It publishes UDP **500** and **4500** (what native IKEv2 clients and legacy
IKEv1 routers require — open both on the firewall, plus **1061**/udp if
strongSwan-based clients will use it) and needs `NET_ADMIN` + `/dev/net/tun`.

Connecting a client:

- **Native IKEv2** (Windows/iOS/macOS/Android) — server `VPN_SERVER_ADDR`, type
  IKEv2 EAP with username/password from `IPSEC_USERS`. First copy the CA:
  `docker cp vpndogs-ipsec-inbound:/etc/swanctl/x509ca/ca-cert.pem ./ca.pem`,
  then import it into the client.
- **strongSwan-based clients** — same credentials on port **1061**.
- **Legacy IKEv1 routers** — shared secret `IPSEC_PSK` on port **500**, main
  mode.

Decrypted traffic enters the same chain as everything else, so inbound clients
get domestic-direct / sb-cluster / blackhole exactly like the local SOCKS
clients.

**Firewall or ports already taken?** IKE needs UDP 500 and 4500 on the host. If
the host runs its own IPsec/L2TP daemon, publishing fails. Only strongSwan-based
clients can use a custom port, so redirecting 500/4500 loses native and legacy
clients.

**Connected, but the tunnel carries no traffic?** The host kernel needs
`ip_compat` (ESP-in-UDP), `af_alg` and `crypto_user` (ChaCha20/AES-GCM ESP) —
the container shares the host kernel, so they are not part of the image:
`lsmod | grep -E '^(ip_compat|af_alg|crypto_user|xfrm_user)'`, and
`sudo modprobe ip_compat af_alg crypto_user xfrm_user` if anything is missing.
Without them the SA negotiates and passes nothing, which looks like a routing
fault rather than a missing module.

**Enabled without credentials?** The container logs `FATAL: IPSEC_USERS is
required` (or `IPSEC_PSK` / `VPN_SERVER_ADDR`) and restart-loops; the rest of
the stack is unaffected.

## Inbound WireGuard node (optional)

Remote clients can also dial in over kernel WireGuard — no userspace daemon,
the host's `wireguard` module does the work. Add `wg-inbound` to
`COMPOSE_PROFILES`, set `WG_PEERS` in `.env`, and bring it up:

```sh
docker compose up -d vpndogs-wg-inbound
```

It publishes UDP **1062** only (open it on the firewall) and needs `NET_ADMIN`
+ `/dev/net/tun` — and the host `wireguard` kernel module
(`lsmod | grep wireguard`; `sudo modprobe wireguard` if missing).

Keys are bring-your-own, split across both sides: on each **client**
(`wg genkey | tee privatekey | wg pubkey > publickey`), and only the
**public** key goes into `WG_PEERS` as `name:PUBKEY` — private keys never
touch the server. The full client conf template lives in
`dogs/wireguard-server-docker/README.md` (Address = pool offset, `DNS`,
`AllowedIPs = 0.0.0.0/0, ::/0` (the `::/0` closes the client-side IPv6 leak —
see Troubleshooting), `PersistentKeepalive = 25`, server `PublicKey` and
`Endpoint = <host>:1062` — the server's public key is printed by
`docker exec vpndogs-wg-inbound report.sh`).

Decrypted traffic enters the same chain as IPsec clients: domestic-direct /
sb-cluster / blackhole via the router.

**Enabled without credentials?** The container logs `FATAL: WG_PEERS is
required` and restart-loops; the rest of the stack is unaffected.

**`wg-keys` volume lost?** The server generates a NEW key on the next boot —
every client conf's server `PublicKey` goes stale until you redistribute the
new one from `report.sh`.

## Inbound AmneziaWG node (optional)

Where plain WireGuard is fingerprinted and blocked, the obfuscated AmneziaWG
protocol can still connect. Two userspace daemons do the work inside the
container — **no host kernel module needed** (unlike the WG node). Requires
AmneziaWG **3.1** clients (current Amnezia app / `awg-tools` ≥ 3.1; older
AWG 1.x clients are unsupported). Add `awg-inbound` to `COMPOSE_PROFILES`,
set `AWG_PEERS` in `.env` (and optionally the shared `AWG_HPK`), and bring
it up:

```sh
docker compose up -d vpndogs-awg-inbound
```

It publishes UDP **1063** only (open it on the firewall) and needs
`NET_ADMIN` + `/dev/net/tun`. Keys are bring-your-own like the WG node:
client keypair generated client-side (`awg genkey | awg pubkey`), only the
**public** key into `AWG_PEERS` as `name:PUBKEY`. The client conf must copy
the server's obfuscation parameters **verbatim** (S1–S4, H1–H4, and the
`HeaderProtectionKey` when `AWG_HPK` is set — a mismatch means handshakes
never complete). The full template lives in
`dogs/amneziawg-server-docker/README.md`; the server's public key and
constants are printed by `docker exec vpndogs-awg-inbound report.sh`.

Decrypted traffic enters the same chain as IPsec/WG clients:
domestic-direct / sb-cluster / blackhole via the router.

**Enabled without credentials?** The container logs `FATAL: AWG_PEERS is
required` and restart-loops; the rest of the stack is unaffected.

**`awg-keys` volume lost?** Same as the WG node: new server key on next
boot, re-distribute the public key from `report.sh`.

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

- **Dual-stack services blocked while IPv4-only ones work** — a client-side
  IPv6 leak: the inbound tunnels carry only IPv4 (`0.0.0.0/0`), so a
  dual-stack client keeps using its native IPv6 *beside* the tunnel, and
  services see the client's real (sanctioned-region) IPv6 address. Fix: add
  `::/0` to the client's `AllowedIPs` (WG/AWG nodes — the server drops that
  IPv6, native IPv6 returns when the tunnel is down); on native IKEv2 clients
  disable IPv6 on the active interface. Section B itself is IPv4-only (the
  `vpndogs` Docker network has no IPv6), so the leak is never in the stack.
  Verify with `curl -6 https://api64.ipify.org` on the client with the tunnel
  up: any answer = leak.
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
