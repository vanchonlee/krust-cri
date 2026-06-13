#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRICTL="${ROOT_DIR}/.local/bin/crictl"
BUILD_BINARY="${ROOT_DIR}/.build/debug/krust-cri"
RUN_BINARY="${KRUST_CRI_RUN_BINARY:-/private/tmp/krust-cri-containerization-network-smoke}"
KERNEL_PATH="${KRUST_CRI_KERNEL:-${ROOT_DIR}/containerization/bin/vmlinux}"
INIT_REFERENCE="${KRUST_CRI_INITFS_REFERENCE:-vminit:latest}"
IMAGE_ROOT="${KRUST_CRI_CONTAINERIZATION_ROOT:-${HOME}/Library/Application Support/com.apple.containerization}"
SOCKET="${KRUST_CRI_SOCKET:-/tmp/krust-cri-containerization-network.sock}"
STATE_DIR="${KRUST_CRI_STATE_DIR:-/tmp/krust-cri-containerization-network-state}"
SERVER_LOG="${KRUST_CRI_SERVER_LOG:-/tmp/krust-cri-containerization-network.log}"
CRI_LOG_DIR="${KRUST_CRI_LOG_DIR:-/tmp/krust-cri-logs}"
CLIENT_LOG="${CRI_LOG_DIR}/client/1.log"

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
rm -f "${SOCKET}" "${SERVER_LOG}" "${CLIENT_LOG}"
rm -rf "${STATE_DIR}" "${CRI_LOG_DIR}"

"${RUN_BINARY}" \
  --listen "${SOCKET}" \
  --state-dir "${STATE_DIR}" \
  --backend containerization \
  --kernel "${KERNEL_PATH}" \
  --initfs-reference "${INIT_REFERENCE}" \
  --containerization-root "${IMAGE_ROOT}" \
  >"${SERVER_LOG}" 2>&1 &

SERVER_PID=$!
POD_A_ID=""
POD_B_ID=""
CONTAINER_A_ID=""
CONTAINER_B_ID=""
CLIENT_CONFIG=""

endpoint="unix://${SOCKET}"
crictl() {
  "${CRICTL}" --config /dev/null --runtime-endpoint "${endpoint}" --image-endpoint "${endpoint}" --timeout 120s "$@"
}

cleanup() {
  set +e
  if [[ -n "${CONTAINER_B_ID}" ]]; then crictl stop "${CONTAINER_B_ID}" >/dev/null 2>&1; fi
  if [[ -n "${POD_B_ID}" ]]; then crictl stopp "${POD_B_ID}" >/dev/null 2>&1; fi
  if [[ -n "${CONTAINER_B_ID}" ]]; then crictl rm "${CONTAINER_B_ID}" >/dev/null 2>&1; fi
  if [[ -n "${POD_B_ID}" ]]; then crictl rmp "${POD_B_ID}" >/dev/null 2>&1; fi
  if [[ -n "${CONTAINER_A_ID}" ]]; then crictl stop "${CONTAINER_A_ID}" >/dev/null 2>&1; fi
  if [[ -n "${POD_A_ID}" ]]; then crictl stopp "${POD_A_ID}" >/dev/null 2>&1; fi
  if [[ -n "${CONTAINER_A_ID}" ]]; then crictl rm "${CONTAINER_A_ID}" >/dev/null 2>&1; fi
  if [[ -n "${POD_A_ID}" ]]; then crictl rmp "${POD_A_ID}" >/dev/null 2>&1; fi
  if [[ -n "${CLIENT_CONFIG}" ]]; then rm -f "${CLIENT_CONFIG}" >/dev/null 2>&1; fi
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

echo "==> CRI status must report vmnet ready"
crictl info
if ! crictl info | grep -q '"vmnet": "ready"'; then
  echo "vmnet is not ready; server log:" >&2
  cat "${SERVER_LOG}" >&2
  exit 1
fi

echo "==> Pull test image"
crictl pull docker.io/library/busybox:1.36.1

echo "==> Start server pod"
POD_A_ID="$(crictl runp "${ROOT_DIR}/testdata/crictl/network-server-sandbox.json")"
CONTAINER_A_ID="$(crictl create "${POD_A_ID}" "${ROOT_DIR}/testdata/crictl/network-server-container.json" "${ROOT_DIR}/testdata/crictl/network-server-sandbox.json")"
crictl start "${CONTAINER_A_ID}"

POD_A_IP="$(crictl inspectp "${POD_A_ID}" | sed -n 's/.*"ip": "\([^"]*\)".*/\1/p' | head -1)"
if [[ -z "${POD_A_IP}" ]]; then
  echo "failed to read server pod IP" >&2
  crictl inspectp "${POD_A_ID}" >&2
  exit 1
fi
echo "server pod ip=${POD_A_IP}"

CLIENT_CONFIG="$(mktemp "${TMPDIR:-/tmp}/krust-cri-client-container.XXXXXX")"
sed "s/__SERVER_IP__/${POD_A_IP}/g" \
  "${ROOT_DIR}/testdata/crictl/network-client-container.json" >"${CLIENT_CONFIG}"

echo "==> Start client pod and fetch server pod IP"
POD_B_ID="$(crictl runp "${ROOT_DIR}/testdata/crictl/network-client-sandbox.json")"
CONTAINER_B_ID="$(crictl create "${POD_B_ID}" "${CLIENT_CONFIG}" "${ROOT_DIR}/testdata/crictl/network-client-sandbox.json")"
crictl start "${CONTAINER_B_ID}"

echo "==> Wait for client log proof"
for _ in $(seq 1 120); do
  if [[ -f "${CLIENT_LOG}" ]] && grep -q "hello-from-krust-pod-a" "${CLIENT_LOG}"; then
    cat "${CLIENT_LOG}"
    echo "same-node pod-to-pod network smoke test complete"
    exit 0
  fi
  sleep 1
done

echo "client did not reach server pod" >&2
echo "--- client log ---" >&2
if [[ -f "${CLIENT_LOG}" ]]; then cat "${CLIENT_LOG}" >&2; fi
echo "--- server log ---" >&2
cat "${SERVER_LOG}" >&2
exit 1
