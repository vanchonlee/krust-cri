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
        var logWriters: [String: ContainerLogWriters] = [:]
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
        let pod = try makePod(record: podRecord, interfaces: interfaces)

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

        var livePod = live
        if livePod.created {
            logger.info(
                "containerization pod reset before container creation",
                metadata: ["sandbox": "\(sandbox.id)", "container": "\(record.id)"]
            )
            try await livePod.pod.stop()
            for writers in livePod.logWriters.values {
                writers.close()
            }
            livePod.logWriters.removeAll()
            livePod.pod = try makePod(record: livePod.record, interfaces: livePod.pod.config.interfaces)
            livePod.created = false
        }

        let rootfs = try await rootfsMount(for: record)
        let logPath = try logPath(for: record)
        let logWriters = try ContainerLogWriters(
            stdout: CRIFileLogWriter(path: logPath, stream: "stdout"),
            stderr: CRIFileLogWriter(path: logPath, stream: "stderr")
        )
        do {
            try await livePod.pod.addContainer(record.id, rootfs: rootfs) { config in
                config.process.arguments = record.command + record.args
                if config.process.arguments.isEmpty {
                    config.process.arguments = ["/bin/sh"]
                }
                config.process.environmentVariables = ["PATH=\(LinuxProcessConfiguration.defaultPath)"]
                config.process.workingDirectory = "/"
                config.process.stdout = logWriters.stdout
                config.process.stderr = logWriters.stderr
                config.useInit = true
            }
        } catch {
            logWriters.close()
            throw error
        }
        livePod.logWriters[record.id] = logWriters
        pods[sandbox.id] = livePod
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

    func waitContainerExit(_ record: ContainerRecord, sandbox: SandboxRecord) async throws -> RuntimeContainerExitStatus {
        guard let live = pods[sandbox.id] else {
            throw RuntimeBackendError.notFound("live pod not found: \(sandbox.id)")
        }
        let status = try await live.pod.waitContainer(record.id)
        return RuntimeContainerExitStatus(
            exitCode: status.exitCode,
            finishedAt: nanos(since1970: status.exitedAt)
        )
    }

    func stopContainer(_ record: ContainerRecord, sandbox: SandboxRecord?) async throws {
        let sandboxID = sandbox?.id ?? record.sandboxID
        guard let live = pods[sandboxID] else { return }
        guard live.created else { return }
        try await live.pod.stopContainer(record.id)
        logger.info("containerization container stopped", metadata: ["container": "\(record.id)"])
    }

    func removeContainer(_ record: ContainerRecord) async throws {
        guard var live = pods[record.sandboxID] else { return }
        if live.created {
            try? await live.pod.stopContainer(record.id)
        }
        live.logWriters.removeValue(forKey: record.id)?.close()
        pods[record.sandboxID] = live
        logger.info("containerization container removed", metadata: ["container": "\(record.id)"])
    }

    func reopenContainerLog(_ record: ContainerRecord) async throws {
        guard let live = pods[record.sandboxID] else {
            try reopenCRIContainerLogFile(record.logPath)
            return
        }
        guard let logWriters = live.logWriters[record.id] else {
            try reopenCRIContainerLogFile(record.logPath)
            return
        }
        try logWriters.reopen()
    }

    func containerStats(_ record: ContainerRecord) async throws -> Runtime_V1_ContainerStats {
        guard let live = pods[record.sandboxID], live.created else {
            return record.toStats()
        }
        do {
            guard let statistics = try await live.pod.statistics(
                containerIDs: [record.id],
                categories: [.cpu, .memory]
            ).first else {
                return record.toStats()
            }
            return record.toStats(containerization: statistics)
        } catch {
            logger.debug(
                "containerization stats unavailable; returning fallback stats",
                metadata: ["container": "\(record.id)", "error": "\(error)"]
            )
            return record.toStats()
        }
    }

    private func makePod(record: SandboxRecord, interfaces: [any Interface]) throws -> LinuxPod {
        let podPath = self.root.appendingPathComponent("pods").appendingPathComponent(record.id)
        try createDirectory(podPath)

        return try LinuxPod(record.id, vmm: vmm, logger: logger) { config in
            config.cpus = 2
            config.memoryInBytes = 1024 * 1024 * 1024
            config.interfaces = interfaces
            config.hostname = record.name.isEmpty ? nil : record.name
            if let dnsConfig = record.dnsConfig {
                config.dns = dnsConfig.toContainerizationDNS()
            }
            config.bootLog = BootLog.file(path: podPath.appendingPathComponent("boot.log"))
        }
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

private func nanos(since1970 date: Date) -> Int64 {
    Int64(date.timeIntervalSince1970 * 1_000_000_000)
}

private enum RuntimeBackendError: Error, CustomStringConvertible {
    case notFound(String)

    var description: String {
        switch self {
        case .notFound(let message): return message
        }
    }
}

private extension SandboxDNSConfig {
    func toContainerizationDNS() -> DNS {
        DNS(
            nameservers: servers,
            searchDomains: searches,
            options: options
        )
    }
}

private extension ContainerRecord {
    func toStats(containerization statistics: ContainerStatistics) -> Runtime_V1_ContainerStats {
        let timestamp = nowNanos()
        var stats = toStats()

        if let cpuStatistics = statistics.cpu {
            var cpu = Runtime_V1_CpuUsage()
            cpu.timestamp = timestamp
            cpu.usageCoreNanoSeconds = .with { $0.value = cpuStatistics.usageUsec * 1_000 }
            stats.cpu = cpu
        }

        if let memoryStatistics = statistics.memory {
            let workingSetBytes = memoryStatistics.usageBytes.saturatingSubtract(memoryStatistics.inactiveFile)
            var memory = Runtime_V1_MemoryUsage()
            memory.timestamp = timestamp
            memory.usageBytes = .with { $0.value = memoryStatistics.usageBytes }
            memory.workingSetBytes = .with { $0.value = workingSetBytes }
            memory.availableBytes = .with { $0.value = memoryStatistics.limitBytes.saturatingSubtract(workingSetBytes) }
            memory.rssBytes = .with { $0.value = memoryStatistics.anon }
            memory.pageFaults = .with { $0.value = memoryStatistics.pageFaults }
            memory.majorPageFaults = .with { $0.value = memoryStatistics.majorPageFaults }
            stats.memory = memory

            var swap = Runtime_V1_SwapUsage()
            swap.timestamp = timestamp
            swap.swapUsageBytes = .with { $0.value = memoryStatistics.swapUsageBytes }
            swap.swapAvailableBytes = .with {
                $0.value = memoryStatistics.swapLimitBytes.saturatingSubtract(memoryStatistics.swapUsageBytes)
            }
            stats.swap = swap
        }

        return stats
    }
}

private extension UInt64 {
    func saturatingSubtract(_ value: UInt64) -> UInt64 {
        self > value ? self - value : 0
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
    func waitContainerExit(_ record: ContainerRecord, sandbox: SandboxRecord) async throws -> RuntimeContainerExitStatus { throw RuntimeBackendError.unsupported }
    func stopContainer(_ record: ContainerRecord, sandbox: SandboxRecord?) async throws { throw RuntimeBackendError.unsupported }
    func removeContainer(_ record: ContainerRecord) async throws { throw RuntimeBackendError.unsupported }
}

private enum RuntimeBackendError: Error {
    case unsupported
}

#endif
