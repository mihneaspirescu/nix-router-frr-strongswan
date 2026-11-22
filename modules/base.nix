# What every appliance has, before and after it gets a site config:
# OS, bootloader with generations (rollback), mgmt on DHCP, SSH for nixos-rebuild.
{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [
    "${modulesPath}/profiles/minimal.nix"
    "${modulesPath}/profiles/qemu-guest.nix"
  ];

  options.appliance.adminKeys = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    description = "SSH public keys allowed to log in as root (used by nixos-rebuild --target-host).";
  };

  config = {
    networking.hostName = lib.mkDefault "router-unprovisioned";
    system.stateVersion = "25.11";

    # ---------- boot: systemd-boot keeps one entry per generation ----------
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = true;
    boot.loader.systemd-boot.configurationLimit = 5; # boot menu / ESP: last 5 generations
    boot.loader.efi.canTouchEfiVariables = false;
    boot.kernelParams = [ "console=ttyAMA0" "console=tty0" ];

    fileSystems."/" = { device = "/dev/disk/by-partlabel/nixos"; fsType = "ext4"; autoResize = true; };
    fileSystems."/boot" = { device = "/dev/disk/by-partlabel/ESP"; fsType = "vfat"; options = [ "umask=0077" ]; };

    # Grow the root partition to the disk size on first boot (the image ships minimal).
    boot.initrd.systemd.repart.enable = true;
    systemd.repart.partitions."20-root".Type = "root";

    # The image ships a store Nix doesn't know about yet; register it once so pushes work.
    systemd.services.nix-load-db = {
      description = "Register the image's store paths with Nix";
      wantedBy = [ "sysinit.target" ];
      after = [ "local-fs.target" ];
      before = [ "sysinit.target" "nix-daemon.socket" "nix-daemon.service" ];
      unitConfig = { DefaultDependencies = false; ConditionPathExists = "/nix-path-registration"; };
      serviceConfig.Type = "oneshot";
      script = ''
        ${config.nix.package}/bin/nix-store --load-db < /nix-path-registration
        rm /nix-path-registration
      '';
    };

    # ---------- store housekeeping: keep the disk from filling with old generations ----------
    # Weekly: drop generations older than 30 days (the running one is always kept), then
    # delete whatever they alone referenced. 30 days is the rollback window via `--rollback`.
    nix.gc = {
      automatic = true;
      dates = "weekly";
      randomizedDelaySec = "1h"; # don't GC the whole fleet in the same minute
      persistent = true;         # catch up after downtime
      options = "--delete-older-than 30d";
    };
    # Safety net between weekly runs: if a push/build drops free space below 1 GiB,
    # Nix garbage-collects until 3 GiB is free.
    nix.settings = {
      min-free = 1024 * 1024 * 1024;
      max-free = 3 * 1024 * 1024 * 1024;
    };
    # Hard-link identical files across generations (kernels/firmware rarely change).
    nix.optimise = { automatic = true; dates = [ "weekly" ]; };

    # ---------- management: DHCP, SSH only here ----------
    networking.useNetworkd = true;
    networking.useDHCP = false;
    systemd.network.enable = true;
    systemd.network.networks."10-mgmt" = {
      matchConfig.Name = "mgmt";
      networkConfig.DHCP = "ipv4";
    };
    systemd.network.wait-online.extraArgs = [ "--interface=mgmt" ];

    services.openssh = {
      enable = true;
      openFirewall = false;
      settings = { PasswordAuthentication = false; PermitRootLogin = "prohibit-password"; };
    };
    users.mutableUsers = false;
    users.users.root.openssh.authorizedKeys.keys = config.appliance.adminKeys;

    networking.nftables.enable = true;
    networking.firewall.enable = true;
    networking.firewall.interfaces.mgmt.allowedTCPPorts = [ 22 ];

    documentation.enable = false;
  };
}
