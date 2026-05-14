#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="nixos-nginx-test"
CONTAINER_NAME="nixos-test-local"
NIXPATH="/run/current-system/sw/bin"

cleanup() {
  echo "==> Cleaning up..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Building Docker image with nginx..."
nix build .#testImage --print-build-logs

echo "==> Loading image..."
docker load < result

echo "==> Starting container (NO extra capabilities)..."
docker run -d --name "$CONTAINER_NAME" \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -p 18080:80 \
  "$IMAGE_NAME:latest"

echo "==> Waiting for systemd to boot (max 30s)..."
state="unknown"
for i in $(seq 1 30); do
  state=$(docker exec -e PATH="$NIXPATH" "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null || true)
  echo "  [$i] systemd state: $state"
  if [[ "$state" == "running" || "$state" == "degraded" ]]; then
    break
  fi
  sleep 1
done

echo ""
echo "=== systemd state: $state ==="
echo ""

echo "==> systemctl list-jobs:"
docker exec -e PATH="$NIXPATH" "$CONTAINER_NAME" systemctl list-jobs 2>&1 || true

echo ""
echo "==> Failed units:"
docker exec -e PATH="$NIXPATH" "$CONTAINER_NAME" systemctl --failed 2>&1 || true

echo ""
echo "==> Journal (last 40 lines):"
docker exec -e PATH="$NIXPATH" "$CONTAINER_NAME" journalctl -b --no-pager -n 40 2>&1 || true

echo ""
echo "==> PID 1:"
docker exec -e PATH="$NIXPATH" "$CONTAINER_NAME" ps -p 1 -o pid,comm 2>&1 || true

echo ""
echo "==> Checking nginx on :8080 ..."
curl -sf http://localhost:18080/ 2>&1 || echo "(nginx not responding)"

echo ""
echo "==> Stopping container..."
docker stop -t 10 "$CONTAINER_NAME"
exit_code=$(docker inspect "$CONTAINER_NAME" --format='{{.State.ExitCode}}')
echo "==> Container exit code: $exit_code"
