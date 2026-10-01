#!/usr/bin/env bash
# docker-e2e.sh - end-to-end test of the Docker deployment with a fake PS5 and Portal.
#
# Builds a fake LAN (a Linux bridge with PS5 and Portal namespaces), attaches the
# deploy/docker/compose.yaml macvlan network to it through a veth "uplink", and drives the image
# through configure, baseline, try (docker kill -s INT), up -d + healthcheck, down,
# and a relay crash with restart. Needs root, Docker with compose v2, iproute2, ethtool,
# python3 (stdlib only).
#   docker build -f deploy/docker/Dockerfile -t portal-relay:local .
#   sudo IMAGE=portal-relay:local bash deploy/tests/docker-e2e.sh
#   COMPOSE_EXTRA=path/to/override.yaml adds an extra compose file (optional).
# shellcheck disable=SC2034  # several variables are only read inside check()'s eval strings
set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PS5=10.88.0.10 PORTAL=10.88.0.20 RELAY=10.88.0.5
PS5_MAC=02:88:00:00:00:02 PORTAL_MAC=02:88:00:00:00:03
T=$(mktemp -d)
FAILS=0
FWD_WAS=$(cat /proc/sys/net/ipv4/ip_forward)

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

cleanup() {
  local rc=$?
  (cd "$T/proj" 2>/dev/null && dc down -t 60 >/dev/null 2>&1) || true
  for n in ps5 portal; do
    for p in $(ip netns pids "$n" 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
    ip netns del "$n" 2>/dev/null || true
  done
  iptables -D FORWARD -i br-dke2e -o br-dke2e -j ACCEPT 2>/dev/null || true
  ip link del dke2e-up 2>/dev/null || true
  ip link del br-dke2e 2>/dev/null || true
  echo "$FWD_WAS" > /proc/sys/net/ipv4/ip_forward
  if [ "$FAILS" = 0 ] && [ "$rc" = 0 ]; then rm -rf "$T"; else echo "logs kept in $T"; fi
}
trap cleanup EXIT
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

step "Fake LAN: bridge, PS5 + Portal namespaces, veth uplink as the macvlan parent"
echo 1 > /proc/sys/net/ipv4/ip_forward     # what Docker hosts normally have
ip link add br-dke2e type bridge && ip link set br-dke2e up
ip link add dke2e-up type veth peer name dke2e-br
ip link set dke2e-br master br-dke2e up && ip link set dke2e-up up
iptables -I FORWARD -i br-dke2e -o br-dke2e -j ACCEPT   # see netns-e2e.sh (br_netfilter)
mk() {
  ip netns add "$1"; ip link add "v-$1" type veth peer name eth0 netns "$1"
  ip link set "v-$1" master br-dke2e up
  ip -n "$1" link set lo up; ip -n "$1" link set eth0 address "$2" up
  ip -n "$1" addr add "$3/24" dev eth0
}
mk ps5 "$PS5_MAC" "$PS5"; mk portal "$PORTAL_MAC" "$PORTAL"
ip netns exec portal ethtool -K eth0 tx off >/dev/null

mkdir -p "$T/proj"
cp "$REPO/deploy/docker/compose.yaml" "$T/proj/"
printf 'LAN_PARENT=dke2e-up\nLAN_SUBNET=10.88.0.0/24\nLAN_GATEWAY=10.88.0.1\nRELAY_IP=%s\n' "$RELAY" > "$T/proj/.env"
EXTRA=()
if [ -n "${COMPOSE_EXTRA:-}" ]; then cp "$COMPOSE_EXTRA" "$T/proj/extra.yaml"; EXTRA=(-f extra.yaml); fi
if [ -n "${IMAGE:-}" ]; then
  printf 'services:\n  relay:\n    build: !reset null\n    image: %s\n' "$IMAGE" > "$T/proj/image.yaml"; EXTRA+=(-f image.yaml)
fi
cd "$T/proj"
dc() { docker compose -f compose.yaml "${EXTRA[@]}" "$@"; }

cat > "$T/ps5.py" <<'EOF'
import hashlib, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((sys.argv[1], 9296))
log = open(sys.argv[2], 'a', buffering=1)
while True:
    d, a = s.recvfrom(4096)
    log.write(hashlib.sha256(d).hexdigest()[:12] + '\n'); s.sendto(b'video' * 200, a)
EOF
# A stand-in for the Portal's session-start packet: same framing checks as upstream's test fixture.
cat > "$T/portal.py" <<'EOF'
import base64, hashlib, socket, sys, time
def varint(x):
    b = bytearray()
    while x > 127: b.append((x & 127) | 128); x >>= 7
    return bytes(b) + bytes([x])
def field(k, v):
    return varint(k * 8) + varint(v) if isinstance(v, int) else varint(k * 8 + 2) + varint(len(v)) + v
def startup():
    plain = b' ' * 334 + b'25000' + b' ' * (1721 - 339)
    cipher = bytes(a ^ ((i * 19 + 31) % 256) for i, a in enumerate(plain))
    msg = field(1, 0) + field(2, field(1, 20) + field(2, b'synthetic') + field(3, base64.b64encode(cipher)) + field(4, b''))
    data = (7).to_bytes(4, 'big') + b'\0' * 4 + b'\0' + msg[:1200]
    return b'\0tagg' + b'\0' * 8 + b'\0\0' + (len(data) + 4).to_bytes(2, 'big') + data
p = startup() if sys.argv[1] == 'startup' else b'controller-input'
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((sys.argv[3], 50000)); s.settimeout(.2)
got = 0
for _ in range(int(sys.argv[2])):
    s.sendto(p, (sys.argv[4], 9296))
    try: s.recv(4096); got += 1
    except socket.timeout: pass
    time.sleep(.2)
print(hashlib.sha256(p).hexdigest()[:12], got)
EOF
ip netns exec ps5 python3 "$T/ps5.py" "$PS5" "$T/ps5.log" &
send() { ip netns exec portal python3 "$T/portal.py" "$1" "$2" "$PORTAL" "$PS5"; }
portal_arp() { ip -n portal neigh show "$PS5" | awk '{for(i=1;i<NF;i++) if($i=="lladdr") print $(i+1)}'; }
cmac() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.MacAddress}}{{end}}' "$1" 2>/dev/null; }
wait_for() { for _ in $(seq 1 "${3:-60}"); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep .5; done; return 1; }
# Redirected = the Portal's entry for the PS5 points at some MAC other than the PS5's.
wait_redirect() {
  for _ in $(seq 1 40); do
    [ -n "$(portal_arp)" ] && [ "$(portal_arp)" != "$PS5_MAC" ] && return 0
    send plain 1 >/dev/null
  done; return 1
}
csum_errors() { ip netns exec ps5 awk '/^Udp:/{if(!h){for(i=1;i<=NF;i++)k[i]=$i;h=1}else for(i=1;i<=NF;i++)if(k[i]=="InCsumErrors")print $i}' /proc/net/snmp; }
send plain 2 >/dev/null

step "docker compose run --rm relay configure 65"
printf 'eth0\n%s\n%s\n' "$PS5" "$PORTAL" | dc run --rm -T relay configure 65 > "$T/configure.out" 2>&1 || true
check "enrolled both devices" 'grep -q "\"ps5_mac\": \"$PS5_MAC\"" data/config/auto-config.json && grep -q "\"portal_mac\": \"$PORTAL_MAC\"" data/config/auto-config.json'
timeout 60 docker compose -f compose.yaml "${EXTRA[@]}" run --rm -T relay service > "$T/nobaseline.out" 2>&1 || true
check "the service refuses to start before a baseline" 'grep -q "no baseline" "$T/nobaseline.out"'

step "docker compose run --rm relay baseline"
dc run --rm -T --name pr-e2e-baseline relay baseline > "$T/baseline.out" 2>&1 &
B=$!
wait_for "$T/baseline.out" "BASELINE READY" && wait_redirect || fail "relay did not redirect the Portal"
send plain 15 > /dev/null
wait "$B" || true
check "baseline receipt written" 'grep -q "\"restored\": true" data/runtime/auto-baseline.json'
check "Portal ARP entry for PS5 repaired" '[ "$(portal_arp)" = "$PS5_MAC" ]'

step "docker compose run --rm relay try, stopped with docker kill -s INT"
CS0=$(csum_errors); : > "$T/ps5.log"
dc run --rm -T --name pr-e2e-try relay try > "$T/try.out" 2>&1 &
B=$!
wait_for "$T/try.out" "AUTO READY" && wait_redirect || fail "relay did not redirect the Portal"
check "Portal now sends to the relay container's MAC" '[ "$(portal_arp)" = "$(cmac pr-e2e-try)" ]'
read -r SENT REPLIES < <(send startup 10)
docker kill -s INT pr-e2e-try >/dev/null
wait "$B" || true
check "summary printed after cleanup" 'grep -q "\"state\": \"stopped\"" "$T/try.out"'
check "one startup packet modified" 'grep -q "\"unique_modified_startups\": 1" "$T/try.out"'
check "PS5 got only modified startup packets" '[ -s "$T/ps5.log" ] && ! grep -q "$SENT" "$T/ps5.log"'
check "no UDP checksum errors at the PS5" '[ "$(csum_errors)" = "$CS0" ]'
check "PS5 replies reached the Portal ($REPLIES/10)" '[ "$REPLIES" -gt 0 ]'
check "Portal ARP entry for PS5 repaired" '[ "$(portal_arp)" = "$PS5_MAC" ]'

step "docker compose up -d (service), healthcheck, down"
dc up -d >/dev/null 2>&1
CID=$(dc ps -q relay)
for _ in $(seq 1 60); do docker logs "$CID" 2>&1 | grep -q "AUTO READY" && break; sleep .5; done
wait_redirect || fail "relay did not redirect the Portal"
send startup 3 >/dev/null
for _ in $(seq 1 90); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = healthy ] && break; sleep 1; done
check "container reports healthy" '[ "$(docker inspect -f "{{.State.Health.Status}}" "$CID")" = healthy ]'
timeout 60 docker compose -f compose.yaml "${EXTRA[@]}" run --rm -T relay status > "$T/second.out" 2>&1 || true
check "a second relay cannot start on the same IP while it runs" 'grep -qi "address already in use" "$T/second.out"'
S0=$(date +%s); dc down -t 60 >/dev/null 2>&1; S1=$(date +%s)
check "down finished inside the grace period ($((S1 - S0)) s)" '[ $((S1 - S0)) -lt 60 ]'
check "Portal ARP entry for PS5 repaired" '[ "$(portal_arp)" = "$PS5_MAC" ]'

step "relay crash inside the running container (SIGKILL), restart policy"
dc up -d >/dev/null 2>&1
CID=$(dc ps -q relay)
for _ in $(seq 1 60); do docker logs "$CID" 2>&1 | grep -q "AUTO READY" && break; sleep .5; done
wait_redirect || fail "relay did not redirect the Portal"
docker exec "$CID" pkill -9 -f 'portal_auto.py run' || true
for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.RestartCount}}' "$CID")" -ge 1 ] && break; sleep 1; done
check "container restarted after the crash" '[ "$(docker inspect -f "{{.RestartCount}}" "$CID")" -ge 1 ]'
check "guardian repaired before the restart" 'grep -q "\"reason\": \"relay_closed\"" data/runtime/recovery.json && grep -q "\"errors\": \[\]" data/runtime/recovery.json'
for _ in $(seq 1 60); do [ "$(docker logs "$CID" 2>&1 | grep -c 'AUTO READY')" -ge 2 ] && break; sleep .5; done
check "relay is running again after the restart" '[ "$(docker logs "$CID" 2>&1 | grep -c "AUTO READY")" -ge 2 ]'
dc down -t 60 >/dev/null 2>&1
check "Portal ARP entry for PS5 repaired after down" '[ "$(portal_arp)" = "$PS5_MAC" ]'

printf '\n'
if [ "$FAILS" = 0 ]; then echo "All checks passed."; else echo "$FAILS check(s) failed."; exit 1; fi
