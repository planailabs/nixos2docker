# nixos2docker

Build Docker images from any NixOS configuration with **systemd as PID 1** — no `--privileged`, no `--cap-add SYS_ADMIN`, no special cgroup flags.

Import one module, and every NixOS system gets a `config.system.build.dockerImage` — just like `config.system.build.vm` gives you a QEMU VM. The container tweaks only affect the Docker image; your base system config stays untouched.

## Quick start

### As a flake module

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos2docker.url = "git+https://git.plan.ai/plan-ai/nixos2docker";
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

# Run — no extra capabilities needed
docker run -d --name nixos \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  --stop-signal SIGRTMIN+3 \
  nixos-docker:latest

# Check it's running
docker exec -e PATH=/run/current-system/sw/bin nixos systemctl status
```

That's it. No `--privileged`, no `--cap-add`, no `--cgroupns`, no `-v /sys/fs/cgroup`.

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

### systemd patches

systemd 260 hard-crashes in containers with read-only cgroup filesystems (the default in Docker). This project includes four patches applied via a nixpkgs overlay that make systemd gracefully degrade instead:

| Patch | What it fixes |
|---|---|
| `0001-mount-setup` | Skip the `MNT_CHECK_WRITABLE` fatal check on `/sys/fs/cgroup` when `detect_container() > 0` |
| `0002-cgroup` | Skip `cg_create()` for init.scope and per-unit cgroups on read-only cgroup fs; replace `ASSERT_PTR` with NULL checks on `CGroupRuntime` |
| `0003-main` | Keep stdout/stderr alive in containers (skip `make_null_stdio()`); stay on `LOG_TARGET_CONSOLE` instead of switching to journal |
| `0004-exec-invoke` | Skip `apply_exec_quotas()` when `cgroup_path` is NULL |

These patches are inspired by how [Incus/LXC](https://linuxcontainers.org/incus/) runs unprivileged system containers and the approach of the [oci-systemd-hook](https://github.com/projectatomic/oci-systemd-hook).

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

**Boot:** `boot.isContainer = true`, `boot.initrd.systemd.enable = true`, no bootloader. `boot.specialFileSystems` cleared (Docker provides them). `boot.nixStoreMountOpts = []` (skip remount).

**Services disabled via NixOS options:** `services.resolved`, `services.nscd`, `services.timesyncd`, `systemd.oomd` — all disabled with proper NixOS options rather than manual unit masking.

**Masked services:** systemd-sysctl, systemd-random-seed, systemd-rfkill, systemd-hibernate-resume, systemd-tmpfiles-setup-dev, systemd-binfmt, systemd-pstore, systemd-firstboot, systemd-hwdb-update (hardware); systemd-networkd, systemd-networkd-wait-online, firewall, network-setup (networking); systemd-remount-fs, suid-sgid-wrappers (filesystem); systemd-logind, systemd-vconsole-setup, getty, serial-getty (console); systemd-journald, systemd-journal-flush (logging — console output instead); systemd-update-utmp, systemd-machine-id-commit, systemd-ask-password-wall (misc).

**Cgroups:** `DisableControllers` on the root slice prevents systemd from enabling controllers it can't manage. `SYSTEMD_SECCOMP=0` disables seccomp sandboxing (the kernel's container namespaces provide isolation).

**Networking:** DHCP, networkd, firewall all disabled — Docker manages networking.

**Journald:** Disabled (masked). Container logs go to stdout/stderr via the console logging patch, captured by `docker logs`.

**Environment:** `container=docker` set so systemd auto-detects the container runtime and skips hardware init.

**Stop signal:** `SIGRTMIN+3` — the correct signal for clean systemd shutdown.

## Docker run flags

The minimum command:

```bash
docker run -d \
  --tmpfs /run          # systemd needs a writable /run
  --tmpfs /run/lock     # lock files
  --tmpfs /tmp          # world-writable temp
  --stop-signal SIGRTMIN+3  # clean systemd shutdown
  my-image:latest
```

No `--privileged`, no `--cap-add`, no `--cgroupns`, no `-v /sys/fs/cgroup`.

Note: `docker exec` doesn't inherit the image's `PATH`. Use:
```bash
docker exec -e PATH=/run/current-system/sw/bin CONTAINER systemctl status
```

## Testing

```bash
# Run the VM integration test
nix flake check

# Fast local iteration with Docker
bash test-local.sh
```

## Differences from nixos-generators / nixos-container

- **nixos-generators** can produce Docker images but uses a different approach (often `streamLayeredImage` with a custom entry point). This module follows the `build-vm.nix` pattern so the image is always available and integrates naturally with `extendModules`.
- **`boot.isContainer` / NixOS containers** are designed for systemd-nspawn. This module builds on that but adds Docker-specific tweaks (OCI image config, volume declarations, stop signal, systemd patches) and disables services that systemd-nspawn handles implicitly but Docker doesn't.
- **Other systemd-in-Docker approaches** require `--cap-add SYS_ADMIN` or `--privileged`. This project patches systemd to gracefully degrade on read-only cgroup filesystems, eliminating the need for any extra capabilities.

## License

MIT
