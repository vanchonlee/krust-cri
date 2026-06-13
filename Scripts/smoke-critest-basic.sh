#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRITEST="${ROOT_DIR}/.local/bin/critest"
BINARY="${KRUST_CRI_BINARY:-${ROOT_DIR}/.build/debug/krust-cri}"
RUNTIME_DIR="${KRUST_CRI_SMOKE_DIR:-${ROOT_DIR}/.tmp/critest-basic}"
SOCKET="${KRUST_CRI_SOCKET:-${RUNTIME_DIR}/krust-cri.sock}"
STATE_DIR="${KRUST_CRI_STATE_DIR:-${RUNTIME_DIR}/state}"
SERVER_LOG="${KRUST_CRI_SERVER_LOG:-${RUNTIME_DIR}/krust-cri.log}"
REPORT_DIR="${KRUST_CRI_CRITEST_REPORT_DIR:-${RUNTIME_DIR}/reports}"

FOCUS="${KRUST_CRI_CRITEST_FOCUS:-Runtime info|Image Manager|PodSandbox runtime should support basic operations|Idempotence|Container runtime should support basic operations on container runtime should support (creating container|starting container|stopping container|removing created container|removing running container|removing stopped container|execSync|listing container stats|listing stats for started containers|listing stats for three created containers|listing stats for containers filtered by labels)|Container runtime should support log runtime should support starting container with log}"
SKIP="${KRUST_CRI_CRITEST_SKIP:-execSync with timeout|volume|reopening container log|Streaming|Networking}"

if [[ ! -x "${BINARY}" ]]; then
  echo "krust-cri binary not found. Run swift build first." >&2
  exit 1
fi

if [[ ! -x "${CRITEST}" ]]; then
  echo "critest not found at ${CRITEST}" >&2
  echo "download https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.35.0/critest-v1.35.0-darwin-arm64.tar.gz" >&2
  exit 1
fi

mkdir -p "${RUNTIME_DIR}" "${REPORT_DIR}"
rm -f "${SOCKET}" "${SERVER_LOG}"
rm -rf "${STATE_DIR}"

"${BINARY}" \
  --listen "${SOCKET}" \
  --state-dir "${STATE_DIR}" \
  --backend mvp \
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

if [[ ! -S "${SOCKET}" ]]; then
  echo "krust-cri did not create ${SOCKET}" >&2
  cat "${SERVER_LOG}" >&2
  exit 1
fi

endpoint="unix://${SOCKET}"

echo "==> critest focused CRI validation"
"${CRITEST}" \
  --config /dev/null \
  --runtime-endpoint "${endpoint}" \
  --image-endpoint "${endpoint}" \
  --runtime-service-timeout 30s \
  --image-service-timeout 30s \
  --ginkgo.no-color \
  --ginkgo.focus "${FOCUS}" \
  --ginkgo.skip "${SKIP}" \
  --report-dir "${REPORT_DIR}" \
  --report-prefix krust-cri \
  "$@"

echo "critest basic smoke test complete"
