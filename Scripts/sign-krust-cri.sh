#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${1:-${ROOT_DIR}/.build/debug/krust-cri}"
ENTITLEMENTS="${ROOT_DIR}/signing/krust-cri.entitlements"

if [[ ! -f "${BINARY}" ]]; then
  echo "binary not found: ${BINARY}" >&2
  exit 1
fi

codesign --force --sign - --timestamp=none --entitlements "${ENTITLEMENTS}" "${BINARY}"
codesign --verify --strict --verbose=2 "${BINARY}"
