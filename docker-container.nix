# docker-container.nix
#
# The container-side module, analogous to qemu-vm.nix.
# This is NOT imported directly — build-docker-image.nix injects it
# into the Docker variant via extendModules. All config here only
# affects config.system.build.dockerImage, never the base system.
#
# The image runs with ZERO extra capabilities — no --privileged,
# no --cap-add SYS_ADMIN.  The approach mirrors how Incus (LXC)
# runs unprivileged system containers: rely on cgroup namespaces
# for delegation, set $container so systemd auto-detects its
# environment, and disable everything that would need CAP_SYS_ADMIN.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkForce mkDefault;

  imgCfg = config.virtualisation.dockerImage;
  toplevel = config.system.build.toplevel;

in
{
  # ════════════════════════════════════════════════════════════════════
  #  Patch systemd: gracefully degrade on read-only cgroup filesystem
  # ════════════════════════════════════════════════════════════════════

  systemd.package = pkgs.systemd.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      ./0001-mount-setup-skip-writable-check-in-containers.patch
      ./0002-cgroup-skip-cgroup-creation-in-containers-with-ro-fs.patch
      ./0003-main-keep-console-logging-in-containers.patch
      ./0004-exec-invoke-skip-cgroup-quotas-when-cgroup-path-null.patch
      ./0005-manager-SIGTERM-triggers-poweroff-in-containers.patch
      ./0006-log-fall-back-to-stderr-when-console-is-missing.patch
    ];
  });

  # ════════════════════════════════════════════════════════════════════
  #  Core container identity
  # ════════════════════════════════════════════════════════════════════

  # boot.isContainer = true activates container-config.nix which
  # disables: kernel, modprobe, console, udev, lvm, audit.
  boot.isContainer = true;
  boot.initrd.systemd.enable = true;

  # Tell NixOS that /proc, /run, /dev, /dev/shm, /dev/pts are
  # already provided by Docker — do not attempt to mount them.
  # (Without this, the specialfs activation script tries to mount
  # them and fails without CAP_SYS_ADMIN.)
  boot.specialFileSystems = mkForce { };

  # Do not attempt to bind-mount /nix/store with ro/nosuid/nodev
  # options — the remount requires CAP_SYS_ADMIN.  The store is
  # already immutable inside the image layers.
  boot.nixStoreMountOpts = [ ];

  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = mkForce false;
  boot.tmp.useTmpfs = true;

  # ════════════════════════════════════════════════════════════════════
  #  Filesystem
  # ════════════════════════════════════════════════════════════════════

  fileSystems."/" = mkForce {
    device = "none";
    fsType = "tmpfs";
  };

  # ════════════════════════════════════════════════════════════════════
  #  Environment — systemd container interface
  # ════════════════════════════════════════════════════════════════════

  # The $container variable is the primary mechanism by which systemd
  # detects it is running in a container (see systemd.io/CONTAINER_INTERFACE).
  # When set, systemd skips hardware init, avoids bind-mount-based
  # sandboxing (ProtectSystem, ProtectHome, etc.), and degrades
  # gracefully when privileged operations are unavailable.
  environment.variables.container = "docker";

  environment.etc."machine-id" = {
    text = "00000000000000000000000000000000\n";
    mode = "0444";
  };

  # ════════════════════════════════════════════════════════════════════
  #  systemd
  # ════════════════════════════════════════════════════════════════════

  systemd.defaultUnit = "multi-user.target";
  systemd.enableEmergencyMode = false;

  # Disable seccomp-based sandboxing inside the container — the
  # kernel already enforces container boundaries via namespaces.
  # Without this, systemd 253+ services with sandboxing directives
  # may fail when they cannot set up seccomp filters.
  systemd.settings.Manager.DefaultEnvironment = "SYSTEMD_SECCOMP=0";

  # Prevent systemd from trying to enable cgroup controllers it
  # cannot manage without CAP_SYS_ADMIN.  See:
  # https://github.com/systemd/systemd/pull/10567
  # https://github.com/systemd/systemd/pull/7630
  systemd.slices."-.slice".sliceConfig.DisableControllers = [
    "cpu" "cpuset" "io" "memory" "pids"
  ];

  # ════════════════════════════════════════════════════════════════════
  #  Services — use proper NixOS options to disable
  # ════════════════════════════════════════════════════════════════════

  # boot.isContainer already sets services.udev.enable = false
  # and security.audit.enable = false in container-config.nix.
  # Explicitly disable remaining services that have NixOS options:

  services.resolved.enable = false;
  services.timesyncd.enable = mkForce false;
  services.nscd.enable = false;
  system.nssModules = mkForce [ ];

  # systemd-oomd needs CAP_SYS_ADMIN for cgroup pressure monitoring
  systemd.oomd.enable = false;

  # The suid wrappers mount needs CAP_SYS_ADMIN; disable it.
  security.wrappers = mkForce { };
  systemd.mounts = [{
    where = "/run/wrappers";
    enable = false;
  }];

  # ...but nixpkgs' pam_unix hardcodes /run/wrappers/bin/unix_chkpwd, and
  # without it *every* PAM account check returns PAM_AUTHINFO_UNAVAIL — sshd
  # then rejects every login with "Access denied by PAM account
  # configuration".  A plain symlink into the /run tmpfs is enough for root
  # (the helper reads /etc/shadow directly when euid is 0); non-root password
  # auth would still need the setuid bit, which no wrapper can provide here.
  systemd.tmpfiles.rules = [
    "L+ /run/wrappers/bin/unix_chkpwd - - - - ${config.security.pam.package}/bin/unix_chkpwd"
  ];

  # ════════════════════════════════════════════════════════════════════
  #  Logging — everything has to end up on PID 1's stdout
  # ════════════════════════════════════════════════════════════════════

  # `docker logs` shows one thing: whatever PID 1 writes to its stdout/stderr.
  # Two separate streams have to get there.
  #
  #  1. systemd's own messages.  Docker creates /dev/console only for `-t`, and
  #     stock systemd writes both its log and its "[  OK  ] Started ..." status
  #     lines there and nowhere else — so everything after "starting systemd"
  #     is silently dropped.  Patch 0006 falls back to stderr for both.
  #
  #  2. Service output.  Units log to the journal, and nothing inside a
  #     container ever reads it.  journald's own ForwardToConsole is no help:
  #     it writes to /dev/console too.  So follow the journal and copy it into
  #     PID 1's stdout, which is the pipe the runtime captures.  That is the
  #     docker-journal-forward unit, defined with the service list below.
  services.journald.storage = "volatile";

  # ════════════════════════════════════════════════════════════════════
  #  Networking — Docker manages the network stack
  # ════════════════════════════════════════════════════════════════════

  networking.useDHCP = mkForce false;
  networking.useNetworkd = mkForce false;
  networking.firewall.enable = mkForce false;
  networking.hosts = mkForce {
    "127.0.0.1" = [ "localhost" ];
    "::1"       = [ "localhost" ];
  };

  # ════════════════════════════════════════════════════════════════════
  #  Users
  # ════════════════════════════════════════════════════════════════════

  users.users.root.initialHashedPassword = mkDefault "";

  # ════════════════════════════════════════════════════════════════════
  #  Masked systemd units — services without NixOS-level options
  #  that would fail or are pointless in an unprivileged container.
  # ════════════════════════════════════════════════════════════════════

  systemd.services = let
    mkMasked = name: lib.nameValuePair name {
      enable = mkForce false;
      wantedBy = mkForce [ ];
      requiredBy = mkForce [ ];
    };
  in builtins.listToAttrs (map mkMasked [
    # journald itself stays enabled — it is what collects service output,
    # which docker-journal-forward then copies to PID 1's stdout.  Flushing
    # to /var/log/journal is pointless with storage = "volatile".
    "systemd-journal-flush"

    # Hardware — no devices, no kernel, no firmware
    "systemd-sysctl"
    "systemd-random-seed"
    "systemd-rfkill"
    "systemd-hibernate-resume"
    "systemd-tmpfiles-setup-dev"
    "systemd-binfmt"
    "systemd-pstore"
    "systemd-firstboot"
    "systemd-hwdb-update"

    # Networking (Docker manages this)
    "systemd-networkd"
    "systemd-networkd-wait-online"
    "firewall"
    "network-setup"

    # Filesystem / mount — requires CAP_SYS_ADMIN
    "systemd-remount-fs"
    "suid-sgid-wrappers"

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
  ]) // {
    # Copy the journal into PID 1's stdout, the only stream `docker logs`
    # shows.  See the logging section above for why nothing else works.
    docker-journal-forward = {
      description = "Forward the journal to the container runtime's stdout";
      documentation = [ "https://systemd.io/CONTAINER_INTERFACE" ];
      wantedBy = [ "sysinit.target" ];
      requires = [ "systemd-journald.service" ];
      after = [ "systemd-journald.service" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        # --lines=all replays what was logged before this unit started, so the
        # early boot reaches `docker logs` too, not just everything after it.
        ExecStart = "${config.systemd.package}/bin/journalctl --follow --lines=all --output=short-precise --no-hostname";
        # append: bypasses the journal, so following it cannot feed itself.
        StandardOutput = "append:/proc/1/fd/1";
        StandardError = "journal";
        Restart = "always";
        RestartSec = 1;
      };
    };
  };

  systemd.sockets = let
    mkMasked = name: lib.nameValuePair name {
      enable = mkForce false;
      wantedBy = mkForce [ ];
    };
  in builtins.listToAttrs (map mkMasked [
    "systemd-udevd-control"
    "systemd-udevd-kernel"
    # No audit subsystem in the container; the other two journald sockets
    # stay, they are how units hand their stdout to journald.
    "systemd-journald-audit"
  ]);

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
    includeNixDB = imgCfg.includeNixDB;

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
        "/run"           = { };
        "/run/lock"      = { };
        "/tmp"           = { };
      };
      # Derived from the firewall lists — services that open a port with
      # `openFirewall` (sshd, nginx, ...) get it declared on the image, so
      # `docker run -P` and registry UIs see the right ports.  Port *ranges*
      # are skipped on purpose; declare those via networking.firewall
      # .allowedTCPPorts if you want them exposed.
      ExposedPorts = lib.listToAttrs (
        map (p: lib.nameValuePair "${toString p}/tcp" { }) config.networking.firewall.allowedTCPPorts
        ++ map (p: lib.nameValuePair "${toString p}/udp" { }) config.networking.firewall.allowedUDPPorts
      );
      Labels = {
        "org.nixos.systemd-container" = "true";
      };
    };
  };
}
