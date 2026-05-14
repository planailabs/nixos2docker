# docker-container.nix
#
# The container-side module, analogous to qemu-vm.nix.
# This is NOT imported directly — build-docker-image.nix injects it
# into the Docker variant via extendModules. All config here only
# affects config.system.build.dockerImage, never the base system.
#

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkForce mkDefault;

  # Read image settings from the *base* config (passed through by extendModules).
  # These options are declared in build-docker-image.nix.
  imgCfg = config.virtualisation.dockerImage;
  toplevel = config.system.build.toplevel;

in
{
  # ════════════════════════════════════════════════════════════════════
  #  systemd / container tweaks — only exist inside the variant
  # ════════════════════════════════════════════════════════════════════

  # ── Boot ─────────────────────────────────────────────────────────
  boot.isContainer = true;
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = mkForce false;
  boot.tmp.useTmpfs = true;

  # ── Filesystem ───────────────────────────────────────────────────
  fileSystems."/" = mkForce {
    device = "none";
    fsType = "tmpfs";
  };

  # ── Security ─────────────────────────────────────────────────────
  security.audit.enable = false;

  # ── Environment ──────────────────────────────────────────────────
  environment.variables.container = "docker";

  environment.etc."machine-id" = {
    text = "00000000000000000000000000000000\n";
    mode = "0444";
  };

  # ── systemd ──────────────────────────────────────────────────────
  systemd.defaultUnit = "multi-user.target";
  systemd.enableEmergencyMode = false;

  # ── Journald ─────────────────────────────────────────────────────
  services.journald.extraConfig = ''
    Storage=volatile
    ForwardToConsole=yes
    MaxLevelConsole=info
  '';

  # ── Networking ───────────────────────────────────────────────────
  # Docker handles networking; disable the NixOS networking stack.
  networking.useDHCP = mkForce false;
  networking.useNetworkd = mkForce false;
  networking.firewall.enable = mkForce false;
  networking.hosts = mkForce {
    "127.0.0.1" = [ "localhost" ];
    "::1"       = [ "localhost" ];
  };

  # ── Root user (sensible default for containers) ──────────────────
  users.users.root.initialHashedPassword = mkDefault "";

  # ── Masked services ──────────────────────────────────────────────
  systemd.services = let
    mkMasked = name: lib.nameValuePair name {
      enable = mkForce false;
      wantedBy = mkForce [ ];
      requiredBy = mkForce [ ];
    };
  in builtins.listToAttrs (map mkMasked [
    # Hardware / device management
    "systemd-udevd"
    "systemd-modules-load"
    "systemd-sysctl"
    "systemd-random-seed"
    "systemd-rfkill"
    "systemd-hibernate-resume"
    "systemd-tmpfiles-setup-dev"

    # Networking (Docker manages this)
    "systemd-networkd"
    "systemd-networkd-wait-online"
    "systemd-resolved"
    "systemd-timesyncd"
    "firewall"
    "network-setup"

    # Filesystem / mount daemons
    "systemd-remount-fs"

    # Console / login / seat management
    "systemd-logind"
    "systemd-vconsole-setup"
    "getty@tty1"
    "serial-getty@ttyS0"

    # Misc
    "systemd-update-utmp"
    "systemd-update-utmp-runlevel"
    "systemd-machine-id-commit"
    "systemd-ask-password-wall"
  ]);

  # ── Masked sockets ──────────────────────────────────────────────
  systemd.sockets = let
    mkMasked = name: lib.nameValuePair name {
      enable = mkForce false;
      wantedBy = mkForce [ ];
    };
  in builtins.listToAttrs (map mkMasked [
    "systemd-udevd-control"
    "systemd-udevd-kernel"
    "systemd-journald-audit"
  ]);

  # ── Masked targets ──────────────────────────────────────────────
  systemd.targets = let
    mkMasked = name: lib.nameValuePair name {
      enable = mkForce false;
      wantedBy = mkForce [ ];
    };
  in builtins.listToAttrs (map mkMasked [
    "sound"
    "bluetooth"
    "swap"
    "hibernate"
    "sleep"
    "suspend"
  ]);

  # ════════════════════════════════════════════════════════════════════
  #  The Docker image derivation
  # ════════════════════════════════════════════════════════════════════

  system.build.dockerImage = pkgs.dockerTools.buildLayeredImage {
    name     = imgCfg.name;
    tag      = imgCfg.tag;
    maxLayers = imgCfg.maxLayers;

    contents = [
      toplevel
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.procps
      pkgs.util-linux
      pkgs.less
    ] ++ imgCfg.extraContents;

    fakeRootCommands = ''
      # ── Nix profiles ──────────────────────────────────────────
      mkdir -p nix/var/nix/profiles nix/var/nix/gcroots
      ln -s ${toplevel} nix/var/nix/profiles/system
      ln -s ${toplevel} nix/var/nix/gcroots/current-system

      # ── Init ──────────────────────────────────────────────────
      mkdir -p sbin
      ln -sf ${toplevel}/init sbin/init

      # ── Directory structure ───────────────────────────────────
      # etc may be a symlink into the read-only nix store from
      # contents; replace it with a real writable directory.
      if [ -L etc ] || [ -e etc ]; then
        rm -rf etc
      fi
      mkdir -p etc run var tmp proc sys dev
      mkdir -p var/log/journal var/lib

      # ── /etc overlay from NixOS ───────────────────────────────
      ln -s ${config.system.build.etc}/etc etc/static

      # ── Baseline passwd/group ─────────────────────────────────
      if [ ! -f etc/passwd ]; then
        echo 'root:x:0:0:root:/root:/bin/bash' > etc/passwd
        echo 'nobody:x:65534:65534:nobody:/var/empty:/run/current-system/sw/bin/nologin' >> etc/passwd
      fi
      if [ ! -f etc/group ]; then
        echo 'root:x:0:' > etc/group
        echo 'nogroup:x:65534:' >> etc/group
      fi

      # ── os-release ────────────────────────────────────────────
      cat > etc/os-release <<'EOF'
NAME="NixOS (Docker)"
ID=nixos
PRETTY_NAME="NixOS (Docker Container)"
HOME_URL="https://nixos.org"
EOF

      # ── machine-id ────────────────────────────────────────────
      echo "00000000000000000000000000000000" > etc/machine-id
    '';

    config = {
      Cmd = [ "${toplevel}/init" ];
      Env = [
        "PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/bin:/bin"
        "container=docker"
      ];
      Volumes = {
        "/sys/fs/cgroup" = { };
        "/run"           = { };
        "/run/lock"      = { };
        "/tmp"           = { };
      };
      StopSignal = "SIGRTMIN+3";
      Labels = {
        "org.nixos.systemd-container" = "true";
      };
    };
  };
}
