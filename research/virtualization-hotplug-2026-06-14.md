# Virtualization Hotplug Research

Generated: 2026-06-14

## Question

Can `krust-cri` safely fork or extend Apple Containerization to implement live
container hotplug for `LinuxPod.addContainer` after `pod.create()`, using public
Virtualization.framework APIs?

## Finding

Do not build a public-product path on live `LinuxPod` container hotplug yet.

Apple Containerization now exposes hotplug interfaces, but the public VZ-backed
path does not install a concrete `HotplugProvider` by default. The local source
shows:

- `LinuxPod.addContainer` hotplugs when called after `create()`.
- `VZVirtualMachineInstance.hotplug` delegates to `hotplugProvider`.
- the default `VirtualMachineInstance.hotplug` throws `hotplug not supported`.
- `HotplugProvider` requires both block-device and virtiofs hotplug mechanics.

The public Virtualization.framework SDK exposes `VZVirtioBlockDeviceConfiguration`
as a VM configuration-time storage device. In the local macOS SDK headers,
`VZVirtualMachineConfiguration.storageDevices` is a configuration property, while
`VZVirtualMachine` does not expose a corresponding runtime attach API for virtio
block storage devices.

The public runtime storage attach path found in the SDK is USB:

- `VZVirtualMachine.usbControllers` exposes configured runtime USB controllers.
- `VZUSBController.attachDevice` and `detachDevice` attach/detach USB devices at
  runtime.
- `VZUSBMassStorageDevice` is documented in the SDK header as hot-pluggable.

That USB path is useful as a feasibility probe only. It is not the same as the
virtio block path Apple Containerization expects for Linux container rootfs
hotplug, and it would force `krust-cri` to guess guest device names or build a
side-channel discovery layer. That is too much speculative implementation for
the current MVP.

## Sources Checked

- Local Apple Containerization source:
  - `containerization/Sources/Containerization/LinuxPod.swift`
  - `containerization/Sources/Containerization/VZVirtualMachineInstance.swift`
  - `containerization/Sources/Containerization/VirtualMachineInstance.swift`
  - `containerization/Sources/Containerization/HotplugProvider.swift`
- Local Xcode SDK headers:
  - `Virtualization.framework/Headers/VZVirtualMachineConfiguration.h`
  - `Virtualization.framework/Headers/VZVirtualMachine.h`
  - `Virtualization.framework/Headers/VZUSBController.h`
  - `Virtualization.framework/Headers/VZUSBMassStorageDevice.h`
- Upstream Apple Containerization:
  - PR #740, "add hotplug interfaces for vmms", merged 2026-05-18:
    https://github.com/apple/containerization/pull/740
  - Issue #767, public `HotplugProvider` question, opened 2026-06-13:
    https://github.com/apple/containerization/issues/767

## Decision

For the MVP:

- Keep the current pod reset/recreate workaround for kubelet restart behavior.
- Do not fork Apple Containerization to implement virtio hotplug unless upstream
  confirms a supported public mechanism or ships a provider.
- Do not implement USB mass-storage rootfs hotplug as the main path.
- Spend engineering time on higher-value CRI behavior: logs, restart fidelity,
  stats, DNS, service networking, and rootfs creation/copy performance.

If hotplug is revisited later, the smallest useful spike is a diagnostic-only
`VZInstanceExtension` that proves a provider can be installed and records what
device path the guest observes. It should not be wired into `LinuxPod` container
start unless the guest path is discovered deterministically.
