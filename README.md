# krust-cri

`krust-cri` is a proof-of-concept Kubernetes Container Runtime Interface (CRI)
implementation for macOS.

The project explores whether macOS can host a CRI runtime by combining:

- the official Kubernetes CRI `runtime.v1` gRPC API,
- Swift as the daemon/runtime implementation language,
- Apple `Containerization` and `LinuxPod` as the Linux execution layer,
- `crictl`, kubelet, and k3s as compatibility test clients.

The current MVP proves that a Swift daemon on macOS can expose a CRI Unix socket,
accept `crictl` and kubelet calls, route pod/container lifecycle through Apple
Containerization, and let a single-node k3s server create pods whose direct
pod-to-pod traffic works through Apple `VmnetNetwork`.

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

See [docs/architecture.md](docs/architecture.md) for the planned node/cluster
architecture, CRI mapping, networking strategy, and roadmap toward k3s/kubelet
integration.

See [docs/poc.md](docs/poc.md) for the verified PoC commands and evidence.

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
- Focused `critest` smoke test for the CRI contract covered by the current MVP:
  runtime info, pod sandbox lifecycle, container lifecycle, and idempotence.
- Same-node pod-to-pod network smoke test through Apple `VmnetNetwork` when the
  signed development binary is run from `/private/tmp`.
- Kubelet static-pod smoke path using a Linux kubelet inside an Apple
  `LinuxPod` with the host `krust-cri` socket relayed into the guest.
- Single-node k3s server smoke path using a Linux k3s binary inside an Apple
  `LinuxPod`; the node registers with `CONTAINER-RUNTIME=krust-cri://0.1.0-mvp`,
  Kubernetes creates two pods, and the client pod reaches the server pod by
  direct pod IP.

Streaming exec, attach, port-forward, checkpoint, events, and deeper stats are
intentionally minimal in the state-backed MVP backend.

The Apple backend can run the MVP lifecycle without VM networking and reports
`NetworkReady=false` when `VmnetNetwork` is unavailable. On the verified macOS
26 development path, the smoke script copies and signs the binary under
`/private/tmp`, `VmnetNetwork` initializes, and direct pod-to-pod traffic works
through the vmnet pod IP reported by CRI.

## Roadmap

Short version: make the CRI surface honest first, then deepen the Apple backend.

1. MVP proof, now: prove the daemon can speak CRI and run the basic
   `crictl` pod/container lifecycle through Apple Containerization.
2. Runtime correctness: map container exit state, errors, logs, and stats back
   into CRI more accurately.
3. Networking: harden the current vmnet pod-to-pod PoC, then add DNS, port
   mappings, service networking, and multi-node routing deliberately.
4. Kubelet/k3s path, now proven as PoC: keep closing the missing CRI semantics
   kubelet expects, especially container exit monitoring and richer logs/stats.
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

Run the smoke scripts after building. The Containerization scripts also require
the prepared kernel and init image:

```bash
Scripts/smoke-kubelet-cri-surface.sh
Scripts/smoke-critest-basic.sh
Scripts/smoke-containerization-backend.sh
Scripts/smoke-containerization-network.sh
Scripts/smoke-kubelet-static-pods.sh
Scripts/smoke-k3s-single-node.sh
```

`smoke-critest-basic.sh` expects `critest` from the matching cri-tools release
in `.local/bin`.

## Open Gaps

Harden the Apple Containerization backend beyond the MVP demo:

- Harden vmnet packaging/signing beyond the `/private/tmp` development smoke
  path.
- Add DNS, port mappings, service networking, and multi-node routing.
- Map container exit status back into CRI state. The k3s PoC currently proves
  pod-to-pod traffic through CRI logs while the client pod may remain `Running`
  until process lifecycle watching is implemented.
- Implement `ContainerStats` from `LinuxPod.statistics`.
- Improve `kubectl logs`/log reopen behavior and Kubernetes status fidelity.
