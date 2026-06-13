# Apple Containerization API Research for a macOS CRI

Generated: 2026-06-13

Local clone:

- Repository: https://github.com/apple/containerization
- Path: `containerization`
- Branch: `main`
- Commit inspected: `1437c67f5a07cb39e8f5e79d0b5aeac0327932bd`

## Executive summary

Apple's `containerization` package is a strong substrate for a CRI on Apple silicon macOS, but it is not itself a CRI runtime. Its core model is Linux workloads inside lightweight VMs using `Virtualization.framework`, with a small Linux guest agent (`vminitd`) controlled via gRPC over vsock. That gives us the right building blocks for pod/container lifecycle, OCI image handling, rootfs creation, exec/attach, stats, networking, and filesystem sharing.

The biggest architectural decision is whether one Kubernetes PodSandbox maps to:

1. `LinuxPod`: one VM per pod, multiple containers inside the VM.
2. `LinuxContainer`: one VM per container.

For Kubernetes semantics, `LinuxPod` is the better starting point because CRI is pod-sandbox-first and Kubernetes expects containers in a pod to share at least the pod network namespace, optionally PID namespace, and shared volumes. `LinuxContainer` is simpler but maps poorly to pod-level networking and sidecars unless we deliberately accept a nonstandard single-container-per-pod runtime.

## API areas to research

### 1. CRI API surface

Research source:

- Kubernetes CRI concept docs: https://kubernetes.io/docs/concepts/containers/cri/
- CRI proto: https://github.com/kubernetes/cri-api
- Raw proto inspected: https://raw.githubusercontent.com/kubernetes/cri-api/master/pkg/apis/runtime/v1/api.proto

CRI endpoints we need to implement or intentionally return unsupported for:

- RuntimeService lifecycle: `Version`, `Status`, `RuntimeConfig`, `UpdateRuntimeConfig`.
- Pod sandbox: `RunPodSandbox`, `StopPodSandbox`, `RemovePodSandbox`, `PodSandboxStatus`, `ListPodSandbox`, `StreamPodSandboxes`.
- Container lifecycle: `CreateContainer`, `StartContainer`, `StopContainer`, `RemoveContainer`, `ListContainers`, `StreamContainers`, `ContainerStatus`.
- Resource updates: `UpdateContainerResources`, `UpdatePodSandboxResources`.
- Streaming operations: `ExecSync`, `Exec`, `Attach`, `PortForward`.
- Logs: `ReopenContainerLog`.
- Stats/events/metrics: `ContainerStats`, `ListContainerStats`, `StreamContainerStats`, `PodSandboxStats`, `ListPodSandboxStats`, `StreamPodSandboxStats`, `GetContainerEvents`, `ListMetricDescriptors`, `ListPodSandboxMetrics`, `StreamPodSandboxMetrics`.
- Images: `ListImages`, `StreamImages`, `ImageStatus`, `PullImage`, `RemoveImage`, `ImageFsInfo`.
- Probably unsupported initially: `CheckpointContainer`, some metrics descriptors, full host namespace modes, SELinux/AppArmor, and advanced user namespace/idmapped mount behavior.

Critical CRI semantics to prove:

- Idempotency for stop/remove calls.
- State recovery after daemon restart.
- Correct `created_at`, labels, annotations, metadata, runtime handler.
- `PullImageResponse.image_ref` matching `Image.id`, `Container.image_id`, and `ContainerStatus.image_id`.
- List streaming fallback behavior for Kubernetes 1.36+.

### 2. Apple `Containerization` runtime API

Research source:

- Local README: `containerization/README.md`
- Apple API docs: https://apple.github.io/containerization/documentation/containerization/

Important types:

- `ContainerManager`: creates containers from OCI images, pulls images, unpacks rootfs, allocates network, deletes local state.
- `LinuxPod`: experimental pod abstraction. One VM, multiple containers, shared CPU/memory/network, optional shared PID namespace, pod volumes, per-container rootfs/process/mounts.
- `LinuxContainer`: single-container lifecycle abstraction. Create/start/stop/kill/wait/exec/resize/copy/statistics.
- `LinuxProcess`: process lifecycle, stdio through vsock, kill/wait/resize/delete.
- `LinuxProcessConfiguration`: command, env, cwd, user, rlimits, capabilities, no-new-privileges, terminal, stdin/stdout/stderr.
- `ContainerStatistics`: process, memory, CPU, block I/O, network, memory events.
- `ImageStore`: OCI pull/list/tag/delete/push/load/save using local content store.
- `EXT4Unpacker`: unpacks OCI layers into ext4 block images.
- `InitImage`: builds/loads guest init filesystem containing `vminitd`.

CRI mapping:

- `RunPodSandbox` -> create `LinuxPod`, configure VM, network, DNS, hosts, pod resources.
- `CreateContainer` -> `LinuxPod.registerContainer` / equivalent create path with rootfs, process config, mounts.
- `StartContainer` -> `LinuxPod.startContainer`.
- `StopContainer` -> `LinuxPod.stopContainer` with CRI grace period handling.
- `RemoveContainer` -> delete process/container state and release hotplugged devices.
- `ExecSync` / `Exec` -> `LinuxPod.execInContainer` plus streaming server.
- `Attach` -> needs mapping to existing stdio/log streams, not just new process exec.
- `PortForward` -> likely vsock bridge plus host TCP listener, or vmnet route/NAT forwarding.
- `ContainerStats` / pod stats -> `LinuxPod.statistics` and aggregation.
- `PullImage` / `ImageStatus` / `ListImages` / `RemoveImage` -> `ImageStore`.
- `ImageFsInfo` -> filesystem accounting for `ImageStore.path` and rootfs/container state.

### 3. macOS `Virtualization.framework`

Research source:

- Apple Virtualization docs: https://developer.apple.com/documentation/virtualization
- `VZVirtualMachineConfiguration`: https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration
- `VZVmnetNetworkDeviceAttachment`: https://developer.apple.com/documentation/virtualization/vzvmnetnetworkdeviceattachment
- Local implementation: `VZVirtualMachineInstance`, `VZVirtualMachineManager`, `VZVirtualMachine+Helpers`.

APIs used by the package:

- `VZVirtualMachine`, start/stop/pause/resume.
- `VZVirtualMachineConfiguration`, validation, CPU/memory limits, boot loader, devices.
- `VZLinuxBootLoader`, custom Linux kernel command line.
- `VZGenericPlatformConfiguration`, including nested virtualization support checks.
- `VZVirtioSocketDeviceConfiguration`, `VZVirtioSocketDevice`, `VZVirtioSocketConnection`, `VZVirtioSocketListener` for host <-> guest control/data channels.
- `VZVirtioBlockDeviceConfiguration`.
- `VZDiskImageStorageDeviceAttachment`, including caching and synchronization modes.
- `VZNetworkBlockDeviceStorageDeviceAttachment` for NBD-backed volumes.
- `VZVirtioFileSystemDeviceConfiguration`, `VZMultipleDirectoryShare`, `VZSharedDirectory` for virtiofs directory sharing.
- `VZVirtioEntropyDeviceConfiguration`.
- `VZVirtioConsoleDeviceSerialPortConfiguration`, `VZFileSerialPortAttachment`, `VZFileHandleSerialPortAttachment` for boot logs.
- `VZLinuxRosettaDirectoryShare` for linux/amd64 on Apple silicon.

Research questions:

- What macOS 26 APIs are hard requirements versus portable to macOS 15 package minimum?
- What entitlements are required for distribution and launchd daemon usage?
- Does pause/resume have stable semantics for CRI, or should it be runtime-internal only?
- How reliable are virtiofs hotplug and block hotplug for Kubernetes volume churn?
- What are the performance and data-safety tradeoffs for disk image caching/sync modes?
- Can we expose boot logs and VM failure causes enough for kubelet diagnostics?
- How should Rosetta be surfaced through RuntimeClass?
- Can we support nested virtualization via RuntimeClass without surprising resource usage?

### 4. macOS `vmnet` networking

Research source:

- Apple vmnet docs: https://developer.apple.com/documentation/vmnet
- Local implementation: `VmnetNetwork`, `NATNetworkInterface`, `Interface`, `Network`.

APIs used:

- `vmnet_network_configuration_create`.
- `vmnet_network_configuration_disable_dhcp`.
- `vmnet_network_create`.
- `vmnet_network_get_ipv4_subnet`.
- `vmnet_network_get_ipv6_prefix`.
- `VZVmnetNetworkDeviceAttachment`.

Research questions:

- How to map CRI `PortMapping` to macOS host ports. `vmnet` shared mode is not automatically Kubernetes-style port forwarding.
- Whether to integrate CNI at all. CRI expects runtime + CNI behavior on Linux nodes, but macOS host networking is not Linux CNI-native.
- How to provide pod IPs and routes that kubelet accepts.
- Whether `hostNetwork` can be supported. Likely no, or only with a very narrow approximation.
- How DNS should be configured: Kubernetes cluster DNS vs `vmnet` gateway DNS.
- Cleanup guarantees when a sandbox VM crashes.
- IPv6 support and dual-stack correctness.
- Firewall/NAT behavior with localhost, LAN, and service IP ranges.

### 5. Guest agent and vsock API

Research source:

- Local proto: `Sources/Containerization/SandboxContext/SandboxContext.proto`
- Local client: `Sources/Containerization/Vminitd.swift`
- Local server: `vminitd/Sources/VminitdCore/Server+GRPC.swift`

Guest operations available:

- Mount/umount, mkdir, write file, stat, copy in/out, sync.
- Create/start/wait/kill/delete/resize process.
- Close stdin.
- Container statistics.
- Proxy vsock to Unix sockets.
- IP link/address/route configuration.
- DNS and hosts file configuration.
- Sysctl and time setup.
- Rosetta/binfmt setup.

Research questions:

- Can the agent safely support all CRI exec/attach streaming modes, including terminal resize, stdin close, and cancellation?
- Does `waitProcess` need timeout support in proto? Local Swift interface accepts timeout, but the proto request currently only includes IDs.
- How are container logs persisted to CRI log paths? Current stdio is writer/terminal-oriented; kubelet expects log files and `ReopenContainerLog`.
- Does vminitd expose enough eventing for `GetContainerEvents`, or do we need a host-side event bus?
- Can all cleanup paths be made idempotent after partial failures?

### 6. Storage and volume semantics

Research source:

- Local `Mount`, `AttachedFilesystem`, `FileMount`, `docs/single-file-mounts.md`, `LinuxPod.PodVolume`.

Available mechanisms:

- Rootfs as ext4 block file.
- Optional writable ext4 layer using overlayfs.
- Host directory sharing via virtiofs.
- Single-file mounts implemented as parent-directory virtiofs share plus bind mount.
- Pod volumes backed by NBD.
- Hotplug block and virtiofs support through `VirtualMachineInstance`.

Research questions:

- Kubernetes `hostPath`, `emptyDir`, projected configmaps/secrets, service account tokens, subPath, image volumes.
- Whether single-file mount parent-directory exposure is acceptable for Kubernetes secrets/configmaps.
- Read-only recursive mounts, mount propagation, idmapped mounts, UID/GID mappings.
- fsGroup, supplemental groups, ownership changes, and performance for large trees.
- Volume cleanup and consistency on VM crash.
- Image volume mount support from CRI v1.33+.

### 7. Linux security/resource model inside the guest

Research source:

- Local `LinuxProcessConfiguration`, `Capabilities`, `Cgroup2Manager`, `ContainerStatistics`.
- CRI `LinuxContainerResources`, `LinuxContainerSecurityContext`, `LinuxSandboxSecurityContext`.

Research questions:

- Map CRI resources to cgroup v2: CPU quota/period, cpuset, memory/swap, pids, hugepages, unified settings.
- Implement `UpdateContainerResources` and `UpdatePodSandboxResources`.
- Capabilities default: current convenience default is all capabilities, but Kubernetes default should be restricted.
- `privileged`, `no_new_privileges`, seccomp, AppArmor, SELinux: likely partial/unsupported on macOS host, but seccomp may be guest-supported.
- User namespace modes and host namespace modes.
- PID namespace sharing in `LinuxPod.shareProcessNamespace`.
- IPC namespace sharing: verify if supported by generated OCI spec/runtime path.

### 8. Runtime state, daemon, and kubelet integration

Research questions:

- Swift vs Go implementation. Swift can consume Apple APIs directly; Go CRI server would need a Swift helper/daemon boundary.
- Persistent state DB schema: sandboxes, containers, images, rootfs paths, VM state, network allocations, log paths, timestamps.
- Recovery after daemon restart: reconstruct state, stop orphan VMs, or reconnect if possible.
- Socket path and launchd service model, likely `/var/run/...` or user-level socket depending target.
- macOS permissions: root daemon vs user agent. Kubernetes kubelet generally expects a node-level runtime.
- Conformance strategy with `crictl`, kubelet smoke tests, and eventually Kubernetes node e2e subset.

## Proposed POC order

1. Build a minimal CRI `RuntimeService` + `ImageService` server that returns `Version`, `Status`, and can `PullImage`/`ListImages` through `ImageStore`.
2. Implement `RunPodSandbox` using `LinuxPod` with one VM per pod and no containers yet.
3. Implement `CreateContainer`, `StartContainer`, `StopContainer`, `RemoveContainer` for one simple Alpine pod.
4. Implement CRI log file writing before exec/attach. Kubelet log semantics should be proven early.
5. Implement `ExecSync`, then streaming `Exec`/`Attach`.
6. Add basic stats and status/list APIs.
7. Add networking: pod IP reporting, DNS, and minimal port-forward.
8. Add volume matrix tests: directory, file, readonly, configmap-like, secret-like, emptyDir-like.
9. Run `crictl` and kubelet smoke tests against the socket.

## Initial risk register

- `LinuxPod` is marked experimental; API stability and correctness risk are high.
- macOS 26/Xcode 26 requirements may make distribution and CI harder.
- CRI requires Kubernetes-specific behavior; the upstream CRI repo explicitly warns it is not a general-purpose runtime API.
- Host networking/CNI semantics on macOS are the largest compatibility gap.
- Logging and streaming are not solved by `Containerization` as-is.
- State recovery is not provided by the library and must be designed by us.
- Security defaults need tightening; current examples often use all capabilities for convenience.
