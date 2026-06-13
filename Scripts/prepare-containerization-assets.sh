#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINERIZATION_DIR="${ROOT_DIR}/containerization"
KERNEL_PATH="${CONTAINERIZATION_DIR}/bin/vmlinux"
INIT_REFERENCE="${KRUST_CRI_INITFS_REFERENCE:-vminit:latest}"
IMAGE_ROOT="${KRUST_CRI_CONTAINERIZATION_ROOT:-${HOME}/Library/Application Support/com.apple.containerization}"

if [[ ! -d "${CONTAINERIZATION_DIR}" ]]; then
  echo "containerization checkout not found at ${CONTAINERIZATION_DIR}" >&2
  exit 1
fi

echo "==> Preparing default Kata kernel"
make -C "${CONTAINERIZATION_DIR}" fetch-default-kernel

echo "==> Preparing vminit image ${INIT_REFERENCE}"
if ! command -v container >/dev/null 2>&1; then
  echo "warning: apple/container CLI is not installed or not in PATH." >&2
  echo "warning: containerization's cross-prep/init targets need it for the Linux build container." >&2
fi

make -C "${CONTAINERIZATION_DIR}" cross-prep
make -C "${CONTAINERIZATION_DIR}" init

echo
echo "Prepared Containerization assets:"
echo "  kernel:              ${KERNEL_PATH}"
echo "  init image:          ${INIT_REFERENCE}"
echo "  image/rootfs store:  ${IMAGE_ROOT}"
echo
echo "Run krust-cri with:"
echo "  .build/debug/krust-cri \\"
echo "    --listen /tmp/krust-cri.sock \\"
echo "    --state-dir /tmp/krust-cri-state \\"
echo "    --backend containerization \\"
echo "    --kernel \"${KERNEL_PATH}\" \\"
echo "    --initfs-reference ${INIT_REFERENCE} \\"
echo "    --containerization-root \"${IMAGE_ROOT}\""
