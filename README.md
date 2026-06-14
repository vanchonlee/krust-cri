# krust-cri

`krust-cri` is an experimental Kubernetes Container Runtime Interface (CRI)
runtime for macOS.

It exposes the official Kubernetes `runtime.v1` CRI API over a Unix socket and
runs Linux workloads through Apple's open-source
[Containerization](https://github.com/apple/containerization) package and
`Virtualization.framework`.

The important distinction: tools like Lima, Colima, and Docker Desktop give you
a Linux machine or a Linux container engine on macOS. `krust-cri` is testing a
different boundary. It asks whether kubelet can talk directly to a macOS-hosted
CRI runtime, with that runtime driving Apple Containerization underneath.

The current demo path is intentionally simple:

```text
macOS host
  -> krust-cri CRI socket
  -> Apple Containerization backend
  -> k3s/kubelet creates pods
  -> kubectl verifies workload behavior
```

This is a proof of concept, not a production Kubernetes runtime.

What Kubernetes sees:

```text
NAME          STATUS   ROLES    AGE   VERSION        INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION   CONTAINER-RUNTIME
krust-macos   Ready    <none>   0s    v1.35.0+k3s1   192.168.65.2   <none>        Debian GNU/Linux 12 (bookworm)   6.12.28          krust-cri://0.1.0-mvp
```

## How It Differs From Lima

Lima launches Linux virtual machines. You can run containerd, Docker, k3s, or
other Linux software inside those VMs.

`krust-cri` is not a VM manager and does not try to replace Lima. Its focus is
the Kubernetes runtime contract:

```text
kubelet
  -> CRI runtime.v1 socket
  -> krust-cri on macOS
  -> Apple Containerization / LinuxPod
```

That means the interesting part of this project is not "can macOS run a Linux
VM?" It is "can macOS host the CRI runtime that kubelet expects?"

## Current Status

Verified on the local development path:

- `krust-cri` starts a CRI `runtime.v1` Unix socket on macOS.
- `crictl`, kubelet, and k3s can talk to that socket.
- A Linux arm64 k3s server can run inside an Apple `LinuxPod`.
- k3s registers a node with `CONTAINER-RUNTIME=krust-cri://0.1.0-mvp`.
- `kubectl apply` can create workload pods through kubelet and `krust-cri`.
- Same-node pod-to-pod TCP works through Apple `VmnetNetwork` pod IPs.
- CRI logs work, including `ReopenContainerLog` for live log rotation.
- Container exit status is visible to kubelet, including non-zero exit codes.
- Basic `restartPolicy: OnFailure` reaches `CrashLoopBackOff` instead of
  runtime create/start errors.
- Live Apple backend `ContainerStats` returns CPU and memory usage from
  `LinuxPod.statistics`.

Still missing or incomplete:

- DNS and Kubernetes service networking.
- Port mappings and multi-node pod routing.
- Full pod sandbox stats and broader resource accounting.
- Multi-container/sidecar restart hardening.
- Daemon restart recovery, orphan cleanup, GC, volumes, security context, and
  RuntimeClass behavior.
- Release packaging/signing beyond the local `/private/tmp` smoke path.

## Demo With k3s

The main demo is:

```bash
Scripts/smoke-k3s-single-node.sh
```

It builds a single-node k3s setup where:

1. `krust-cri` runs on the macOS host.
2. k3s runs inside an Apple `LinuxPod`.
3. the k3s kubelet reaches the host CRI socket through Apple socket relay.
4. `kubectl` creates pods.
5. the smoke verifies pod-to-pod networking, logs, exit status, restart behavior,
   live stats, and log reopen.

Recent successful output:

```text
NAME          STATUS   ROLES    AGE   VERSION        INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION   CONTAINER-RUNTIME
krust-macos   Ready    <none>   0s    v1.35.0+k3s1   192.168.65.2   <none>        Debian GNU/Linux 12 (bookworm)   6.12.28          krust-cri://0.1.0-mvp

hello-from-k3s-pod-a
OnFailure restart verified: restartCount=1
container stats verified: cpuCoreNs=8709000 memoryBytes=5890048
live log reopen after rotation verified

NAME                   READY   STATUS      RESTARTS     AGE   IP             NODE
krust-k3s-client       0/1     Completed   0            14s   192.168.64.3   krust-macos
krust-k3s-fail         0/1     Error       0            10s   192.168.64.4   krust-macos
krust-k3s-log-writer   1/1     Running     0            4s    192.168.64.6   krust-macos
krust-k3s-restart      0/1     Error       1 (6s ago)   7s    192.168.64.5   krust-macos
krust-k3s-server       1/1     Running     0            16s   192.168.64.2   krust-macos

k3s single-node krust-cri pod-to-pod smoke test complete
```

## Requirements

- Apple silicon Mac.
- macOS 26 and Xcode 26 for Apple Containerization.
- SwiftPM.
- `kubectl`.
- `jq`.
- Local cri-tools binaries under `.local/bin`, including `crictl`.
- Linux arm64 k3s binary at `.local/bin/k3s-linux-arm64`.
- Apple Containerization kernel at `containerization/bin/vmlinux`.
- `vminit:latest` available in the local Apple Containerization image store.

Some local vmnet development flows require the runnable binaries to be copied
and signed under `/private/tmp`; the smoke scripts handle that.

## Build

```bash
Scripts/generate-protos.sh

env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" \
  swift build --cache-path "$PWD/.build/swiftpm-cache"
```

Run unit tests:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-module-cache" \
  SWIFTPM_CACHE_PATH="$PWD/.build/swiftpm-cache" \
  swift test --cache-path "$PWD/.build/swiftpm-cache"
```

## Run Manually

State-only backend for quick CRI API checks:

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

Then point `crictl` at the socket:

```bash
crictl --runtime-endpoint unix:///tmp/krust-cri.sock info
crictl --runtime-endpoint unix:///tmp/krust-cri.sock images
```

## Other Smoke Tests

```bash
Scripts/smoke-critest-basic.sh
Scripts/smoke-containerization-backend.sh
Scripts/smoke-containerization-network.sh
Scripts/smoke-kubelet-static-pods.sh
Scripts/smoke-k3s-single-node.sh
```

`Scripts/smoke-k3s-single-node.sh` is the most useful end-to-end demo for
people evaluating the project.

## Project Layout

- `Sources/KrustCRI`: CRI server, runtime state, image service, and backends.
- `Sources/KrustKubeletPod`: helper for running kubelet/k3s inside an Apple
  `LinuxPod`.
- `Protos/runtime/v1`: Kubernetes CRI protobuf definitions.
- `Scripts`: build, signing, and smoke-test helpers.
- `containerization`: Apple Containerization checkout/submodule.

## Roadmap

The next valuable milestones are:

- make DNS work for normal k3s pods,
- add a minimal service-networking story,
- implement port mappings,
- broaden stats and pod sandbox stats,
- harden multi-container restart behavior,
- package signing/setup into a repeatable open-source developer flow.

Live post-create `LinuxPod.addContainer` hotplug is not a committed MVP path.
Current public API review did not find a supported runtime virtio block attach
path for the Apple Containerization VZ backend.

## Contributing

Contributions should keep the project evidence-driven:

- prefer small CRI behavior improvements with smoke coverage,
- keep macOS/Apple API assumptions documented,
- run `swift test` before sending changes,
- use the k3s smoke when touching kubelet-facing lifecycle, logs, stats, or
  networking behavior.
