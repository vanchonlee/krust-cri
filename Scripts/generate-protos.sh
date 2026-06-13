#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_DIR="$ROOT_DIR/.local"
PROTOC_VERSION="26.1"
PROTOC_DIR="$LOCAL_DIR/bin/protoc@$PROTOC_VERSION"
PROTOC="$PROTOC_DIR/protoc"
PROTOC_ZIP="protoc-$PROTOC_VERSION-osx-universal_binary.zip"

cd "$ROOT_DIR"

if [[ ! -x "$PROTOC" ]]; then
  mkdir -p "$LOCAL_DIR"
  curl -L -o "$PROTOC_ZIP" "https://github.com/protocolbuffers/protobuf/releases/download/v$PROTOC_VERSION/$PROTOC_ZIP"
  mkdir -p "$PROTOC_DIR"
  unzip -jo "$PROTOC_ZIP" bin/protoc -d "$PROTOC_DIR"
  unzip -o "$PROTOC_ZIP" 'include/*' -d "$PROTOC_DIR"
  rm -f "$PROTOC_ZIP"
fi

swift build --product protoc-gen-swift
swift build --product protoc-gen-grpc-swift-2

PLUGIN_DIR="$ROOT_DIR/.build/debug"
OUT_DIR="$ROOT_DIR/Sources/KrustCRI/Generated"
mkdir -p "$OUT_DIR"

"$PROTOC" Protos/runtime/v1/api.proto \
  --plugin=protoc-gen-grpc-swift="$PLUGIN_DIR/protoc-gen-grpc-swift-2" \
  --plugin=protoc-gen-swift="$PLUGIN_DIR/protoc-gen-swift" \
  --proto_path=Protos \
  --proto_path="$PROTOC_DIR/include" \
  --grpc-swift_out="$OUT_DIR" \
  --grpc-swift_opt=Visibility=Internal \
  --swift_out="$OUT_DIR" \
  --swift_opt=Visibility=Internal
