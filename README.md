# nixos2docker

Build Docker images from any NixOS configuration with **systemd as PID 1**.

Import one module, and every NixOS system gets a `config.system.build.dockerImage` — just like `config.system.build.vm` gives you a QEMU VM. The container tweaks (masked hardware services, disabled networkd, volatile journald, etc.) only affect the Docker image; your base system config stays untouched.

## Quick start

### As a flake module

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos2docker.url = "github:youruser/nixos2docker";
  };

  outputs = { nixpkgs, nixos2docker, ... }: {
    nixosConfigurations.myHost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        nixos2docker.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

### Build & run

```bash
# Build the image
nix build .#nixosConfigurations.myHost.config.system.build.dockerImage

# Load into Docker
docker load < result

# Run with systemd as PID 1
docker run -d --name nixos \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --stop-signal SIGRTMIN+3 \
  --cap-add SYS_ADMIN \
  nixos-docker:latest

# Check it's running
docker exec nixos systemctl status
```

## How it works

The architecture mirrors how NixOS builds VMs (`build-vm.nix` + `qemu-vm.nix`):

| File | Role | Analogue |
|---|---|---|
| `build-docker-image.nix` | Outer module — uses `extendModules` to create a Docker variant, wires up `system.build.dockerImage` | `build-vm.nix` |
| `docker-container.nix` | Inner module — injected into the variant, applies all systemd/container tweaks and builds the image | `qemu-vm.nix` |

The `extendModules` call creates a **separate NixOS evaluation** that inherits your full config but layers on the container module. This means:

- Your base `config` is never modified — no `boot.isContainer`, no masked services, no side effects.
- The Docker variant's `config.system.build.toplevel` has all the container tweaks baked in.
- `config.system.build.dockerImage` just points at the variant's output.

## Options

### `virtualisation.dockerImage.name`

Name of the Docker image.

**Type:** `str`
**Default:** `config.networking.hostName` or `"nixos-docker"`

### `virtualisation.dockerImage.tag`

Tag of the Docker image.

**Type:** `str`
**Default:** `"latest"`

### `virtualisation.dockerImage.maxLayers`

Maximum number of Docker image layers. Higher values improve cache efficiency.

**Type:** `int`
**Default:** `125`

### `virtualisation.dockerImage.extraContents`

Additional store paths to include in the image.

**Type:** `list of package`
**Default:** `[ ]`

### `virtualisation.dockerVariant`

NixOS configuration that applies **only** to the Docker image, not the base system. This works exactly like `virtualisation.vmVariant` — you can set any NixOS option here and it will only take effect inside the container.

```nix
virtualisation.dockerVariant = {
  # Enable nginx only in the Docker image
  services.nginx.enable = true;

  # Add packages only to the container
  environment.systemPackages = [ pkgs.strace ];
};
```

## What gets tweaked for Docker

The container module applies the following, modelled on how Incus/LXD and systemd-nspawn configure container guests:

**Boot:** `boot.isContainer = true`, no bootloader, no initrd.

**Networking:** DHCP, networkd, resolved, timesyncd, and the firewall are all disabled — Docker manages networking externally.

**Masked services:** udevd, modules-load, sysctl, random-seed, rfkill (hardware); logind, getty, vconsole-setup (console); remount-fs (filesystem); utmp, machine-id-commit, ask-password-wall (misc).

**Masked sockets:** udevd-control, udevd-kernel, journald-audit.

**Masked targets:** sound, bluetooth, swap, hibernate, sleep, suspend.

**Journald:** volatile storage (RAM only), forwarded to console.

**Security:** audit disabled (unavailable in unprivileged containers).

**Environment:** `container=docker` is set so systemd and other tools detect the container runtime.

**Stop signal:** `SIGRTMIN+3` — the correct signal for clean systemd shutdown.

## Docker run flags explained

```bash
docker run -d \
  --tmpfs /run          # systemd needs a writable /run
  --tmpfs /run/lock     # lock files
  --tmpfs /tmp          # world-writable temp
  --cgroupns=host       # share the host cgroup namespace (or =private on cgroups v2)
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw  # systemd needs cgroup access
  --stop-signal SIGRTMIN+3             # clean systemd shutdown
  --cap-add SYS_ADMIN   # needed for systemd; drop if you can use --privileged
  my-image:latest
```

For a more locked-down setup on cgroups v2 hosts, you can use `--cgroupns=private` instead and potentially drop `SYS_ADMIN` if your systemd version supports it.

## Differences from nixos-generators / nixos-container

- **nixos-generators** can produce Docker images but uses a different approach (often `streamLayeredImage` with a custom entry point). This module follows the `build-vm.nix` pattern so the image is always available and integrates naturally with `extendModules`.
- **`boot.isContainer` / NixOS containers** are designed for systemd-nspawn. This module builds on that but adds Docker-specific tweaks (OCI image config, volume declarations, stop signal) and disables services that systemd-nspawn handles implicitly but Docker doesn't.

## License

MIT
