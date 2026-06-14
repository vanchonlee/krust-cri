# k3s PoC Demo

This document records the main proof-of-concept demo for `krust-cri`.

The goal is to show that a macOS-hosted Swift CRI daemon can act as the
container runtime for a single-node k3s server, and that normal Kubernetes
commands can create and inspect pods through that runtime.

## What The Demo Runs

```text
macOS host
  krust-cri
    - CRI runtime.v1 Unix socket
    - Apple Containerization backend
    - VmnetNetwork pod networking

Apple LinuxPod control VM
  k3s server
    - embedded kubelet
    - host krust-cri socket relayed into the guest

workload pods
  kubectl apply
  -> k3s API
  -> kubelet
  -> krust-cri
  -> Apple LinuxPod sandboxes
```

The workload proof is intentionally direct:

- one pod runs BusyBox `httpd`,
- another pod fetches the server pod by pod IP,
- `kubectl logs` and CRI logs show `hello-from-k3s-pod-a`.

## Run The Demo

The end-to-end demo script is:

```bash
Scripts/smoke-k3s-single-node.sh
```

It expects:

- Apple Containerization kernel at `containerization/bin/vmlinux`,
- init image reference `vminit:latest` in the Apple Containerization image
  store,
- `crictl` at `.local/bin/crictl`,
- Linux arm64 k3s binary at `.local/bin/k3s-linux-arm64`,
- `kubectl` in PATH, `/opt/homebrew/bin/kubectl`, or `/usr/local/bin/kubectl`,
- `jq` in PATH.

The script copies and signs runnable binaries under `/private/tmp` because local
vmnet development is sensitive to signing and execution location.

## Expected Output

A recent successful run:

```text
/private/tmp/krust-cri-k3s-smoke: replacing existing signature
/private/tmp/krust-cri-k3s-smoke: valid on disk
/private/tmp/krust-cri-k3s-smoke: satisfies its Designated Requirement
/private/tmp/krust-k3s-pod-smoke-bin: replacing existing signature
/private/tmp/krust-k3s-pod-smoke-bin: valid on disk
/private/tmp/krust-k3s-pod-smoke-bin: satisfies its Designated Requirement
==> CRI status must report vmnet ready
==> Start single-node k3s server with relayed krust-cri socket
==> Wait for k3s kubeconfig
==> Wait for k3s API and node registration

NAME          STATUS   ROLES    AGE   VERSION        INTERNAL-IP    EXTERNAL-IP   OS-IMAGE                         KERNEL-VERSION   CONTAINER-RUNTIME
krust-macos   Ready    <none>   0s    v1.35.0+k3s1   192.168.65.2   <none>        Debian GNU/Linux 12 (bookworm)   6.12.28          krust-cri://0.1.0-mvp

==> Wait for default service account
==> Create server pod via k3s API
pod/krust-k3s-server created
==> Wait for server pod IP
server pod ip=192.168.64.2
==> Create client pod and test direct pod IP
pod/krust-k3s-client created
hello-from-k3s-pod-a

==> Verify failed container termination status
pod/krust-k3s-fail created
==> Verify kubelet OnFailure restart behavior
pod/krust-k3s-restart created
OnFailure restart verified: restartCount=1

==> Verify live container log reopen after rotation
pod/krust-k3s-log-writer created
==> Verify live container stats
container stats verified: cpuCoreNs=8709000 memoryBytes=5890048
INFO[0000] Container logs reopened
live log reopen after rotation verified

NAME                   READY   STATUS      RESTARTS     AGE   IP             NODE          NOMINATED NODE   READINESS GATES
krust-k3s-client       0/1     Completed   0            14s   192.168.64.3   krust-macos   <none>           <none>
krust-k3s-fail         0/1     Error       0            10s   192.168.64.4   krust-macos   <none>           <none>
krust-k3s-log-writer   1/1     Running     0            4s    192.168.64.6   krust-macos   <none>           <none>
krust-k3s-restart      0/1     Error       1 (6s ago)   7s    192.168.64.5   krust-macos   <none>           <none>
krust-k3s-server       1/1     Running     0            16s   192.168.64.2   krust-macos   <none>           <none>
k3s single-node krust-cri pod-to-pod smoke test complete
```

## What This Proves

The current PoC demonstrates:

- k3s can start inside an Apple `LinuxPod`,
- the k3s node registers as `krust-macos`,
- kubelet sees `krust-cri` as the node container runtime,
- Kubernetes API pod creation reaches kubelet,
- kubelet calls the macOS-hosted `krust-cri` socket through Apple socket relay,
- `krust-cri` creates workload pod sandboxes through Apple `LinuxPod`,
- Apple `VmnetNetwork` assigns pod IPs,
- same-node pod-to-pod TCP works through direct pod IP,
- CRI log output captures the pod-to-pod proof payload,
- `kubectl logs` can read CRI log output,
- non-zero exits are visible to kubelet with `Error` reason and exit code,
- basic `restartPolicy: OnFailure` behavior reaches `CrashLoopBackOff`,
- `ReopenContainerLog` reopens live stdout/stderr writers after rotation,
- live container CPU and memory stats are returned through CRI.

## Useful Manual Checks

After the script starts k3s, it writes a host kubeconfig under the smoke work
directory. The script normally cleans up on exit, but while it is running these
are the important commands:

```bash
kubectl --kubeconfig /tmp/krust-k3s-pod-smoke/kubeconfig-host.yaml get nodes -o wide
kubectl --kubeconfig /tmp/krust-k3s-pod-smoke/kubeconfig-host.yaml get pods -o wide
kubectl --kubeconfig /tmp/krust-k3s-pod-smoke/kubeconfig-host.yaml logs krust-k3s-client
```

Direct CRI checks use the smoke socket:

```bash
.local/bin/crictl \
  --config /dev/null \
  --runtime-endpoint unix:///tmp/krust-cri-k3s-smoke.sock \
  --image-endpoint unix:///tmp/krust-cri-k3s-smoke.sock \
  info
```

## Supporting Smokes

`Scripts/smoke-containerization-network.sh`

Proves same-node pod-to-pod networking through `crictl` without k3s.

`Scripts/smoke-kubelet-static-pods.sh`

Runs a Linux kubelet inside an Apple `LinuxPod` with the host CRI socket relayed
into the guest. It creates static pods through kubelet and proves direct
pod-to-pod traffic.

`Scripts/smoke-critest-basic.sh`

Covers the focused CRI contract that the MVP currently implements.

## Current Limits

The PoC intentionally does not claim full Kubernetes node support yet.

Known gaps:

- DNS is not part of the current k3s proof; the smoke uses direct pod IP
  traffic.
- Kubernetes service networking is disabled for the smoke.
- Port mappings are not implemented.
- Multi-node pod routing is not implemented.
- Restart behavior beyond the current single-container `OnFailure` smoke still
  needs hardening.
- Stats currently cover live container CPU and memory; pod sandbox stats and
  deeper resource accounting remain open.
- Recovery after daemon restart, orphan cleanup, GC, volumes, security context,
  and RuntimeClass are not production-ready.
- Live post-create `LinuxPod.addContainer` hotplug is not a committed MVP path.
  Current public API research did not find a supported runtime virtio block
  attach path for the Apple Containerization VZ backend.

## Next Demo Milestones

The next open-source demo should move from direct pod IP tests toward normal
Kubernetes workflows:

- DNS between pods and services,
- a minimal service networking story,
- port mappings for host-to-pod access,
- better `kubectl logs` coverage around rotation,
- pod sandbox stats,
- a repeatable setup script for public contributors.
