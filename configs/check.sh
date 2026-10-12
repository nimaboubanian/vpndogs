#!/usr/bin/env bash
set -euo pipefail

SOCKS=--socks5-hostname
PROXY=127.0.0.1:1070
FAILOVER=0
[ "${1:-}" = "--failover" ] && FAILOVER=1

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "PASS: $1" >&2
}

wait_containers() {
    # wait until every router/sb-client/selector/LB container is healthy
    # (softether only needs `running`: gost answers even if the tunnel is down)
    local budget=120
    while [ $budget -gt 0 ]; do
        local ok=1
        for c in vpndogs-router vpndogs-selector vpndogs-sb-clients-lb vpndogs-sb-client-1; do
            state=$(docker inspect --format '{{.State.Health.Status}}' "$c" 2>/dev/null || echo missing)
            [ "$state" = healthy ] || ok=0
        done
        se=$(docker inspect --format '{{.State.Status}}' vpndogs-softether 2>/dev/null || echo missing)
        [ "$se" = running ] || ok=0
        [ $ok = 1 ] && return 0
        sleep 2
        budget=$((budget - 2))
    done
    fail "stack containers not healthy within 120s"
}

wait_containers
sleep 5

host_ip=$(curl -s --noproxy '*' --max-time 20 https://api.ipify.org)
[ -n "$host_ip" ] || fail "direct egress (host): no IP"

proxy_ip=$(curl -s --max-time 20 $SOCKS $PROXY https://api.ipify.org)
if [ -n "$proxy_ip" ] && [ "$proxy_ip" != "$host_ip" ]; then
    pass "remote egress (proxy: $proxy_ip, host: $host_ip)"
else
    fail "remote egress: proxy IP empty or equals host IP ($proxy_ip)"
fi

code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 $SOCKS $PROXY https://www.aparat.com)
if [ "${code:-0}" -ge 200 ] && [ "$code" -lt 400 ]; then
    pass "domestic egress (aparat.com -> HTTP $code)"
else
    fail "domestic egress: HTTP $code"
fi

if curl -s -o /dev/null --max-time 10 $SOCKS $PROXY http://googlesyndication.com; then
    fail "blackhole: googlesyndication.com was reachable"
else
    pass "blackhole (googlesyndication.com unreachable)"
fi

if [ $FAILOVER = 1 ]; then
    names=$(docker ps --filter 'name=^vpndogs-sb-client-' --format '{{.Names}}')
    [ -n "$names" ] || fail "failover: no running sb-clients to stop"
    docker stop $names > /dev/null
    trap 'docker start $names > /dev/null 2>&1 || true' EXIT INT TERM
    sleep 15

    # ponytail: if-condition, not a bare assignment — under `set -e` a curl error
    # would abort before `docker start`, leaving the sb-clients stopped.
    if failover_ip=$(curl -s --max-time 20 $SOCKS $PROXY https://api.ipify.org) \
        && [ -n "$failover_ip" ] && [ "$failover_ip" != "$host_ip" ]; then
        pass "failover (egress: $failover_ip)"
    else
        docker start $names > /dev/null
        fail "failover: no egress via softether after clients stopped (${failover_ip:-curl failed})"
    fi

    docker start $names > /dev/null
    budget=120
    restored_ip=""
    restored=0
    while [ $budget -gt 0 ]; do
        if restored_ip=$(curl -s --max-time 20 $SOCKS $PROXY https://api.ipify.org) && [ -n "$restored_ip" ] && [ "$restored_ip" != "$host_ip" ]; then
            pass "restore (egress: $restored_ip)"
            restored=1
            break
        fi
        sleep 5
        budget=$((budget - 5))
    done
    [ "$restored" = 1 ] || fail "restore: no sb-cluster egress after clients restarted"
fi

echo "all checks passed" >&2
