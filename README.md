# krust-cri

`krust-cri` is a proof-of-concept Kubernetes Container Runtime Interface (CRI)
implementation for macOS.

The project explores whether macOS can host a CRI runtime by combining:

- the official Kubernetes CRI `runtime.v1` gRPC API,
- Swift as the daemon/runtime implementation language,
- Apple `Containerization` and `LinuxPod` as the Linux execution layer,
- `crictl` as the first compatibility test client.

The current MVP proves that a Swift daemon on macOS can expose a CRI Unix socket,
accept `crictl` calls, create a pod sandbox, create/start/inspect/stop/remove a
container, and route that lifecycle through Apple Containerization.

## Why

Kubernetes assumes Linux container runtimes. macOS developers usually rely on a
Linux VM plus containerd, Docker Desktop, Lima, Colima, or similar layers.

This repo asks a narrower research question:

Can we build a small CRI runtime that speaks Kubernetes directly on macOS while
using Apple's native virtualization/container APIs underneath?

If the answer is yes, this can become a foundation for local Kubernetes runtime
experiments, lighter macOS developer environments, and deeper research into what
Apple Containerization can and cannot provide for Kubernetes-style workloads.

## Architecture

`krust-cri` has two runtime backends:

- `mvp`: a state-backed backend for fast CRI API development and `crictl`
  compatibility checks.
- `containerization`: an experimental backend that uses Apple `Containerization`
  and `LinuxPod` for the real Linux pod/container execution path.

## What Works Now

- Official CRI protobuf/service names from Kubernetes `runtime.v1`.
- Unix socket gRPC server.
- `Version` and `Status`.
- Pod sandbox create/stop/remove/status/list/stream.
- Container create/start/stop/remove/status/list/stream.
- Image pull/list/status/remove using local runtime state.
- Basic container stats responses.
- Persistent JSON state under `--state-dir`.
- Experimental `--backend containerization` bridge to Apple `Containerization`
  and `LinuxPod`.
- End-to-end `crictl` smoke test for the Apple backend:
  `pull -> runp -> create -> start -> inspect -> stop -> rm`.

Streaming exec, attach, port-forward, checkpoint, events, and deeper stats are
intentionally minimal in the state-backed MVP backend.

The Apple backend can run the MVP lifecycle without VM networking. `VmnetNetwork`
currently reports unavailable on machines without the restricted Apple vmnet
entitlement, so `crictl info` will show `NetworkReady=false` while
`RuntimeReady=true`.

## Roadmap

Short version: make the CRI surface honest first, then deepen the Apple backend.

1. MVP proof, now: prove the daemon can speak CRI and run the basic
   `crictl` pod/container lifecycle through Apple Containerization.
2. Runtime correctness: map container exit state, errors, logs, and stats back
   into CRI more accurately.
3. Networking: decide between proper vmnet entitlement, alternate network
   plumbing, or a documented no-network mode for local-only workloads.
4. Kubelet path: run against kubelet instead of only `crictl`, then close the
   missing CRI calls kubelet actually requires.
5. Developer experience: package assets, signing, config, smoke tests, and
   diagnostics into a repeatable local setup.

## Build

```bash
Scripts/generate-protos.sh
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" \
  swift build --cache-path "$PWD/.build/swiftpm-cache"
```

## Run

State-backed backend for CRI conformance smoke tests:

```bash
.build/debug/krust-cri \
  --listen /tmp/krust-cri.sock \
  --state-dir /tmp/krust-cri-state \
  --backend mvp
```

Apple Containerization backend:

```bash
Scripts/prepare-containerization-assets.sh
Scripts/sign-krust-cri.sh

.build/debug/krust-cri \
  --listen /tmp/krust-cri.sock \
  --state-dir /tmp/krust-cri-state \
  --backend containerization \
  --kernel containerization/bin/vmlinux \
  --initfs-reference vminit:latest \
  --containerization-root "$HOME/Library/Application Support/com.apple.containerization"
```

With `crictl` installed:

```bash
crictl --runtime-endpoint unix:///tmp/krust-cri.sock version
crictl --runtime-endpoint unix:///tmp/krust-cri.sock info
crictl --runtime-endpoint unix:///tmp/krust-cri.sock pull docker.io/library/alpine:3.20
crictl --runtime-endpoint unix:///tmp/krust-cri.sock images
```

For the Apple Containerization backend, run the end-to-end smoke script after
preparing the kernel and init image:

```bash
Scripts/smoke-containerization-backend.sh
```

## Open Gaps

Harden the Apple Containerization backend beyond the MVP demo:

- Decide the networking path: proper vmnet entitlement, alternate network
  plumbing, or a documented no-network MVP mode.
- Map container exit status back into CRI state.
- Implement `ContainerStats` from `LinuxPod.statistics`.
- Add a scripted `crictl` smoke test for the state-backed `mvp` backend too.
