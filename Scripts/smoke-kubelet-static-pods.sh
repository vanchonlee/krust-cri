#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRICTL="${ROOT_DIR}/.local/bin/crictl"
KUBELET="${KRUST_CRI_KUBELET:-${ROOT_DIR}/.local/bin/kubelet-linux-arm64}"
KRUST_CRI_BUILD="${ROOT_DIR}/.build/debug/krust-cri"
KUBELET_POD_BUILD="${ROOT_DIR}/.build/debug/krust-kubelet-pod"
KRUST_CRI_RUN_BINARY="${KRUST_CRI_RUN_BINARY:-/private/tmp/krust-cri-kubelet-smoke}"
KUBELET_POD_RUN_BINARY="${KRUST_KUBELET_POD_RUN_BINARY:-/private/tmp/krust-kubelet-pod-smoke-bin}"
KERNEL_PATH="${KRUST_CRI_KERNEL:-${ROOT_DIR}/containerization/bin/vmlinux}"
INIT_REFERENCE="${KRUST_CRI_INITFS_REFERENCE:-vminit:latest}"
IMAGE_ROOT="${KRUST_CRI_CONTAINERIZATION_ROOT:-${HOME}/Library/Application Support/com.apple.containerization}"
SOCKET="${KRUST_CRI_SOCKET:-/tmp/krust-cri-kubelet-smoke.sock}"
STATE_DIR="${KRUST_CRI_STATE_DIR:-/tmp/krust-cri-kubelet-smoke-state}"
SERVER_LOG="${KRUST_CRI_SERVER_LOG:-/tmp/krust-cri-kubelet-smoke.log}"
WORK_DIR="${KRUST_KUBELET_WORK_DIR:-/tmp/krust-kubelet-pod-smoke}"
MANIFESTS_DIR="${WORK_DIR}/manifests"
POD_LOGS_DIR="${KRUST_KUBELET_POD_LOGS_DIR:-/tmp/krust-cri-kubelet-logs}"
CLIENT_LOG_PATTERN="${POD_LOGS_DIR}/default_krust-static-client-"'*'"/client/0.log"

if [[ ! -x "${KRUST_CRI_BUILD}" ]]; then
  echo "krust-cri binary not found. Run swift build first." >&2
  exit 1
fi

if [[ ! -x "${KUBELET_POD_BUILD}" ]]; then
  echo "krust-kubelet-pod binary not found. Run swift build first." >&2
  exit 1
fi

if [[ ! -x "${CRICTL}" ]]; then
  echo "crictl not found at ${CRICTL}" >&2
  exit 1
fi

if [[ ! -x "${KUBELET}" ]]; then
  echo "linux kubelet not found at ${KUBELET}" >&2
  echo "download it with: curl -fL -o .local/bin/kubelet-linux-arm64 https://dl.k8s.io/release/v1.35.0/bin/linux/arm64/kubelet && chmod +x .local/bin/kubelet-linux-arm64" >&2
  exit 1
fi

if [[ ! -f "${KERNEL_PATH}" ]]; then
  echo "kernel not found at ${KERNEL_PATH}" >&2
  echo "run Scripts/prepare-containerization-assets.sh first" >&2
  exit 1
fi

ditto "${KRUST_CRI_BUILD}" "${KRUST_CRI_RUN_BINARY}"
"${ROOT_DIR}/Scripts/sign-krust-cri.sh" "${KRUST_CRI_RUN_BINARY}"
ditto "${KUBELET_POD_BUILD}" "${KUBELET_POD_RUN_BINARY}"
"${ROOT_DIR}/Scripts/sign-krust-cri.sh" "${KUBELET_POD_RUN_BINARY}"

rm -f "${SOCKET}" "${SERVER_LOG}"
rm -rf "${STATE_DIR}" "${WORK_DIR}" "${POD_LOGS_DIR}"
mkdir -p "${MANIFESTS_DIR}" "${POD_LOGS_DIR}"

"${KRUST_CRI_RUN_BINARY}" \
  --listen "${SOCKET}" \
  --state-dir "${STATE_DIR}" \
  --backend containerization \
  --cgroup-driver cgroupfs \
  --kernel "${KERNEL_PATH}" \
  --initfs-reference "${INIT_REFERENCE}" \
  --containerization-root "${IMAGE_ROOT}" \
  >"${SERVER_LOG}" 2>&1 &

SERVER_PID=$!
KUBELET_PID=""

endpoint="unix://${SOCKET}"
crictl() {
  "${CRICTL}" --config /dev/null --runtime-endpoint "${endpoint}" --image-endpoint "${endpoint}" --timeout 120s "$@"
}

cleanup() {
  set +e
  if [[ -n "${KUBELET_PID}" ]]; then kill "${KUBELET_PID}" >/dev/null 2>&1; fi
  if [[ -n "${KUBELET_PID}" ]]; then wait "${KUBELET_PID}" >/dev/null 2>&1; fi
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
if ! crictl info | grep -q '"vmnet": "ready"'; then
  echo "vmnet is not ready; server log:" >&2
  cat "${SERVER_LOG}" >&2
  exit 1
fi

cat >"${MANIFESTS_DIR}/server.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: krust-static-server
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: server
      image: docker.io/library/busybox:1.36.1
      command:
        - /bin/sh
        - -c
        - mkdir -p /www; echo hello-from-kubelet-pod-a > /www/index.html; exec httpd -f -p 0.0.0.0:8080 -h /www
YAML

echo "==> Start LinuxPod kubelet with relayed CRI socket"
"${KUBELET_POD_RUN_BINARY}" \
  --kubelet "${KUBELET}" \
  --manifests "${MANIFESTS_DIR}" \
  --cri-socket "${SOCKET}" \
  --kernel "${KERNEL_PATH}" \
  --initfs-reference "${INIT_REFERENCE}" \
  --containerization-root "${IMAGE_ROOT}" \
  --work-dir "${WORK_DIR}" \
  --pod-logs-dir "${POD_LOGS_DIR}" \
  >"${WORK_DIR}/runner.log" 2>&1 &

KUBELET_PID=$!

echo "==> Wait for kubelet to create server pod"
SERVER_POD_ID=""
for _ in $(seq 1 180); do
  if ! kill -0 "${KUBELET_PID}" >/dev/null 2>&1; then
    echo "kubelet pod runner exited early" >&2
    cat "${WORK_DIR}/runner.log" >&2 || true
    cat "${WORK_DIR}/logs/kubelet.log" >&2 || true
    exit 1
  fi
  SERVER_POD_ID="$(crictl pods --name krust-static-server -q | head -1 || true)"
  if [[ -n "${SERVER_POD_ID}" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${SERVER_POD_ID}" ]]; then
  echo "kubelet did not create server pod" >&2
  cat "${WORK_DIR}/logs/kubelet.log" >&2 || true
  cat "${SERVER_LOG}" >&2
  exit 1
fi

SERVER_IP=""
for _ in $(seq 1 120); do
  SERVER_IP="$(crictl inspectp "${SERVER_POD_ID}" | sed -n 's/.*"ip": "\([^"]*\)".*/\1/p' | head -1)"
  if [[ -n "${SERVER_IP}" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "${SERVER_IP}" ]]; then
  echo "server pod has no IP" >&2
  crictl inspectp "${SERVER_POD_ID}" >&2
  exit 1
fi
echo "server pod ip=${SERVER_IP}"

cat >"${MANIFESTS_DIR}/client.yaml" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: krust-static-client
  namespace: default
spec:
  restartPolicy: Never
  containers:
    - name: client
      image: docker.io/library/busybox:1.36.1
      command:
        - /bin/sh
        - -c
        - for i in \$(seq 1 60); do wget -qO- http://${SERVER_IP}:8080 && exit 0; sleep 1; done; exit 1
YAML

echo "==> Wait for kubelet-created client pod log proof"
for _ in $(seq 1 180); do
  for log in ${CLIENT_LOG_PATTERN}; do
    if [[ -f "${log}" ]] && grep -q "hello-from-kubelet-pod-a" "${log}"; then
      cat "${log}"
      echo "kubelet static pod-to-pod smoke test complete"
      exit 0
    fi
  done
  sleep 1
done

echo "client did not reach server pod" >&2
echo "--- kubelet log ---" >&2
cat "${WORK_DIR}/logs/kubelet.log" >&2 || true
echo "--- krust-cri log ---" >&2
cat "${SERVER_LOG}" >&2
exit 1
