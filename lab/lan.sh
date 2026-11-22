#!/usr/bin/env bash
# LAB ONLY: a LAN of Docker containers behind a router VM.
#
#   lab/lan.sh up   site-a 10.10.1 1     switch + clients site-a-c1 (10.10.1.11), site-a-c2 (.12), gw 10.10.1.1
#   lab/lan.sh up   site-b 10.10.2 2
#   lab/lan.sh down site-a
#
# The router VMs run in QEMU on macOS and the containers run inside Docker Desktop's VM,
# so there is no shared Ethernet. The "<site>-lan" switch container closes the gap:
#
#   router VM lan NIC ── QEMU dgram (UDP 127.0.0.1:11000+n <-> :12000+n) ── socat tap0 ── br0 ── veth ── client
#
# n is the VM index (1 = site-a, 2 = site-b), matching lab/vm.sh.
# Clients answer on tcp/80 with their hostname, like the nodes in the vrf-overlay lab.
set -euo pipefail
cd "$(dirname "$0")/.."
cmd=$1 site=$2
sw=$site-lan

case $cmd in
  up)
    net=$3 n=$4 count=${5:-2}
    docker image inspect router-lab-switch:local >/dev/null 2>&1 \
      || docker build -q -t router-lab-switch:local lab/lan >/dev/null
    docker run -d --name "$sw" --privileged --pid=host \
      -p 127.0.0.1:$((12000 + n)):$((12000 + n))/udp router-lab-switch:local sh -c "
        ip link add br0 type bridge && ip link set br0 up
        socat UDP4-DATAGRAM:host.docker.internal:$((11000 + n)),bind=:$((12000 + n)) TUN,tun-type=tap,tun-name=tap0,iff-up,iff-no-pi &
        while ! ip link show tap0 >/dev/null 2>&1; do sleep 0.2; done
        ip link set tap0 master br0
        wait" >/dev/null
    for i in $(seq 1 "$count"); do
      c=$site-c$i ip=$net.$((10 + i))
      docker run -d --name "$c" --hostname "$c" --network none --cap-add NET_ADMIN \
        ghcr.io/srl-labs/clab:latest sh -c "
          while ! ip link show eth0 >/dev/null 2>&1; do sleep 0.2; done
          ip addr add $ip/24 dev eth0 && ip link set eth0 up && ip route add default via $net.1
          nc -lk -p 80 -e hostname" >/dev/null
      pid=$(docker inspect -f '{{.State.Pid}}' "$c")
      docker exec "$sw" sh -c "ip link add v-c$i type veth peer name eth0 netns $pid \
        && ip link set v-c$i master br0 && ip link set v-c$i up"
      echo "$c  $ip  gw $net.1"
    done
    ;;
  down)
    docker rm -f "$sw" $(docker ps -aq --filter "name=^$site-c") >/dev/null 2>&1 || true
    echo "$site lan removed"
    ;;
  *) echo "usage: $0 up <site> <net-prefix> <vm-index> [clients] | down <site>" >&2; exit 1 ;;
esac
