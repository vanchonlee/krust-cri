import ArgumentParser
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging

@main
struct KrustKubeletPod: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "krust-kubelet-pod",
        abstract: "Run a Linux kubelet inside an Apple Containerization LinuxPod with the host CRI socket relayed into the guest."
    )

    @Option(help: "Control pod identifier.")
    var id: String = "krust-kubelet"

    @Option(help: "Mode to run: kubelet, k3s-agent, or k3s-server.")
    var mode: String = "kubelet"

    @Option(help: "Linux kernel path.")
    var kernel: String = "containerization/bin/vmlinux"

    @Option(help: "Init filesystem OCI reference.")
    var initfsReference: String = "vminit:latest"

    @Option(help: "Apple Containerization image/root state root.")
    var containerizationRoot: String?

    @Option(help: "Control container image.")
    var image: String = "docker.io/library/debian:bookworm-slim"

    @Option(help: "Host path to linux/arm64 kubelet binary.")
    var kubelet: String?

    @Option(help: "Host path to linux/arm64 k3s binary.")
    var k3s: String?

    @Option(help: "Host directory containing static pod manifests.")
    var manifests: String?

    @Option(help: "K3s server URL for k3s-agent mode, for example https://10.0.0.10:6443.")
    var k3sURL: String?

    @Option(help: "K3s node token for k3s-agent mode.")
    var k3sToken: String?

    @Option(help: "Node name reported by kubelet/k3s.")
    var nodeName: String = "krust-macos"

    @Option(help: "Host krust-cri Unix socket path.")
    var criSocket: String = "/tmp/krust-cri.sock"

    @Option(help: "Guest krust-cri Unix socket path.")
    var guestCriSocket: String = "/run/krust-cri/krust-cri.sock"

    @Option(help: "Work directory for generated kubelet config and logs.")
    var workDir: String = "/tmp/krust-kubelet-pod"

    private var guestWorkDir: String { "/krust/work" }

    @Option(help: "Absolute path shared by host and guest for kubelet pod logs.")
    var podLogsDir: String = "/tmp/krust-cri-kubelet-logs"

    @Option(help: "Kubelet verbosity.")
    var verbosity: Int = 4

    @Flag(help: "Enable Rosetta for linux/amd64 control images.")
    var rosetta = false

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "krust-kubelet-pod")

        let fileManager = FileManager.default
        let workURL = URL(fileURLWithPath: workDir)
        let logsURL = workURL.appendingPathComponent("logs")
        let stateRoot = containerizationRoot.map { URL(fileURLWithPath: $0) }
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.apple.containerization")
        try fileManager.createDirectory(at: workURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(atPath: podLogsDir, withIntermediateDirectories: true)
        try validateInputs(fileManager: fileManager)

        let runMode = try RunMode(rawValue: mode).orThrow("--mode must be 'kubelet', 'k3s-agent', or 'k3s-server'")
        let kubeletConfig = workURL.appendingPathComponent("kubelet-config.yaml")
        if runMode == .kubelet {
            try writeKubeletConfig(to: kubeletConfig)
        }

        let imageStore = try ImageStore(path: stateRoot)
        let initPath = stateRoot.appendingPathComponent("initfs.ext4")
        let initImage = try await imageStore.getInitImage(reference: initfsReference)
        let initfs: Containerization.Mount
        do {
            initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
        } catch {
            if fileManager.fileExists(atPath: initPath.path) {
                initfs = .block(format: "ext4", source: initPath.path, destination: "/", options: ["ro"])
            } else {
                throw error
            }
        }

        let vmm = VZVirtualMachineManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernel), platform: .linuxArm),
            initialFilesystem: initfs,
            rosetta: rosetta,
            logger: logger
        )

        let podPath = workURL.appendingPathComponent("pod")
        try fileManager.createDirectory(at: podPath, withIntermediateDirectories: true)
        let controlInterfaces = try createControlInterfaces(for: id, enabled: runMode.usesControlNetwork)
        let controlIP = controlInterfaces.first?.ipv4Address.address.description
        if let controlIP {
            try controlIP.write(to: workURL.appendingPathComponent("control-ip.txt"), atomically: true, encoding: .utf8)
        }
        let pod = try LinuxPod(id, vmm: vmm, logger: logger) { config in
            config.cpus = 2
            config.memoryInBytes = 2048 * 1024 * 1024
            config.hostname = nodeName
            config.interfaces = controlInterfaces
            config.bootLog = .file(path: logsURL.appendingPathComponent("boot.log"))
        }

        let rootfs = try await rootfsMount(
            image: image,
            imageStore: imageStore,
            stateRoot: stateRoot,
            containerID: "\(id)-control"
        )

        let logName = runMode.logName
        let processLog = try FileLogWriter(path: logsURL.appendingPathComponent(logName), stream: "stdout")
        let processErr = try FileLogWriter(path: logsURL.appendingPathComponent(logName), stream: "stderr")
        try await pod.addContainer(runMode.containerID, rootfs: rootfs) { config in
            config.process.arguments = try processArguments(mode: runMode, controlIP: controlIP)
            config.process.environmentVariables = ["PATH=\(LinuxProcessConfiguration.defaultPath):/usr/local/bin"]
            config.process.workingDirectory = "/"
            config.process.stdout = processLog
            config.process.stderr = processErr
            try addProcessMounts(to: &config, mode: runMode, kubeletConfig: kubeletConfig)
            let guestPodLogsDir = runMode.guestPodLogsDir(hostPath: podLogsDir)
            config.mounts.append(.share(source: podLogsDir, destination: guestPodLogsDir))
            if guestPodLogsDir != podLogsDir {
                config.mounts.append(.share(source: podLogsDir, destination: podLogsDir))
            }
            config.sockets = [
                UnixSocketConfiguration(
                    source: URL(fileURLWithPath: criSocket),
                    destination: URL(fileURLWithPath: guestCriSocket),
                    direction: .into
                )
            ]
            config.useInit = true
        }

        logger.info("creating control pod", metadata: ["id": "\(id)", "mode": "\(runMode.rawValue)", "log": "\(logsURL.path)"])
        try await pod.create()
        logger.info("starting control process", metadata: ["mode": "\(runMode.rawValue)", "criSocket": "\(guestCriSocket)", "nodeIP": "\(controlIP ?? "")"])
        try await pod.startContainer(runMode.containerID)

        logger.info("control process is running; press Ctrl-C to stop", metadata: ["log": "\(logsURL.appendingPathComponent(logName).path)"])
        try await waitForever()
    }

    private func validateInputs(fileManager: FileManager) throws {
        let runMode = try RunMode(rawValue: mode).orThrow("--mode must be 'kubelet', 'k3s-agent', or 'k3s-server'")
        switch runMode {
        case .kubelet:
            guard let kubelet, fileManager.isExecutableFile(atPath: kubelet) else {
                throw ValidationError("kubelet binary is not executable: \(kubelet ?? "")")
            }
            var isDirectory = ObjCBool(false)
            guard let manifests, fileManager.fileExists(atPath: manifests, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ValidationError("manifests directory does not exist: \(manifests ?? "")")
            }
        case .k3sAgent:
            guard let k3s, fileManager.isExecutableFile(atPath: k3s) else {
                throw ValidationError("k3s binary is not executable: \(k3s ?? "")")
            }
            guard k3sURL?.isEmpty == false else {
                throw ValidationError("--k3s-url is required in k3s-agent mode")
            }
            guard k3sToken?.isEmpty == false else {
                throw ValidationError("--k3s-token is required in k3s-agent mode")
            }
        case .k3sServer:
            guard let k3s, fileManager.isExecutableFile(atPath: k3s) else {
                throw ValidationError("k3s binary is not executable: \(k3s ?? "")")
            }
        }
        guard fileManager.fileExists(atPath: criSocket) else {
            throw ValidationError("CRI socket does not exist: \(criSocket)")
        }
        guard fileManager.fileExists(atPath: kernel) else {
            throw ValidationError("kernel does not exist: \(kernel)")
        }
    }

    private func writeKubeletConfig(to url: URL) throws {
        let config = """
        apiVersion: kubelet.config.k8s.io/v1beta1
        kind: KubeletConfiguration
        authentication:
          anonymous:
            enabled: true
          webhook:
            enabled: false
        authorization:
          mode: AlwaysAllow
        cgroupDriver: cgroupfs
        cgroupsPerQOS: false
        enforceNodeAllocatable: []
        failSwapOn: false
        staticPodPath: /etc/krust/manifests
        containerLogMaxSize: 10Mi
        containerLogMaxFiles: 2
        podLogsDir: \(podLogsDir)
        clusterDomain: cluster.local
        clusterDNS: []
        resolvConf: /etc/resolv.conf
        """
        try config.write(to: url, atomically: true, encoding: .utf8)
    }

    private func kubeletArguments() -> [String] {
        [
            "/usr/local/bin/kubelet",
            "--config=/etc/krust/kubelet-config.yaml",
            "--container-runtime-endpoint=unix://\(guestCriSocket)",
            "--image-service-endpoint=unix://\(guestCriSocket)",
            "--pod-manifest-path=/etc/krust/manifests",
            "--root-dir=/var/lib/kubelet",
            "--hostname-override=\(nodeName)",
            "--register-node=false",
            "--fail-swap-on=false",
            "--v=\(verbosity)",
        ]
    }

    private func processArguments(mode: RunMode, controlIP: String?) throws -> [String] {
        switch mode {
        case .kubelet:
            return kubeletArguments()
        case .k3sAgent:
            var args = [
                "/usr/local/bin/k3s",
                "agent",
                "--server", k3sURL!,
                "--token", k3sToken!,
                "--node-name", nodeName,
                "--container-runtime-endpoint", "unix://\(guestCriSocket)",
                "--image-service-endpoint", "unix://\(guestCriSocket)",
                "--kubelet-arg", "cgroup-driver=cgroupfs",
                "--kubelet-arg", "cgroups-per-qos=false",
                "--kubelet-arg", "enforce-node-allocatable=",
                "--kubelet-arg", "fail-swap-on=false",
                "--kubelet-arg", "container-log-max-files=2",
                "--kubelet-arg", "container-log-max-size=10Mi",
            ]
            if let controlIP {
                args += ["--node-ip", controlIP]
            }
            return args
        case .k3sServer:
            var args = [
                "/usr/local/bin/k3s",
                "server",
                "--node-name", nodeName,
                "--container-runtime-endpoint", "unix://\(guestCriSocket)",
                "--image-service-endpoint", "unix://\(guestCriSocket)",
                "--flannel-backend=none",
                "--disable-network-policy",
                "--disable-kube-proxy",
                "--disable", "traefik",
                "--disable", "servicelb",
                "--disable", "metrics-server",
                "--disable", "local-storage",
                "--disable", "coredns",
                "--write-kubeconfig", "\(guestWorkDir)/kubeconfig.yaml",
                "--write-kubeconfig-mode", "644",
                "--kubelet-arg", "cgroup-driver=cgroupfs",
                "--kubelet-arg", "cgroups-per-qos=false",
                "--kubelet-arg", "enforce-node-allocatable=",
                "--kubelet-arg", "fail-swap-on=false",
                "--kubelet-arg", "container-log-max-files=2",
                "--kubelet-arg", "container-log-max-size=10Mi",
            ]
            if let controlIP {
                args += ["--node-ip", controlIP, "--advertise-address", controlIP]
            }
            return args
        }
    }

    private func addProcessMounts(
        to config: inout LinuxPod.ContainerConfiguration,
        mode: RunMode,
        kubeletConfig: URL
    ) throws {
        switch mode {
        case .kubelet:
            config.mounts.append(.share(source: kubelet!, destination: "/usr/local/bin/kubelet", options: ["ro"]))
            config.mounts.append(.share(source: manifests!, destination: "/etc/krust/manifests", options: ["ro"]))
            config.mounts.append(.share(source: kubeletConfig.path, destination: "/etc/krust/kubelet-config.yaml", options: ["ro"]))
        case .k3sAgent, .k3sServer:
            config.mounts.append(.share(source: k3s!, destination: "/usr/local/bin/k3s", options: ["ro"]))
            config.mounts.append(.share(source: workDir, destination: guestWorkDir))
        }
    }

    private func createControlInterfaces(for id: String, enabled: Bool) throws -> [any Interface] {
        guard enabled else { return [] }
        if #available(macOS 26.0, *) {
            var network = try VmnetNetwork()
            if let interface = try network.createInterface("\(id)-control") {
                return [interface]
            }
        }
        return []
    }

    private func rootfsMount(
        image: String,
        imageStore: ImageStore,
        stateRoot: URL,
        containerID: String
    ) async throws -> Containerization.Mount {
        let image = try await imageStore.get(reference: image, pull: true)
        let path = stateRoot.appendingPathComponent("containers").appendingPathComponent(containerID)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let rootfsPath = path.appendingPathComponent("rootfs.ext4")
        if FileManager.default.fileExists(atPath: rootfsPath.path) {
            return .block(format: "ext4", source: rootfsPath.path, destination: "/", options: [])
        }
        let unpacker = EXT4Unpacker(blockSizeInBytes: 2 * 1024 * 1024 * 1024)
        return try await unpacker.unpack(image, for: .current, at: rootfsPath)
    }

    private func waitForever() async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

private enum RunMode: String {
    case kubelet
    case k3sAgent = "k3s-agent"
    case k3sServer = "k3s-server"

    var containerID: String {
        switch self {
        case .kubelet: return "kubelet"
        case .k3sAgent: return "k3s-agent"
        case .k3sServer: return "k3s-server"
        }
    }

    var logName: String {
        switch self {
        case .kubelet: return "kubelet.log"
        case .k3sAgent: return "k3s-agent.log"
        case .k3sServer: return "k3s-server.log"
        }
    }

    var usesControlNetwork: Bool {
        switch self {
        case .kubelet: return false
        case .k3sAgent, .k3sServer: return true
        }
    }

    func guestPodLogsDir(hostPath: String) -> String {
        switch self {
        case .kubelet: return hostPath
        case .k3sAgent, .k3sServer: return "/var/log/pods"
        }
    }
}

private extension Optional where Wrapped == RunMode {
    func orThrow(_ message: String) throws -> RunMode {
        guard let self else { throw ValidationError(message) }
        return self
    }
}

private final class FileLogWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle
    private let stream: String

    init(path: URL, stream: String) throws {
        self.stream = stream
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        self.handle = try FileHandle(forWritingTo: path)
        try self.handle.seekToEnd()
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(stream) F \(String(decoding: data, as: UTF8.self))"
        if let encoded = line.data(using: .utf8) {
            try handle.write(contentsOf: encoded)
        }
    }

    func close() throws {
        try handle.close()
    }
}
