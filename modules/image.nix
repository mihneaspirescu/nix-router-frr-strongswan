# Turns the base config into a bootable UEFI disk image with systemd-repart.
# No VM or KVM needed at build time, so it builds in a plain (privileged) Docker container.
# Only the base image uses this; sites are pushed to running machines instead.
{ config, lib, pkgs, modulesPath, ... }:
let
  efiArch = pkgs.stdenv.hostPlatform.efiArch;
  closure = pkgs.closureInfo { rootPaths = [ config.system.build.toplevel ]; };
in
{
  imports = [ "${modulesPath}/image/repart.nix" ];

  image.repart = {
    enable = true;
    name = "router-base";
    partitions = {
      "10-esp" = {
        # Factory entry: a UKI systemd-boot finds on its own. Later generations are added
        # next to it by nixos-rebuild, so the factory entry stays as a last-resort fallback.
        contents = {
          "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
            "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";
          "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
            "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";
          "/loader/loader.conf".source = pkgs.writeText "loader.conf" "timeout 3\n";
        };
        repartConfig = { Type = "esp"; Format = "vfat"; Label = "ESP"; SizeMinBytes = "512M"; };
      };
      "20-root" = {
        storePaths = [ config.system.build.toplevel ];
        contents."/nix-path-registration".source = "${closure}/registration";
        repartConfig = { Type = "root"; Format = "ext4"; Label = "nixos"; Minimize = "guess"; };
      };
    };
  };
}
