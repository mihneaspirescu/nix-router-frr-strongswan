#!/usr/bin/env bash
# LAB ONLY: end-to-end checks with Docker clients behind both routers.
# Needs: both VMs up (lab/vm.sh), sites pushed (./deploy.sh), LANs up (lab/lan.sh).
#
#   lab/test.sh            reachability, encryption on the wire, isolation, fail-closed
#   lab/test.sh --reboot   also reboot site-a and check it comes back on its pushed config
set -uo pipefail
cd "$(dirname "$0")/.."

r() { ssh -F lab/ssh_config -o ConnectTimeout=5 "$@"; }
c() { docker exec "$@"; }
pass=0 fail=0
check() { # check <description> <command...>
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $d"; pass=$((pass + 1)); else echo "FAIL  $d"; fail=$((fail + 1)); fi
}
refute() { # refute <description> <command...>: passes when the command fails
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL  $d"; fail=$((fail + 1)); else echo "PASS  $d"; pass=$((pass + 1)); fi
}
app() { [ "$(c "$1" nc -w 3 "$2" 80 </dev/null 2>/dev/null)" = "$3" ]; } # app <from> <ip> <expected hostname>
wait_bgp() { for _ in $(seq 1 40); do r site-a 'ip route show vrf red | grep -q "10.10.2.0/24.*bgp"' && r site-b 'ip route show vrf red | grep -q "10.10.1.0/24.*bgp"' && return 0; sleep 1; done; return 1; }

echo "== reachability across the tunnel"
check "BGP routes present on both routers" wait_bgp
check "site-a-c1 -> site-b-c1 ping"            c site-a-c1 ping -c 3 -W 2 10.10.2.11
check "site-a-c2 -> site-b-c2 ping"            c site-a-c2 ping -c 3 -W 2 10.10.2.12
check "site-b-c1 -> site-a-c2 ping"            c site-b-c1 ping -c 3 -W 2 10.10.1.12
check "site-a-c1 -> site-b-c1:80 app reply"    app site-a-c1 10.10.2.11 site-b-c1
check "site-b-c2 -> site-a-c1:80 app reply"    app site-b-c2 10.10.1.11 site-a-c1

echo "== on the wire (capture on site-b wan while clients talk)"
r site-b 'rm -f /tmp/wan.txt; (timeout 8 tcpdump -lni wan -A not arp >/tmp/wan.txt 2>/dev/null &)'
sleep 1
for _ in 1 2 3; do app site-a-c1 10.10.2.11 site-b-c1; app site-b-c1 10.10.1.11 site-a-c1; done
c site-a-c2 ping -c 5 -i 0.3 10.10.2.12 >/dev/null
sleep 8
esp=$(r site-b 'grep -c ": ESP(" /tmp/wan.txt')
echo "      ESP packets seen on wan: $esp"
check "wan carried ESP"                        test "$esp" -gt 0
refute "no client address on wan (10.10.x)"    r site-b 'grep -q "10\.10\." /tmp/wan.txt'
refute "no app payload on wan (hostnames)"     r site-b 'grep -q "site-[ab]-c" /tmp/wan.txt'

echo "== isolation (red clients must not reach black/mgmt or the internet)"
refute "site-a-c1 -> remote wan 192.0.2.2"     c site-a-c1 ping -c 2 -W 1 192.0.2.2
refute "site-a-c1 -> own router wan 192.0.2.1" c site-a-c1 ping -c 2 -W 1 192.0.2.1
refute "site-a-c1 -> router mgmt 10.0.2.15"    c site-a-c1 ping -c 2 -W 1 10.0.2.15
refute "site-a-c1 -> internet 1.1.1.1"         c site-a-c1 ping -c 2 -W 1 1.1.1.1
refute "site-a-c1 -> router ssh on lan"        c site-a-c1 nc -w 2 10.10.1.1 22

echo "== fail-closed: stop IPsec on site-a while site-a-c1 keeps pinging"
r site-b 'rm -f /tmp/wan2.txt; (timeout 30 tcpdump -lni wan -A not arp >/tmp/wan2.txt 2>/dev/null &)'
c site-a-c1 sh -c 'ping -i 0.5 -c 50 -W 1 10.10.2.11 > /tmp/fc.txt 2>&1 &'
sleep 4
r site-a systemctl stop strongswan-swanctl
sleep 15                                          # covers the 9 s BGP hold time window
check "remote routes withdrawn on site-a"      r site-a '! ip route show vrf red | grep -q bgp'
refute "client cannot reach remote while down" c site-a-c1 ping -c 2 -W 1 10.10.2.11
sleep 12
refute "no client address on wan during outage" r site-b 'grep -q "10\.10\." /tmp/wan2.txt'
echo "      pings answered before/while down: $(c site-a-c1 grep -c 'bytes from' /tmp/fc.txt) of 50"

echo "== recovery"
r site-a systemctl start strongswan-swanctl
check "BGP routes back"                        wait_bgp
check "site-a-c1 -> site-b-c1 app reply again" app site-a-c1 10.10.2.11 site-b-c1

if [ "${1:-}" = "--reboot" ]; then
  echo "== reboot site-a: does it come back on the pushed generation?"
  before=$(r site-a readlink -f /run/current-system)
  r site-a systemctl reboot || true
  sleep 10
  for _ in $(seq 1 60); do r site-a true 2>/dev/null && break; sleep 2; done
  after=$(r site-a readlink -f /run/current-system)
  check "same system after reboot"             test "$before" = "$after"
  check "hostname is site-a after reboot"      test "$(r site-a hostname)" = site-a
  check "BGP routes back after reboot"         wait_bgp
  check "site-a-c1 -> site-b-c1 app after reboot" app site-a-c1 10.10.2.11 site-b-c1
fi

echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
