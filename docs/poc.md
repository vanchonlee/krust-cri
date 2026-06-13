# krust-cri PoC Status

This document records what the current proof of concept proves and what remains
outside the proof.

## Summary

The current PoC proves that a macOS-hosted Swift CRI daemon can be used by a
single-node k3s server running inside an Apple Containerization `LinuxPod`.

The verified path is:

```text
macOS host
  krust-cri
    - CRI runtime.v1 Unix socket
    - Apple Containerization backend
    - VmnetNetwork pod networking

LinuxPod control VM
  k3s server
    - embedded kubelet
    - CRI socket relayed from macOS host

workload pods
  Kubernetes API creates pods
  kubelet calls krust-cri
  krust-cri creates Apple LinuxPod sandboxes
  pod-to-pod traffic works by direct pod IP
```

## Verified Evidence

The main smoke test is:

```bash
Scripts/smoke-k3s-single-node.sh
```

The successful run showed:

```text
NAME          STATUS   VERSION        CONTAINER-RUNTIME
krust-macos   Ready    v1.35.0+k3s1   krust-cri://0.1.0-mvp

server pod ip=192.168.64.2
/tmp/krust-cri-k3s-logs/.../client/0.log: hello-from-k3s-pod-a

krust-k3s-client   0/1 Completed IP 192.168.64.3
krust-k3s-server   1/1 Running   IP 192.168.64.2

k3s single-node krust-cri pod-to-pod smoke test complete
```

This proves:

- k3s can start inside an Apple `LinuxPod`.
- The k3s node can register as `krust-macos`.
- Kubelet sees `krust-cri` as the node container runtime.
- Kubernetes API pod creation reaches kubelet.
- Kubelet calls the host `krust-cri` socket through Apple socket relay.
- `krust-cri` creates workload pod sandboxes through Apple `LinuxPod`.
- Apple `VmnetNetwork` assigns pod IPs.
- Direct pod-to-pod TCP works on the same node.
- CRI log output captures the pod-to-pod proof payload.
- Container process exit is observed through Apple Containerization and
  reflected back to kubelet, so the client pod reaches `Completed`.

## Supporting Smokes

`Scripts/smoke-containerization-network.sh`

Proves same-node pod-to-pod networking through `crictl` without k3s:

```text
server pod ip=192.168.64.2
hello-from-krust-pod-a
```

`Scripts/smoke-kubelet-static-pods.sh`

Runs a Linux kubelet inside an Apple `LinuxPod` with the host CRI socket relayed
into the guest. It creates static pods through kubelet and proves direct
pod-to-pod traffic.

`Scripts/smoke-critest-basic.sh`

Covers the focused CRI contract that the MVP currently implements.

## Required Local Assets

The k3s smoke expects these local assets:

- Apple Containerization kernel at `containerization/bin/vmlinux`.
- Init image reference `vminit:latest` in the Apple Containerization image
  store.
- `crictl` at `.local/bin/crictl`.
- Linux arm64 k3s binary at `.local/bin/k3s-linux-arm64`.
- `kubectl` available in PATH, `/opt/homebrew/bin/kubectl`, or
  `/usr/local/bin/kubectl`.

The smoke script copies and signs the runnable binaries under `/private/tmp`
because local vmnet development is sensitive to signing and execution location.

## Current Limitations

The PoC intentionally does not claim full Kubernetes node support yet.

Known gaps:

- Container process exit monitoring is implemented for the Apple
  Containerization backend, but restart policy behavior and richer termination
  reasons still need hardening.
- `kubectl logs` needs more hardening around CRI log path behavior and log
  reopen semantics.
- DNS is not part of the current network proof; the k3s smoke uses direct pod
  IP traffic.
- Service networking is disabled for the smoke and remains a separate milestone.
- Multi-node pod routing is not implemented.
- Resource stats are minimal and not yet suitable for real scheduling pressure.
- Recovery after daemon restart, orphan cleanup, GC, volumes, security context,
  and RuntimeClass are not production-ready.

## Next Milestone

The next technical milestone should make kubelet logs and restart semantics
more complete:

- make `kubectl logs` work reliably for the k3s smoke,
- implement `ReopenContainerLog`,
- harden restart policy behavior,
- preserve richer termination reasons,
- keep the existing pod-to-pod proof passing.
