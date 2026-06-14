#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="${KUBECTL:-$(command -v kubectl || true)}"
JQ="${JQ:-$(command -v jq || true)}"
CRICTL="${ROOT_DIR}/.local/bin/crictl"
K3S="${KRUST_CRI_K3S:-${ROOT_DIR}/.local/bin/k3s-linux-arm64}"
KRUST_CRI_BUILD="${ROOT_DIR}/.build/debug/krust-cri"
KUBELET_POD_BUILD="${ROOT_DIR}/.build/debug/krust-kubelet-pod"
KRUST_CRI_RUN_BINARY="${KRUST_CRI_RUN_BINARY:-/private/tmp/krust-cri-k3s-smoke}"
K3S_POD_RUN_BINARY="${KRUST_K3S_POD_RUN_BINARY:-/private/tmp/krust-k3s-pod-smoke-bin}"
KERNEL_PATH="${KRUST_CRI_KERNEL:-${ROOT_DIR}/containerization/bin/vmlinux}"
INIT_REFERENCE="${KRUST_CRI_INITFS_REFERENCE:-vminit:latest}"
IMAGE_ROOT="${KRUST_CRI_CONTAINERIZATION_ROOT:-${HOME}/Library/Application Support/com.apple.containerization}"
SOCKET="${KRUST_CRI_SOCKET:-/tmp/krust-cri-k3s-smoke.sock}"
STATE_DIR="${KRUST_CRI_STATE_DIR:-/tmp/krust-cri-k3s-smoke-state}"
SERVER_LOG="${KRUST_CRI_SERVER_LOG:-/tmp/krust-cri-k3s-smoke.log}"
WORK_DIR="${KRUST_K3S_WORK_DIR:-/tmp/krust-k3s-pod-smoke}"
POD_LOGS_DIR="${KRUST_K3S_POD_LOGS_DIR:-/tmp/krust-cri-k3s-logs}"
KUBECONFIG_HOST="${WORK_DIR}/kubeconfig-host.yaml"
NODE_NAME="${KRUST_K3S_NODE_NAME:-krust-macos}"
CONTROL_ID="${KRUST_K3S_CONTROL_ID:-krust-k3s-$(date +%s)}"

if [[ -z "${KUBECTL}" || ! -x "${KUBECTL}" ]]; then
  if [[ -x /opt/homebrew/bin/kubectl ]]; then
    KUBECTL=/opt/homebrew/bin/kubectl
  elif [[ -x /usr/local/bin/kubectl ]]; then
    KUBECTL=/usr/local/bin/kubectl
  else
    echo "kubectl not found. Set KUBECTL=/path/to/kubectl" >&2
    exit 1
  fi
fi

if [[ -z "${JQ}" || ! -x "${JQ}" ]]; then
  echo "jq not found. Set JQ=/path/to/jq" >&2
  exit 1
fi

for binary in "${KRUST_CRI_BUILD}" "${KUBELET_POD_BUILD}" "${K3S}" "${CRICTL}"; do
  if [[ ! -x "${binary}" ]]; then
    echo "required executable not found: ${binary}" >&2
    exit 1
  fi
done

if [[ ! -f "${KERNEL_PATH}" ]]; then
  echo "kernel not found at ${KERNEL_PATH}" >&2
  echo "run Scripts/prepare-containerization-assets.sh first" >&2
  exit 1
fi

ditto "${KRUST_CRI_BUILD}" "${KRUST_CRI_RUN_BINARY}"
"${ROOT_DIR}/Scripts/sign-krust-cri.sh" "${KRUST_CRI_RUN_BINARY}"
ditto "${KUBELET_POD_BUILD}" "${K3S_POD_RUN_BINARY}"
"${ROOT_DIR}/Scripts/sign-krust-cri.sh" "${K3S_POD_RUN_BINARY}"

rm -f "${SOCKET}" "${SERVER_LOG}"
rm -rf "${STATE_DIR}" "${WORK_DIR}" "${POD_LOGS_DIR}"
mkdir -p "${WORK_DIR}" "${POD_LOGS_DIR}"

"${KRUST_CRI_RUN_BINARY}" \
  --listen "${SOCKET}" \
  --state-dir "${STATE_DIR}" \
  --backend containerization \
  --cgroup-driver cgroupfs \
  --host-pod-logs-dir "${POD_LOGS_DIR}" \
  --kernel "${KERNEL_PATH}" \
  --initfs-reference "${INIT_REFERENCE}" \
  --containerization-root "${IMAGE_ROOT}" \
  >"${SERVER_LOG}" 2>&1 &

SERVER_PID=$!
K3S_PID=""

endpoint="unix://${SOCKET}"
crictl() {
  "${CRICTL}" --config /dev/null --runtime-endpoint "${endpoint}" --image-endpoint "${endpoint}" --timeout 120s "$@"
}

kubectl() {
  "${KUBECTL}" --kubeconfig "${KUBECONFIG_HOST}" "$@"
}

cleanup() {
  set +e
  if [[ -n "${K3S_PID}" ]]; then kill "${K3S_PID}" >/dev/null 2>&1; fi
  if [[ -n "${K3S_PID}" ]]; then wait "${K3S_PID}" >/dev/null 2>&1; fi
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

echo "==> Start single-node k3s server with relayed krust-cri socket"
"${K3S_POD_RUN_BINARY}" \
  --mode k3s-server \
  --id "${CONTROL_ID}" \
  --k3s "${K3S}" \
  --cri-socket "${SOCKET}" \
  --kernel "${KERNEL_PATH}" \
  --initfs-reference "${INIT_REFERENCE}" \
  --containerization-root "${IMAGE_ROOT}" \
  --work-dir "${WORK_DIR}" \
  --pod-logs-dir "${POD_LOGS_DIR}" \
  --node-name "${NODE_NAME}" \
  >"${WORK_DIR}/runner.log" 2>&1 &

K3S_PID=$!

echo "==> Wait for k3s kubeconfig"
for _ in $(seq 1 240); do
  if ! kill -0 "${K3S_PID}" >/dev/null 2>&1; then
    echo "k3s runner exited early" >&2
    cat "${WORK_DIR}/runner.log" >&2 || true
    cat "${WORK_DIR}/logs/k3s-server.log" >&2 || true
    exit 1
  fi
  if [[ -s "${WORK_DIR}/kubeconfig.yaml" && -s "${WORK_DIR}/control-ip.txt" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -s "${WORK_DIR}/kubeconfig.yaml" ]]; then
  echo "k3s did not write kubeconfig" >&2
  cat "${WORK_DIR}/logs/k3s-server.log" >&2 || true
  exit 1
fi

CONTROL_IP="$(tr -d '[:space:]' <"${WORK_DIR}/control-ip.txt")"
sed "s#https://127.0.0.1:6443#https://${CONTROL_IP}:6443#g" "${WORK_DIR}/kubeconfig.yaml" >"${KUBECONFIG_HOST}"

echo "==> Wait for k3s API and node registration"
for _ in $(seq 1 240); do
  if kubectl get node "${NODE_NAME}" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
kubectl get nodes -o wide

echo "==> Wait for default service account"
for _ in $(seq 1 120); do
  if kubectl get serviceaccount default >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
kubectl get serviceaccount default >/dev/null

echo "==> Create server pod via k3s API"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: krust-k3s-server
  namespace: default
spec:
  nodeName: ${NODE_NAME}
  restartPolicy: Never
  containers:
    - name: server
      image: docker.io/library/busybox:1.36.1
      command:
        - /bin/sh
        - -c
        - mkdir -p /www; echo hello-from-k3s-pod-a > /www/index.html; exec httpd -f -p 0.0.0.0:8080 -h /www
YAML

echo "==> Wait for server pod IP"
SERVER_IP=""
for _ in $(seq 1 240); do
  SERVER_IP="$(kubectl get pod krust-k3s-server -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  if [[ -n "${SERVER_IP}" ]]; then
    break
  fi
  sleep 1
done
if [[ -z "${SERVER_IP}" ]]; then
  echo "server pod has no IP" >&2
  kubectl describe pod krust-k3s-server >&2 || true
  cat "${WORK_DIR}/logs/k3s-server.log" >&2 || true
  exit 1
fi
echo "server pod ip=${SERVER_IP}"

echo "==> Create client pod and test direct pod IP"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: krust-k3s-client
  namespace: default
spec:
  nodeName: ${NODE_NAME}
  restartPolicy: Never
  containers:
    - name: client
      image: docker.io/library/busybox:1.36.1
      command:
        - /bin/sh
        - -c
        - for i in \$(seq 1 60); do wget -qO- http://${SERVER_IP}:8080 && exit 0; sleep 1; done; exit 1
YAML

for _ in $(seq 1 240); do
  phase="$(kubectl get pod krust-k3s-client -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Succeeded" ]]; then
    logs="$(kubectl logs krust-k3s-client 2>/dev/null || true)"
    if [[ "${logs}" == *"hello-from-k3s-pod-a"* ]]; then
      printf '%s\n' "${logs}"
    else
      grep -R "hello-from-k3s-pod-a" "${POD_LOGS_DIR}"
    fi
    break
  fi
  if [[ "${phase}" == "Failed" ]]; then
    kubectl describe pod krust-k3s-client >&2 || true
    kubectl logs krust-k3s-client >&2 || true
    exit 1
  fi
  sleep 1
done

phase="$(kubectl get pod krust-k3s-client -o jsonpath='{.status.phase}' 2>/dev/null || true)"
if [[ "${phase}" != "Succeeded" ]]; then
  echo "client pod did not finish" >&2
  kubectl get pods -o wide >&2 || true
  kubectl describe pod krust-k3s-client >&2 || true
  cat "${WORK_DIR}/logs/k3s-server.log" >&2 || true
  exit 1
fi

echo "==> Verify failed container termination status"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: krust-k3s-fail
  namespace: default
spec:
  nodeName: ${NODE_NAME}
  restartPolicy: Never
  containers:
    - name: fail
      image: docker.io/library/busybox:1.36.1
      command:
        - /bin/sh
        - -c
        - exit 42
YAML

for _ in $(seq 1 120); do
  phase="$(kubectl get pod krust-k3s-fail -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Failed" ]]; then
    break
  fi
  sleep 1
done

FAILED_EXIT_CODE="$(kubectl get pod krust-k3s-fail -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)"
FAILED_REASON="$(kubectl get pod krust-k3s-fail -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"
FAILED_MESSAGE="$(kubectl get pod krust-k3s-fail -o jsonpath='{.status.containerStatuses[0].state.terminated.message}' 2>/dev/null || true)"
if [[ "${FAILED_EXIT_CODE}" != "42" || "${FAILED_REASON}" != "Error" || "${FAILED_MESSAGE}" != *"42"* ]]; then
  echo "failed pod termination status mismatch: exit=${FAILED_EXIT_CODE} reason=${FAILED_REASON} message=${FAILED_MESSAGE}" >&2
  kubectl get pod krust-k3s-fail -o yaml >&2 || true
  exit 1
fi

echo "==> Verify kubelet OnFailure restart behavior"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: krust-k3s-restart
  namespace: default
spec:
  nodeName: ${NODE_NAME}
  restartPolicy: OnFailure
  containers:
    - name: restart
      image: docker.io/library/busybox:1.36.1
      command:
        - /bin/sh
        - -c
        - exit 7
YAML

for _ in $(seq 1 180); do
  RESTART_COUNT="$(kubectl get pod krust-k3s-restart -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
  LAST_EXIT_CODE="$(kubectl get pod krust-k3s-restart -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || true)"
  LAST_REASON="$(kubectl get pod krust-k3s-restart -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)"
  CURRENT_WAITING_REASON="$(kubectl get pod krust-k3s-restart -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  if [[ "${CURRENT_WAITING_REASON}" == "RunContainerError" || "${CURRENT_WAITING_REASON}" == "CreateContainerError" ]]; then
    break
  fi
  if [[ "${RESTART_COUNT}" =~ ^[0-9]+$ ]] && (( RESTART_COUNT >= 1 )) && [[ "${LAST_EXIT_CODE}" == "7" && "${LAST_REASON}" == "Error" ]]; then
    echo "OnFailure restart verified: restartCount=${RESTART_COUNT}"
    break
  fi
  sleep 1
done

RESTART_COUNT="$(kubectl get pod krust-k3s-restart -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
LAST_EXIT_CODE="$(kubectl get pod krust-k3s-restart -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null || true)"
LAST_REASON="$(kubectl get pod krust-k3s-restart -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null || true)"
CURRENT_WAITING_REASON="$(kubectl get pod krust-k3s-restart -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
if ! [[ "${RESTART_COUNT}" =~ ^[0-9]+$ ]] || (( RESTART_COUNT < 1 )) || [[ "${LAST_EXIT_CODE}" != "7" || "${LAST_REASON}" != "Error" || "${CURRENT_WAITING_REASON}" == "RunContainerError" || "${CURRENT_WAITING_REASON}" == "CreateContainerError" ]]; then
  echo "OnFailure restart status mismatch: restartCount=${RESTART_COUNT} lastExit=${LAST_EXIT_CODE} lastReason=${LAST_REASON} waiting=${CURRENT_WAITING_REASON}" >&2
  kubectl get pod krust-k3s-restart -o yaml >&2 || true
  exit 1
fi

echo "==> Verify live container log reopen after rotation"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: krust-k3s-log-writer
  namespace: default
spec:
  nodeName: ${NODE_NAME}
  restartPolicy: Never
  containers:
    - name: writer
      image: docker.io/library/busybox:1.36.1
      command:
        - /bin/sh
        - -c
        - while true; do echo krust-log-reopen-proof; sleep 1; done
YAML

for _ in $(seq 1 120); do
  phase="$(kubectl get pod krust-k3s-log-writer -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${phase}" == "Running" ]]; then
    writer_logs="$(kubectl logs krust-k3s-log-writer --tail=5 2>/dev/null || true)"
    if [[ "${writer_logs}" == *"krust-log-reopen-proof"* ]]; then
      break
    fi
  fi
  sleep 1
done

writer_logs="$(kubectl logs krust-k3s-log-writer --tail=5 2>/dev/null || true)"
if [[ "${writer_logs}" != *"krust-log-reopen-proof"* ]]; then
  echo "log writer pod did not produce initial logs" >&2
  kubectl describe pod krust-k3s-log-writer >&2 || true
  exit 1
fi

WRITER_CONTAINER_ID="$(crictl ps --name '^writer$' --quiet | head -n 1)"
if [[ -z "${WRITER_CONTAINER_ID}" ]]; then
  echo "failed to find writer container id" >&2
  crictl ps -a >&2 || true
  exit 1
fi

echo "==> Verify live container stats"
WRITER_STATS_JSON="$(crictl stats -o json "${WRITER_CONTAINER_ID}")"
WRITER_STATS_ID="$(printf '%s\n' "${WRITER_STATS_JSON}" | "${JQ}" -r '.stats[0].attributes.id // ""')"
WRITER_CPU_USAGE="$(printf '%s\n' "${WRITER_STATS_JSON}" | "${JQ}" -r '.stats[0].cpu.usageCoreNanoSeconds.value // ""')"
WRITER_MEMORY_USAGE="$(printf '%s\n' "${WRITER_STATS_JSON}" | "${JQ}" -r '.stats[0].memory.usageBytes.value // ""')"
if [[ "${WRITER_STATS_ID}" != "${WRITER_CONTAINER_ID}" || ! "${WRITER_CPU_USAGE}" =~ ^[0-9]+$ || ! "${WRITER_MEMORY_USAGE}" =~ ^[0-9]+$ ]]; then
  echo "container stats mismatch: id=${WRITER_STATS_ID} cpu=${WRITER_CPU_USAGE} memory=${WRITER_MEMORY_USAGE}" >&2
  printf '%s\n' "${WRITER_STATS_JSON}" >&2
  exit 1
fi
echo "container stats verified: cpuCoreNs=${WRITER_CPU_USAGE} memoryBytes=${WRITER_MEMORY_USAGE}"

WRITER_LOG_PATH="$(crictl inspect -o json "${WRITER_CONTAINER_ID}" | "${JQ}" -r '(if type == "array" then .[0] else . end).status.logPath // ""')"
if [[ -z "${WRITER_LOG_PATH}" || ! -f "${WRITER_LOG_PATH}" ]]; then
  echo "failed to resolve writer log path: ${WRITER_LOG_PATH}" >&2
  crictl inspect "${WRITER_CONTAINER_ID}" >&2 || true
  exit 1
fi

mv "${WRITER_LOG_PATH}" "${WRITER_LOG_PATH}.rotated"
crictl logs --reopen "${WRITER_CONTAINER_ID}" >/dev/null

for _ in $(seq 1 60); do
  if [[ -f "${WRITER_LOG_PATH}" ]] && grep -q "krust-log-reopen-proof" "${WRITER_LOG_PATH}"; then
    writer_logs="$(kubectl logs krust-k3s-log-writer --tail=5 2>/dev/null || true)"
    if [[ "${writer_logs}" == *"krust-log-reopen-proof"* ]]; then
      echo "live log reopen after rotation verified"
      kubectl get pods -o wide
      echo "k3s single-node krust-cri pod-to-pod smoke test complete"
      exit 0
    fi
  fi
  sleep 1
done

echo "writer log did not resume after reopen" >&2
echo "--- rotated log ---" >&2
cat "${WRITER_LOG_PATH}.rotated" >&2 || true
echo "--- current log ---" >&2
cat "${WRITER_LOG_PATH}" >&2 || true
kubectl logs krust-k3s-log-writer --tail=20 >&2 || true
exit 1
