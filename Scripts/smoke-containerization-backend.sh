#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRICTL="${ROOT_DIR}/.local/bin/crictl"
BUILD_BINARY="${ROOT_DIR}/.build/debug/krust-cri"
RUN_BINARY="${KRUST_CRI_RUN_BINARY:-/private/tmp/krust-cri-containerization-smoke}"
KERNEL_PATH="${KRUST_CRI_KERNEL:-${ROOT_DIR}/containerization/bin/vmlinux}"
INIT_REFERENCE="${KRUST_CRI_INITFS_REFERENCE:-vminit:latest}"
IMAGE_ROOT="${KRUST_CRI_CONTAINERIZATION_ROOT:-${HOME}/Library/Application Support/com.apple.containerization}"
SOCKET="${KRUST_CRI_SOCKET:-/tmp/krust-cri-containerization.sock}"
STATE_DIR="${KRUST_CRI_STATE_DIR:-/tmp/krust-cri-containerization-state}"
SERVER_LOG="${KRUST_CRI_SERVER_LOG:-/tmp/krust-cri-containerization.log}"

if [[ ! -x "${BUILD_BINARY}" ]]; then
  echo "krust-cri binary not found. Run swift build first." >&2
  exit 1
fi

if [[ ! -x "${CRICTL}" ]]; then
  echo "crictl not found at ${CRICTL}" >&2
  exit 1
fi

if [[ ! -f "${KERNEL_PATH}" ]]; then
  echo "kernel not found at ${KERNEL_PATH}" >&2
  echo "run Scripts/prepare-containerization-assets.sh first" >&2
  exit 1
fi

ditto "${BUILD_BINARY}" "${RUN_BINARY}"
"${ROOT_DIR}/Scripts/sign-krust-cri.sh" "${RUN_BINARY}"
rm -f "${SOCKET}" "${SERVER_LOG}"
rm -rf "${STATE_DIR}"

"${RUN_BINARY}" \
  --listen "${SOCKET}" \
  --state-dir "${STATE_DIR}" \
  --backend containerization \
  --kernel "${KERNEL_PATH}" \
  --initfs-reference "${INIT_REFERENCE}" \
  --containerization-root "${IMAGE_ROOT}" \
  >"${SERVER_LOG}" 2>&1 &

SERVER_PID=$!
cleanup() {
  set +e
  kill "${SERVER_PID}" >/dev/null 2>&1
  wait "${SERVER_PID}" >/dev/null 2>&1
}
trap cleanup EXIT

for _ in $(seq 1 100); do
  if [[ -S "${SOCKET}" ]]; then
    break
  fi
  if ! kill -0 "${SERVER_PID}" >/dev/null 2>&1; then
    echo "krust-cri exited before creating ${SOCKET}" >&2
    cat "${SERVER_LOG}" >&2
    exit 1
  fi
  sleep 0.1
done

endpoint="unix://${SOCKET}"
crictl() {
  "${CRICTL}" --config /dev/null --runtime-endpoint "${endpoint}" --image-endpoint "${endpoint}" --timeout 120s "$@"
}

echo "==> CRI version"
crictl version

echo "==> CRI status"
crictl info

echo "==> Pull test image"
crictl pull docker.io/library/alpine:3.20

echo "==> Run pod sandbox"
POD_ID="$(crictl runp "${ROOT_DIR}/testdata/crictl/sandbox.json")"
echo "pod=${POD_ID}"

echo "==> Create container"
CONTAINER_ID="$(crictl create "${POD_ID}" "${ROOT_DIR}/testdata/crictl/container.json" "${ROOT_DIR}/testdata/crictl/sandbox.json")"
echo "container=${CONTAINER_ID}"

echo "==> Start container"
crictl start "${CONTAINER_ID}"

echo "==> Inspect running container"
crictl inspect "${CONTAINER_ID}"

echo "==> Stop and remove"
crictl stop "${CONTAINER_ID}" || true
crictl stopp "${POD_ID}" || true
crictl rm "${CONTAINER_ID}" || true
crictl rmp "${POD_ID}" || true

echo "containerization backend smoke test complete"
