#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRICTL="${ROOT_DIR}/.local/bin/crictl"
BINARY="${KRUST_CRI_BINARY:-${ROOT_DIR}/.build/debug/krust-cri}"
RUNTIME_DIR="${KRUST_CRI_SMOKE_DIR:-${ROOT_DIR}/.tmp/kubelet-cri-surface}"
SOCKET="${KRUST_CRI_SOCKET:-${RUNTIME_DIR}/krust-cri.sock}"
STATE_DIR="${KRUST_CRI_STATE_DIR:-${RUNTIME_DIR}/state}"
SERVER_LOG="${KRUST_CRI_SERVER_LOG:-${RUNTIME_DIR}/krust-cri.log}"
IMAGE="${KRUST_CRI_TEST_IMAGE:-docker.io/library/alpine:3.20}"

if [[ ! -x "${BINARY}" ]]; then
  echo "krust-cri binary not found. Run swift build first." >&2
  exit 1
fi

if [[ ! -x "${CRICTL}" ]]; then
  echo "crictl not found at ${CRICTL}" >&2
  exit 1
fi

mkdir -p "${RUNTIME_DIR}"
rm -f "${SOCKET}" "${SERVER_LOG}"
rm -rf "${STATE_DIR}"

"${BINARY}" \
  --listen "${SOCKET}" \
  --state-dir "${STATE_DIR}" \
  --backend mvp \
  >"${SERVER_LOG}" 2>&1 &

SERVER_PID=$!
POD_ID=""
CONTAINER_ID=""

endpoint="unix://${SOCKET}"
crictl() {
  "${CRICTL}" --config /dev/null --runtime-endpoint "${endpoint}" --image-endpoint "${endpoint}" --timeout 30s "$@"
}

cleanup() {
  set +e
  if [[ -n "${CONTAINER_ID}" ]]; then crictl stop "${CONTAINER_ID}" >/dev/null 2>&1; fi
  if [[ -n "${POD_ID}" ]]; then crictl stopp "${POD_ID}" >/dev/null 2>&1; fi
  if [[ -n "${CONTAINER_ID}" ]]; then crictl rm "${CONTAINER_ID}" >/dev/null 2>&1; fi
  if [[ -n "${POD_ID}" ]]; then crictl rmp "${POD_ID}" >/dev/null 2>&1; fi
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

if [[ ! -S "${SOCKET}" ]]; then
  echo "krust-cri did not create ${SOCKET}" >&2
  cat "${SERVER_LOG}" >&2
  exit 1
fi

echo "==> Runtime identity and readiness"
crictl version
crictl info
crictl runtime-config

echo "==> Image service baseline"
crictl imagefsinfo
crictl pull "${IMAGE}"
crictl images
crictl imagefsinfo

echo "==> Empty runtime lists and metrics"
crictl pods
crictl ps -a
crictl stats
crictl statsp
crictl metricdescs
crictl metricsp

echo "==> Pod and container lifecycle surface"
POD_ID="$(crictl runp "${ROOT_DIR}/testdata/crictl/sandbox.json")"
echo "pod=${POD_ID}"
CONTAINER_ID="$(crictl create "${POD_ID}" "${ROOT_DIR}/testdata/crictl/container.json" "${ROOT_DIR}/testdata/crictl/sandbox.json")"
echo "container=${CONTAINER_ID}"
crictl start "${CONTAINER_ID}"
crictl inspectp "${POD_ID}"
crictl inspect "${CONTAINER_ID}"
crictl pods
crictl ps -a
crictl stats "${CONTAINER_ID}"
crictl statsp "${POD_ID}"

echo "==> Cleanup lifecycle"
crictl stop "${CONTAINER_ID}"
crictl stopp "${POD_ID}"
crictl rm "${CONTAINER_ID}"
CONTAINER_ID=""
crictl rmp "${POD_ID}"
POD_ID=""

echo "kubelet CRI surface smoke test complete"
