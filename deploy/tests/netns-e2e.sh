#!/usr/bin/env bash
# netns-e2e.sh - end-to-end test of the relay with a fake PS5 and Portal.
#
# Builds three network namespaces (ps5, portal, relay) on one Linux bridge - the same
# layer-2 shape as an LXC on vmbr0 or a macvlan container - and drives the installed
# 'portal' helper through configure, baseline, try (Ctrl+C), service (SIGTERM) and a
# relay crash (SIGKILL). Needs root, iproute2, ethtool, python3, and the relay installed
# (deploy/install-alpine.sh). Run: sudo bash deploy/tests/netns-e2e.sh
# shellcheck disable=SC2034  # several variables are only read inside check()'s eval strings
set -euo pipefail

APP=/opt/portal-bitrate-auto
RT=/var/lib/portal-bitrate-auto
CFG=/etc/portal-bitrate/auto-config.json
PY=$APP/.venv/bin/python
PS5=10.77.0.10 PORTAL=10.77.0.20 RELAY=10.77.0.5
PS5_MAC=02:77:00:00:00:02 PORTAL_MAC=02:77:00:00:00:03 RELAY_MAC=02:77:00:00:00:01
T=$(mktemp -d)
FAILS=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

cleanup() {
  local rc=$?
  for n in ps5 portal relay; do
    for p in $(ip netns pids "$n" 2>/dev/null); do kill -9 "$p" 2>/dev/null || true; done
    ip netns del "$n" 2>/dev/null || true
  done
  if [ -n "${IPT_RULE:-}" ]; then iptables -D FORWARD -i br-e2e -o br-e2e -j ACCEPT 2>/dev/null || true; fi
  ip link del br-e2e 2>/dev/null || true
  if [ "$FAILS" = 0 ] && [ "$rc" = 0 ]; then rm -rf "$T"; else echo "logs kept in $T"; fi
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -x "$PY" ] && command -v portal >/dev/null || { echo "install the relay first (install-alpine.sh)"; exit 1; }
rm -rf "$RT" "$(dirname "$CFG")"; rm -f /run/portal-lab-capture.lock

step "Network: bridge + fake PS5, fake Portal, relay"
FWD_WAS=$(cat /proc/sys/net/ipv4/ip_forward)
echo 1 > /proc/sys/net/ipv4/ip_forward      # like a PVE/Docker host with forwarding on
ip link add br-e2e type bridge && ip link set br-e2e up
# With Docker running (GitHub runners, many hosts), br_netfilter sends bridged IPv4
# through iptables FORWARD, whose policy Docker sets to DROP. ARP still crosses the
# bridge, so the Portal gets redirected but its traffic never reaches the relay.
if [ "$(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null)" = 1 ] && command -v iptables >/dev/null; then
  iptables -I FORWARD -i br-e2e -o br-e2e -j ACCEPT && IPT_RULE=1
fi
mk() {
  ip netns add "$1"; ip link add "v-$1" type veth peer name eth0 netns "$1"
  ip link set "v-$1" master br-e2e up
  ip -n "$1" link set lo up; ip -n "$1" link set eth0 address "$2" up
  ip -n "$1" addr add "$3/24" dev eth0
}
mk ps5 "$PS5_MAC" "$PS5"; mk portal "$PORTAL_MAC" "$PORTAL"; mk relay "$RELAY_MAC" "$RELAY"
echo "$FWD_WAS" > /proc/sys/net/ipv4/ip_forward
# veth leaves UDP checksums for "hardware" to finish; a real Portal's frames arrive complete.
ip netns exec portal ethtool -K eth0 tx off >/dev/null
check "relay namespace inherited ip_forward=1 (the case the helper must fix)" \
  '[ "$(ip netns exec relay cat /proc/sys/net/ipv4/ip_forward)" = 1 ]'

cat > "$T/ps5.py" <<'EOF'
import hashlib, socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind((sys.argv[1], 9296))
log = open(sys.argv[2], 'a', buffering=1)
while True:
    d, a = s.recvfrom(4096)
    log.write(hashlib.sha256(d).hexdigest()[:12] + '\n'); s.sendto(b'video' * 200, a)
EOF
cat > "$T/portal.py" <<'EOF'
import hashlib, socket, sys, time
sys.path.insert(0, '/opt/portal-bitrate-auto/tests'); sys.path.insert(0, '/opt/portal-bitrate-auto')
from test_probe import fixture
p = fixture()[0] if sys.argv[1] == 'startup' else b'controller-input'
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
send() { ip netns exec portal "$PY" "$T/portal.py" "$1" "$2" "$PORTAL" "$PS5"; }
portal_arp() { ip -n portal neigh show "$PS5" | awk '{for(i=1;i<NF;i++) if($i=="lladdr") print $(i+1)}'; }
csum_errors() { ip netns exec ps5 awk '/^Udp:/{if(!h){for(i=1;i<=NF;i++)k[i]=$i;h=1}else for(i=1;i<=NF;i++)if(k[i]=="InCsumErrors")print $i}' /proc/net/snmp; }
wait_ready() { for _ in $(seq 1 30); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep .5; done; return 1; }
guardians() { pgrep -f 'portal_auto.py guardian' | wc -l; }
# Linux only accepts the relay's unsolicited ARP replies after its lock time, so a fake
# Portal takes a few seconds to switch; a real Portal reconnects after READY anyway.
wait_redirect() { for _ in $(seq 1 40); do [ "$(portal_arp)" = "$RELAY_MAC" ] && return 0; send plain 1 >/dev/null; done; return 1; }
send plain 2 >/dev/null   # give the Portal a neighbor entry for the PS5

step "portal configure 65"
printf 'eth0\n%s\n%s\n' "$PS5" "$PORTAL" | ip netns exec relay portal configure 65 > "$T/configure.out" 2>&1 || true
check "enrolled both devices" 'grep -q "\"ps5_mac\": \"$PS5_MAC\"" "$CFG" && grep -q "\"portal_mac\": \"$PORTAL_MAC\"" "$CFG"'
check "helper turned the inherited forwarding off" '[ "$(ip netns exec relay cat /proc/sys/net/ipv4/ip_forward)" = 0 ]'
check "try is refused before a baseline" '! ip netns exec relay portal try >/dev/null 2>&1'

step "portal baseline (60 s)"
ip netns exec relay portal baseline > "$T/baseline.out" 2>&1 &
B=$!
wait_ready "$T/baseline.out" "BASELINE READY" && wait_redirect || fail "relay did not redirect the Portal"
send plain 20 > "$T/send-baseline.out"
wait "$B" || true
check "baseline receipt written" 'grep -q "\"restored\": true" "$RT/auto-baseline.json"'
check "Portal->PS5 traffic was relayed" '[ "$(sed -n "s/.*\"forwarded_out\": \([0-9]*\).*/\1/p" "$RT/auto-baseline.json")" -gt 0 ]'
check "Portal ARP entry for PS5 repaired" '[ "$(portal_arp)" = "$PS5_MAC" ]'

step "portal try + Ctrl+C (SIGINT to the terminal's process group)"
CS0=$(csum_errors); : > "$T/ps5.log"
setsid -f sh -c "echo \$\$ > '$T/try.pgid'; exec ip netns exec relay portal try > '$T/try.out' 2>&1"
wait_ready "$T/try.out" "AUTO READY" && wait_redirect || fail "relay did not redirect the Portal"
check "Portal now sends to the relay's MAC" '[ "$(portal_arp)" = "$RELAY_MAC" ]'
read -r SENT REPLIES < <(send startup 10)
kill -INT -- "-$(cat "$T/try.pgid")"
for _ in $(seq 1 60); do kill -0 "$(cat "$T/try.pgid")" 2>/dev/null || break; sleep .5; done
check "helper waited for cleanup and printed the summary" 'grep -q "\"state\": \"stopped\"" "$T/try.out"'
check "one startup packet modified" 'grep -q "\"unique_modified_startups\": 1" "$RT/status.json"'
check "PS5 got only modified startup packets ($(wc -l < "$T/ps5.log") received)" '[ -s "$T/ps5.log" ] && ! grep -q "$SENT" "$T/ps5.log"'
check "no UDP checksum errors at the PS5" '[ "$(csum_errors)" = "$CS0" ]'
check "PS5 replies reached the Portal ($REPLIES/10, direct path)" '[ "$REPLIES" -gt 0 ]'
check "Portal ARP entry for PS5 repaired" '[ "$(portal_arp)" = "$PS5_MAC" ]'
check "no guardian left, lock released" '[ "$(guardians)" = 0 ] && [ ! -e /run/portal-lab-capture.lock ]'

step "portal service + SIGTERM to the helper only (supervise-daemon / Docker init)"
ip netns exec relay portal service > "$T/service.out" 2>&1 &
S=$!
wait_ready "$T/service.out" "AUTO READY" && wait_redirect || fail "relay did not redirect the Portal"
kill -TERM "$S"   # $S is the helper shell: ip netns exec execs straight into it
RC=0; wait "$S" || RC=$?
check "service exited cleanly (rc=$RC)" '[ "$RC" = 0 ]'
check "Portal ARP entry for PS5 repaired" '[ "$(portal_arp)" = "$PS5_MAC" ]'
check "no guardian left, lock released" '[ "$(guardians)" = 0 ] && [ ! -e /run/portal-lab-capture.lock ]'

step "portal service + relay crash (SIGKILL to the Python relay)"
ip netns exec relay portal service > "$T/crash.out" 2>&1 &
S=$!
wait_ready "$T/crash.out" "AUTO READY" && wait_redirect || fail "relay did not redirect the Portal"
check "Portal redirected to the relay" '[ "$(portal_arp)" = "$RELAY_MAC" ]'
kill -9 "$(pgrep -f 'portal_auto.py run' | head -1)"
RC=0; wait "$S" || RC=$?
check "helper reported the crash (rc=$RC)" '[ "$RC" != 0 ]'
check "guardian repaired after the crash" 'grep -q "\"reason\": \"relay_closed\"" "$RT/recovery.json" && grep -q "\"errors\": \[\]" "$RT/recovery.json"'
check "Portal ARP entry for PS5 repaired" '[ "$(portal_arp)" = "$PS5_MAC" ]'
check "no recovery-required marker" '[ ! -e "$RT/recovery-required" ]'

printf '\n'
if [ "$FAILS" = 0 ]; then echo "All checks passed."; else echo "$FAILS check(s) failed."; exit 1; fi
