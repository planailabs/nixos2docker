# build-docker-image.nix
#
# NixOS module that adds `config.system.build.dockerImage` to every
# NixOS configuration, following the same pattern as build-vm.nix.
#
# The Docker/systemd container tweaks are applied via `extendModules`
# so they ONLY affect the image — your base config stays untouched.
#
# Usage:
#   # flake.nix
#   nixosConfigurations.myHost = lib.nixosSystem {
#     modules = [
#       ./build-docker-image.nix
#       ./configuration.nix
#     ];
#   };
#
#   # Build:
#   nix build .#nixosConfigurations.myHost.config.system.build.dockerImage
#   docker load < result
#
#   # Run:
#   docker run -d --name nixos \
#     --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
#     --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
#     --stop-signal SIGRTMIN+3 \
#     --cap-add SYS_ADMIN \
#     nixos-docker:latest
#
#   # You can also push extra config into the variant without touching
#   # your base system:
#   virtualisation.dockerVariant = {
#     services.openssh.enable = true;
#     environment.systemPackages = [ pkgs.htop ];
#   };
#
{ config, extendModules, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkDefault;

  # ── Create the Docker variant via extendModules ────────────────────
  # This is exactly analogous to how build-vm.nix creates vmVariant.
  # The base NixOS config is inherited; we layer on the container
  # module which applies all the systemd tweaks + builds the image.
  dockerVariant = extendModules {
    modules = [ ./docker-container.nix ];
  };

in
{
  options = {
    virtualisation.dockerVariant = mkOption {
      description = ''
        Machine configuration to be added for the Docker image produced
        by `config.system.build.dockerImage`.

        Any NixOS options set here apply only to the Docker image, not
        to the base system. For example:

            virtualisation.dockerVariant = {
              services.nginx.enable = true;
            };
      '';
      inherit (dockerVariant) type;
      default = { };
      visible = "shallow";
    };

    virtualisation.dockerImage = {
      name = mkOption {
        type = lib.types.str;
        default = config.networking.hostName or "nixos-docker";
        description = "Name of the Docker image.";
      };

      tag = mkOption {
        type = lib.types.str;
        default = "latest";
        description = "Tag of the Docker image.";
      };

      maxLayers = mkOption {
        type = lib.types.int;
        default = 125;
        description = "Maximum number of Docker image layers.";
      };

      extraContents = mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = "Additional store paths to include in the image.";
      };
    };
  };

  config = {
    # ── Wire system.build.dockerImage to the variant's output ────────
    system.build.dockerImage =
      mkDefault config.virtualisation.dockerVariant.system.build.dockerImage;

    # ── Prevent infinite nesting ─────────────────────────────────────
    virtualisation.dockerVariant = {
      options = {
        virtualisation.dockerVariant = lib.mkOption {
          apply = _: throw "virtualisation.dockerVariant.virtualisation.dockerVariant is not supported";
        };
      };
    };
  };

  # extendModules can't be evaluated in the docs sandbox
  meta.buildDocsInSandbox = false;
}
