{
  description = "NixOS router appliances: one base image, per-site configs pushed live with nixos-rebuild";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      system = "aarch64-linux";

      # Layers every appliance shares: the OS, the hardware port map, admin access.
      common = [
        ./modules/base.nix
        ./hardware/qemu-virt.nix
        { appliance.adminKeys = [ (builtins.readFile ./keys/lab-admin.pub) ]; }
      ];

      # Every sites/<name>.nix becomes nixosConfigurations.<name>.
      siteNames = map (lib.removeSuffix ".nix")
        (builtins.filter (lib.hasSuffix ".nix") (builtins.attrNames (builtins.readDir ./sites)));

      mkSite = name: lib.nixosSystem {
        inherit system;
        modules = common ++ [ ./modules/router.nix ./sites/${name}.nix ];
      };

      darwinPkgs = nixpkgs.legacyPackages.aarch64-darwin;
    in
    {
      nixosConfigurations = lib.genAttrs siteNames mkSite // {
        # The generic image: boots anywhere, comes up on mgmt with DHCP + SSH, nothing site-specific.
        base = lib.nixosSystem {
          inherit system;
          modules = common ++ [ ./modules/image.nix ];
        };
      };

      # nix build .#base-image  -> the one image you flash/boot everywhere
      packages.${system}.base-image = self.nixosConfigurations.base.config.system.build.image;

      # Tools for the Mac side: nixos-rebuild (deploys) and qemu (lab VMs), pinned to this flake's nixpkgs.
      devShells.aarch64-darwin.default = darwinPkgs.mkShell {
        packages = [ darwinPkgs.nixos-rebuild darwinPkgs.qemu ];
      };
    };
}
