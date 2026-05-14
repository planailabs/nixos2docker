{
  description = "NixOS module: build Docker images from any NixOS config (systemd as PID 1)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
  let
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in
  {
    # ── The NixOS module — the main thing people consume ─────────────
    nixosModules = {
      docker-image = ./build-docker-image.nix;
      default = self.nixosModules.docker-image;
    };

    # ── Example: a minimal NixOS system with the module applied ──────
    # Build with:
    #   nix build .#nixosConfigurations.example.config.system.build.dockerImage
    nixosConfigurations = forAllSystems (system:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.default
          ({ pkgs, ... }: {
            # ── Image metadata ──────────────────────────────────────
            virtualisation.dockerImage.name = "nixos-example";
            virtualisation.dockerImage.tag = "latest";

            # ── Your services ───────────────────────────────────────
            # These are part of the base config and will be inherited
            # by the Docker variant automatically.
            services.openssh.enable = true;
            services.openssh.settings.PermitRootLogin = "yes";

            environment.systemPackages = with pkgs; [
              vim
              curl
              htop
            ];

            # ── Docker-only overrides (optional) ────────────────────
            # Anything here affects only the Docker image.
            # virtualisation.dockerVariant = {
            #   services.nginx.enable = true;
            # };

            system.stateVersion = "24.11";
          })
        ];
      }
    );

    # ── Convenience: expose the image as a package ───────────────────
    packages = forAllSystems (system: {
      dockerImage =
        self.nixosConfigurations.${system}.config.system.build.dockerImage;
      default =
        self.packages.${system}.dockerImage;
    });
  };
}
