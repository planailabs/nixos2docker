# CLAUDE.md

## Testing

Always test in this order:

1. **Local Docker first** — fast iteration: `bash test-local.sh`
2. **VM test via flake checks** — full integration: `nix flake check` or `nix build .#checks.x86_64-linux.docker-nginx --print-build-logs`

The local test takes seconds; the VM test takes ~90s and rebuilds systemd if patches changed.

## Build

- `nix build .#testImage` — build the nginx test image
- `nix build .#dockerImage` — build the example image (openssh)
- Docker images are loaded with `docker load < result`

## Architecture

- `build-docker-image.nix` — outer module, uses `extendModules` (like `build-vm.nix`)
- `docker-container.nix` — inner module, container tweaks + systemd patches + image build
- `0001-*.patch` through `0004-*.patch` — systemd patches for read-only cgroup support
- `tests/docker-nginx.nix` — NixOS VM integration test
- `test-local.sh` — fast local Docker test script
