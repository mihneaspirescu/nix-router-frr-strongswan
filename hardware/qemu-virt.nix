# Port map for one hardware model: which physical slot is which port.
# Like the labels on an appliance chassis, this belongs to the hardware, not the site,
# so it is in the base image and never needs a reboot to change names.
# A physical box gets its own file here (e.g. hardware/apu6.nix) with its PCI paths.
#   QEMU: -device virtio-net-pci,addr=0x3 -> mgmt, addr=0x4 -> wan, addr=0x5 -> lan
# Matched on udev's bus-position name (what the NIC would otherwise be called), which is
# stable per slot on a given hardware model. Find it on new hardware with:
#   udevadm info /sys/class/net/<if> | grep ID_NET_NAME_PATH
let
  port = path: name: { matchConfig.Property = "ID_NET_NAME_PATH=${path}"; linkConfig.Name = name; };
  links = {
    "10-mgmt" = port "enp0s3" "mgmt";
    "10-wan" = port "enp0s4" "wan";
    "10-lan" = port "enp0s5" "lan";
  };
in
{
  systemd.network.links = links;
  # The initrd brings NICs up first; give it the same names so stage 2 never has to rename.
  boot.initrd.systemd.network.links = links;
}
