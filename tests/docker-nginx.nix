# NixOS VM test: build a Docker image with nginx via nixos2docker,
# load it into Docker on a VM, and verify systemd + nginx work.

{ self, pkgs, lib, ... }:

let
  # Build a NixOS Docker image that has nginx enabled
  nginxDockerImage = (lib.nixosSystem {
    inherit (pkgs) system;
    modules = [
      self.nixosModules.default
      ({ pkgs, ... }: {
        virtualisation.dockerImage.name = "nixos-nginx-test";
        virtualisation.dockerImage.tag = "latest";

        services.nginx = {
          enable = true;
          virtualHosts."localhost" = {
            root = pkgs.writeTextDir "index.html" "nixos2docker-ok";
          };
        };

        system.stateVersion = "24.11";
      })
    ];
  }).config.system.build.dockerImage;

in
{
  name = "docker-nginx";
  meta.maintainers = [ ];

  nodes.machine = { pkgs, ... }: {
    virtualisation = {
      docker.enable = true;
      # Enough resources for Docker + systemd container
      memorySize = 2048;
      diskSize = 4096;
      cores = 2;
    };
  };

  testScript = ''
    machine.wait_for_unit("docker.service")

    # Load the pre-built Docker image
    machine.succeed("docker load < ${nginxDockerImage}")

    # Start the container with systemd requirements
    machine.succeed(
        "docker run -d --name nixos-test "
        "--tmpfs /run --tmpfs /run/lock --tmpfs /tmp "
        "--cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw "
        "--stop-signal SIGRTMIN+3 "
        "--cap-add SYS_ADMIN "
        "-p 8080:80 "
        "nixos-nginx-test:latest"
    )

    # Wait for systemd to finish booting inside the container
    machine.wait_until_succeeds(
        "docker exec nixos-test systemctl is-system-running --wait 2>/dev/null | grep -qE 'running|degraded'",
        timeout=60,
    )

    # Verify systemd is PID 1
    machine.succeed(
        "docker exec nixos-test ps -p 1 -o comm= | grep -q systemd"
    )

    # Check that multi-user.target was reached
    machine.succeed(
        "docker exec nixos-test systemctl is-active multi-user.target"
    )

    # Verify nginx service is running
    machine.succeed(
        "docker exec nixos-test systemctl is-active nginx.service"
    )

    # Verify nginx responds with the expected content
    machine.wait_until_succeeds(
        "curl -sf http://localhost:8080/ | grep -q nixos2docker-ok",
        timeout=30,
    )

    # Verify no failed systemd units
    machine.succeed(
        "docker exec nixos-test systemctl --failed --no-legend | wc -l | grep -q '^0$'"
    )

    # Clean stop — verify systemd shuts down gracefully
    machine.succeed("docker stop -t 30 nixos-test")
    machine.succeed("docker inspect nixos-test --format='{{.State.ExitCode}}' | grep -q '^0$'")
  '';
}
