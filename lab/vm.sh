#!/usr/bin/env bash
# LAB ONLY: run routers as QEMU/HVF VMs on this Mac, all booted from the same base image.
#
#   lab/vm.sh start site-a 2221 listen=127.0.0.1:10001    (ssh port, wan link socket)
#   lab/vm.sh start site-b 2222 connect=127.0.0.1:10001
#   lab/vm.sh stop site-a        lab/vm.sh destroy site-a  (also deletes its disk)
#
# Each VM gets a copy-on-write disk on top of out/router-base.raw, so the image stays pristine.
# NIC slots match hardware/qemu-virt.nix: 0x3 mgmt (user net + ssh forward), 0x4 wan, 0x5 lan.
# lan is a UDP frame pipe to the Docker LAN from lab/lan.sh (ssh port 2221 -> index 1, 2222 -> 2).
set -euo pipefail
cd "$(dirname "$0")/.."
cmd=$1 name=$2
dir=lab/vms; mkdir -p "$dir"
disk=$dir/$name.qcow2 pid=$dir/$name.pid

case $cmd in
  start)
    port=$3 wan=$4
    command -v qemu-system-aarch64 >/dev/null || { echo "run inside: nix develop" >&2; exit 1; }
    [ -f "$disk" ] || qemu-img create -q -f qcow2 -b "$PWD/out/router-base.raw" -F raw "$disk" 8G
    fw=$(dirname "$(command -v qemu-system-aarch64)")/../share/qemu/edk2-aarch64-code.fd
    id=$(printf '%02x' $((port % 256)))   # unique MACs per VM; wan NICs share a link
    n=$((port - 2220))                    # VM index: lan NIC <-> lab/lan.sh switch on UDP 11000+n / 12000+n
    qemu-system-aarch64 -name "$name" -machine virt,accel=hvf -cpu host -smp 2 -m 1024 \
      -drive if=pflash,format=raw,readonly=on,file="$fw" \
      -drive if=none,id=disk,file="$disk",format=qcow2 -device virtio-blk-pci,drive=disk,addr=0x2 \
      -netdev user,id=mgmt,hostfwd=tcp:127.0.0.1:"$port"-:22 -device virtio-net-pci,netdev=mgmt,addr=0x3,mac=52:54:00:$id:00:01 \
      -netdev socket,id=wan,"$wan" -device virtio-net-pci,netdev=wan,addr=0x4,mac=52:54:00:$id:00:02 \
      -netdev dgram,id=lan,local.type=inet,local.host=127.0.0.1,local.port=$((11000 + n)),remote.type=inet,remote.host=127.0.0.1,remote.port=$((12000 + n)) \
      -device virtio-net-pci,netdev=lan,addr=0x5,mac=52:54:00:$id:00:03 \
      -display none -serial file:"$dir/$name.console" -daemonize -pidfile "$pid"
    echo "$name started (console: $dir/$name.console, ssh: -F lab/ssh_config root@$name)"
    ;;
  stop)    [ -f "$pid" ] && kill "$(cat "$pid")" && rm -f "$pid"; echo "$name stopped" ;;
  destroy) "$0" stop "$name" || true; rm -f "$disk" "$dir/$name.console"; echo "$name destroyed" ;;
  *) echo "usage: $0 start|stop|destroy <name> [ssh-port wan-socket-opts]" >&2; exit 1 ;;
esac
