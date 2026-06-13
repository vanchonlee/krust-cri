import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging

#if os(macOS)

actor ContainerizationRuntimeBackend: ContainerRuntimeBackend {
    private struct LivePod {
        var record: SandboxRecord
        var pod: LinuxPod
        var created: Bool
    }

    private let imageStore: ImageStore
    private let vmm: any VirtualMachineManager
    private let root: URL
    private let logger: Logger
    private var network: (any Network)?
    private var pods: [String: LivePod] = [:]

    init(
        kernelPath: URL,
        initfsReference: String,
        root: URL?,
        rosetta: Bool,
        logger: Logger
    ) async throws {
        self.logger = logger
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.containerization")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        self.imageStore = try ImageStore(path: self.root)

        let initPath = self.root.appendingPathComponent("initfs.ext4")
        let initImage = try await self.imageStore.getInitImage(reference: initfsReference)
        let initfs: Containerization.Mount
        do {
            initfs = try await initImage.initBlock(at: initPath, for: .linuxArm)
        } catch {
            if FileManager.default.fileExists(atPath: initPath.path) {
                initfs = .block(format: "ext4", source: initPath.path, destination: "/", options: ["ro"])
            } else {
                throw error
            }
        }

        self.vmm = VZVirtualMachineManager(
            kernel: Kernel(path: kernelPath, platform: .linuxArm),
            initialFilesystem: initfs,
            rosetta: rosetta,
            logger: logger
        )

        if #available(macOS 26.0, *) {
            do {
                self.network = try VmnetNetwork()
            } catch {
                logger.warning("vmnet network unavailable; continuing without pod networking", metadata: ["error": "\(error)"])
                self.network = nil
            }
        }
    }

    func runSandbox(_ record: SandboxRecord) async throws -> SandboxRecord {
        var podRecord = record
        let interfaces = try allocateInterfaces(for: record.id)
        if let first = interfaces.first {
            podRecord.ip = first.ipv4Address.address.description
        }
        let podPath = self.root.appendingPathComponent("pods").appendingPathComponent(record.id)
        try createDirectory(podPath)

        let pod = try LinuxPod(record.id, vmm: vmm, logger: logger) { config in
            config.cpus = 2
            config.memoryInBytes = 1024 * 1024 * 1024
            config.interfaces = interfaces
            config.hostname = record.name.isEmpty ? nil : record.name
            config.bootLog = BootLog.file(path: podPath.appendingPathComponent("boot.log"))
        }

        pods[record.id] = LivePod(record: podRecord, pod: pod, created: false)
        logger.info("containerization pod registered", metadata: ["sandbox": "\(record.id)"])
        return podRecord
    }

    func status() async -> RuntimeBackendStatus {
        RuntimeBackendStatus(
            runtimeReady: true,
            networkReady: network != nil,
            info: [
                "vmnet": network == nil ? "unavailable" : "ready"
            ]
        )
    }

    func stopSandbox(_ record: SandboxRecord) async throws {
        guard let live = pods[record.id] else { return }
        if live.created {
            try await live.pod.stop()
        }
        try releaseInterface(for: record.id)
        logger.info("containerization pod stopped", metadata: ["sandbox": "\(record.id)"])
    }

    func createContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws {
        guard let live = pods[sandbox.id] else {
            throw RuntimeBackendError.notFound("live pod not found: \(sandbox.id)")
        }

        let rootfs = try await rootfsMount(for: record)
        let logPath = try logPath(for: record)
        try await live.pod.addContainer(record.id, rootfs: rootfs) { config in
            config.process.arguments = record.command + record.args
            if config.process.arguments.isEmpty {
                config.process.arguments = ["/bin/sh"]
            }
            config.process.environmentVariables = ["PATH=\(LinuxProcessConfiguration.defaultPath)"]
            config.process.workingDirectory = "/"
            config.process.stdout = try? FileLogWriter(path: logPath, stream: "stdout")
            config.process.stderr = try? FileLogWriter(path: logPath, stream: "stderr")
            config.useInit = true
        }
        logger.info("containerization container created", metadata: ["container": "\(record.id)", "sandbox": "\(sandbox.id)"])
    }

    func startContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws {
        guard var live = pods[sandbox.id] else {
            throw RuntimeBackendError.notFound("live pod not found: \(sandbox.id)")
        }
        if !live.created {
            try await live.pod.create()
            live.created = true
            pods[sandbox.id] = live
            logger.info("containerization pod booted", metadata: ["sandbox": "\(sandbox.id)"])
        }
        try await live.pod.startContainer(record.id)
        logger.info("containerization container started", metadata: ["container": "\(record.id)"])
    }

    func stopContainer(_ record: ContainerRecord, sandbox: SandboxRecord?) async throws {
        let sandboxID = sandbox?.id ?? record.sandboxID
        guard let live = pods[sandboxID] else { return }
        guard live.created else { return }
        try await live.pod.stopContainer(record.id)
        logger.info("containerization container stopped", metadata: ["container": "\(record.id)"])
    }

    func removeContainer(_ record: ContainerRecord) async throws {
        guard let live = pods[record.sandboxID] else { return }
        if live.created {
            try? await live.pod.stopContainer(record.id)
        }
        logger.info("containerization container removed", metadata: ["container": "\(record.id)"])
    }

    private func allocateInterfaces(for id: String) throws -> [any Interface] {
        guard var network else { return [] }
        if let interface = try network.createInterface(id) {
            self.network = network
            return [interface]
        }
        self.network = network
        return []
    }

    private func releaseInterface(for id: String) throws {
        guard var network else { return }
        try network.releaseInterface(id)
        self.network = network
    }

    private func rootfsMount(for record: ContainerRecord) async throws -> Containerization.Mount {
        let image = try await imageStore.get(reference: record.image, pull: true)
        let path = root.appendingPathComponent("containers").appendingPathComponent(record.id)
        try createDirectory(path)
        let rootfsPath = path.appendingPathComponent("rootfs.ext4")
        if FileManager.default.fileExists(atPath: rootfsPath.path) {
            return .block(format: "ext4", source: rootfsPath.path, destination: "/", options: [])
        }
        let unpacker = EXT4Unpacker(blockSizeInBytes: 2 * 1024 * 1024 * 1024)
        return try await unpacker.unpack(image, for: .current, at: rootfsPath)
    }

    private func logPath(for record: ContainerRecord) throws -> URL {
        if !record.logPath.isEmpty {
            let url = URL(fileURLWithPath: record.logPath)
            try createDirectory(url.deletingLastPathComponent())
            return url
        }
        let path = root.appendingPathComponent("logs").appendingPathComponent(record.id).appendingPathComponent("current.log")
        try createDirectory(path.deletingLastPathComponent())
        return path
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

private enum RuntimeBackendError: Error, CustomStringConvertible {
    case notFound(String)

    var description: String {
        switch self {
        case .notFound(let message): return message
        }
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

#else

actor ContainerizationRuntimeBackend: ContainerRuntimeBackend {
    init(kernelPath: URL, initfsReference: String, root: URL?, rosetta: Bool, logger: Logger) async throws {
        throw RuntimeBackendError.unsupported
    }

    func runSandbox(_ record: SandboxRecord) async throws -> SandboxRecord { throw RuntimeBackendError.unsupported }
    func stopSandbox(_ record: SandboxRecord) async throws { throw RuntimeBackendError.unsupported }
    func createContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws { throw RuntimeBackendError.unsupported }
    func startContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws { throw RuntimeBackendError.unsupported }
    func stopContainer(_ record: ContainerRecord, sandbox: SandboxRecord?) async throws { throw RuntimeBackendError.unsupported }
    func removeContainer(_ record: ContainerRecord) async throws { throw RuntimeBackendError.unsupported }
}

private enum RuntimeBackendError: Error {
    case unsupported
}

#endif
