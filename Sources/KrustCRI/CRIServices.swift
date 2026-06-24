import Foundation
import GRPCCore
import Logging
import SwiftProtobuf

struct CRIRuntimeService: Runtime_V1_RuntimeService.SimpleServiceProtocol {
    let runtimeName: String
    let runtimeVersion: String
    let state: RuntimeState
    let runtime: ContainerRuntimeBackend
    let backendName: String
    let cgroupDriver: Runtime_V1_CgroupDriver
    let hostPodLogsDir: String
    let logger: Logger

    func version(
        request: Runtime_V1_VersionRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_VersionResponse {
        .with {
            $0.version = request.version.isEmpty ? "0.1.0" : request.version
            $0.runtimeName = runtimeName
            $0.runtimeVersion = runtimeVersion
            $0.runtimeApiVersion = "0.1.0"
        }
    }

    func runPodSandbox(
        request: Runtime_V1_RunPodSandboxRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_RunPodSandboxResponse {
        let config = request.config
        let meta = config.metadata
        let id = makeID(prefix: "pod", seed: "\(meta.namespace)-\(meta.name)-\(meta.uid)-\(meta.attempt)")
        let record = SandboxRecord(
            id: id,
            name: meta.name,
            namespace: meta.namespace,
            attempt: meta.attempt,
            uid: meta.uid,
            labels: config.labels,
            annotations: config.annotations,
            runtimeHandler: request.runtimeHandler,
            logDirectory: config.logDirectory,
            createdAt: nowNanos(),
            phase: .ready,
            ip: "10.88.0.\((abs(id.hashValue) % 200) + 2)",
            dnsConfig: config.hasDnsConfig ? SandboxDNSConfig(cri: config.dnsConfig) : nil,
            portMappings: config.portMappings.map(SandboxPortMapping.init(cri:))
        )
        do {
            let backendRecord = try await runtime.runSandbox(record)
            try await state.addSandbox(backendRecord)
        } catch {
            logger.error("RunPodSandbox failed", metadata: ["sandbox": "\(id)", "error": "\(error)"])
            throw RPCError(code: .unknown, message: "RunPodSandbox failed: \(error)")
        }
        return .with { $0.podSandboxID = id }
    }

    func stopPodSandbox(
        request: Runtime_V1_StopPodSandboxRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_StopPodSandboxResponse {
        if let sandbox = await state.sandbox(id: request.podSandboxID) {
            for container in await state.containers(sandboxID: sandbox.id) where container.phase == .running {
                try await runtime.stopContainer(container, sandbox: sandbox)
                try await state.updateContainer(id: container.id) {
                    $0.phase = .exited
                    $0.finishedAt = nowNanos()
                }
            }
            try await runtime.stopSandbox(sandbox)
            try await state.updateSandbox(id: sandbox.id) { $0.phase = .notReady }
        }
        return Runtime_V1_StopPodSandboxResponse()
    }

    func removePodSandbox(
        request: Runtime_V1_RemovePodSandboxRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_RemovePodSandboxResponse {
        try await state.removeSandbox(id: request.podSandboxID)
        return Runtime_V1_RemovePodSandboxResponse()
    }

    func podSandboxStatus(
        request: Runtime_V1_PodSandboxStatusRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_PodSandboxStatusResponse {
        guard let sandbox = await state.sandbox(id: request.podSandboxID) else {
            throw RPCError(code: .notFound, message: "sandbox not found: \(request.podSandboxID)")
        }
        let containers = await state.containers(sandboxID: sandbox.id)
        return .with {
            $0.status = sandbox.toStatus()
            $0.containersStatuses = containers.map { $0.toStatus() }
            $0.timestamp = nowNanos()
            if request.verbose {
                $0.info = [
                    "backend": "\"\(backendName)\"",
                    "portMappings": sandbox.portMappingsInfoJSON,
                ]
            }
        }
    }

    func listPodSandbox(
        request: Runtime_V1_ListPodSandboxRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ListPodSandboxResponse {
        let items = (await state.sandboxes())
            .filter { request.filter.matches($0) }
            .map { $0.toListItem() }
        return .with {
            $0.items = items
        }
    }

    func streamPodSandboxes(
        request: Runtime_V1_StreamPodSandboxesRequest,
        response: RPCWriter<Runtime_V1_StreamPodSandboxesResponse>,
        context: ServerContext
    ) async throws {
        let items = (await state.sandboxes()).filter { request.filter.matches($0) }.map { $0.toListItem() }
        if !items.isEmpty {
            try await response.write(.with { $0.podSandboxes = items })
        }
    }

    func createContainer(
        request: Runtime_V1_CreateContainerRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_CreateContainerResponse {
        guard let sandbox = await state.sandbox(id: request.podSandboxID) else {
            throw RPCError(code: .notFound, message: "sandbox not found: \(request.podSandboxID)")
        }
        let config = request.config
        let meta = config.metadata
        let imageRef = imageName(config.image)
        let image: ImageRecord
        if let existing = await state.image(reference: imageRef) {
            image = existing
        } else {
            image = try await state.upsertImage(reference: imageRef)
        }
        let runtimeImageRef = image.runnableReference(preferred: imageRef)
        let id = makeID(prefix: "ctr", seed: "\(request.podSandboxID)-\(meta.name)-\(meta.attempt)")
        let record = ContainerRecord(
            id: id,
            sandboxID: request.podSandboxID,
            name: meta.name,
            attempt: meta.attempt,
            image: runtimeImageRef,
            imageRef: image.id,
            command: config.command,
            args: config.args,
            labels: config.labels,
            annotations: config.annotations,
            logPath: resolveLogPath(config.logPath, sandbox: sandbox, hostPodLogsDir: hostPodLogsDir),
            createdAt: nowNanos(),
            startedAt: 0,
            finishedAt: 0,
            exitCode: 0,
            phase: .created
        )
        do {
            try await runtime.createContainer(record, sandbox: sandbox)
            try await state.addContainer(record)
        } catch {
            logger.error("CreateContainer failed", metadata: ["container": "\(id)", "sandbox": "\(sandbox.id)", "image": "\(imageRef)", "error": "\(error)"])
            throw RPCError(code: .unknown, message: "CreateContainer failed: \(error)")
        }
        return .with { $0.containerID = id }
    }

    func startContainer(
        request: Runtime_V1_StartContainerRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_StartContainerResponse {
        guard let container = await state.container(id: request.containerID) else {
            throw RPCError(code: .notFound, message: "container not found: \(request.containerID)")
        }
        guard let sandbox = await state.sandbox(id: container.sandboxID) else {
            throw RPCError(code: .notFound, message: "sandbox not found: \(container.sandboxID)")
        }
        do {
            try await runtime.startContainer(container, sandbox: sandbox)
        } catch {
            logger.error("StartContainer failed", metadata: ["container": "\(container.id)", "sandbox": "\(sandbox.id)", "error": "\(error)"])
            throw RPCError(code: .unknown, message: "StartContainer failed: \(error)")
        }
        try await state.updateContainer(id: container.id) {
            $0.phase = .running
            $0.startedAt = nowNanos()
            $0.finishedAt = 0
        }
        observeContainerExit(container: container, sandbox: sandbox, runtime: runtime, state: state, logger: logger)
        return Runtime_V1_StartContainerResponse()
    }

    func stopContainer(
        request: Runtime_V1_StopContainerRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_StopContainerResponse {
        if let container = await state.container(id: request.containerID) {
            try await runtime.stopContainer(container, sandbox: await state.sandbox(id: container.sandboxID))
            try await state.updateContainer(id: container.id) {
                $0.phase = .exited
                $0.finishedAt = nowNanos()
                $0.exitCode = 0
            }
        }
        return Runtime_V1_StopContainerResponse()
    }

    func removeContainer(
        request: Runtime_V1_RemoveContainerRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_RemoveContainerResponse {
        if let container = await state.container(id: request.containerID) {
            try await runtime.removeContainer(container)
        }
        try await state.removeContainer(id: request.containerID)
        return Runtime_V1_RemoveContainerResponse()
    }

    func listContainers(
        request: Runtime_V1_ListContainersRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ListContainersResponse {
        let containers = (await state.containers())
            .filter { request.filter.matches($0) }
            .map { $0.toListItem() }
        return .with {
            $0.containers = containers
        }
    }

    func streamContainers(
        request: Runtime_V1_StreamContainersRequest,
        response: RPCWriter<Runtime_V1_StreamContainersResponse>,
        context: ServerContext
    ) async throws {
        let containers = (await state.containers()).filter { request.filter.matches($0) }.map { $0.toListItem() }
        if !containers.isEmpty {
            try await response.write(.with { $0.containers = containers })
        }
    }

    func containerStatus(
        request: Runtime_V1_ContainerStatusRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ContainerStatusResponse {
        guard let container = await state.container(id: request.containerID) else {
            throw RPCError(code: .notFound, message: "container not found: \(request.containerID)")
        }
        return .with {
            $0.status = container.toStatus()
            if request.verbose {
                $0.info = ["backend": "\"\(backendName)\""]
            }
        }
    }

    func updateContainerResources(
        request: Runtime_V1_UpdateContainerResourcesRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_UpdateContainerResourcesResponse {
        Runtime_V1_UpdateContainerResourcesResponse()
    }

    func reopenContainerLog(
        request: Runtime_V1_ReopenContainerLogRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ReopenContainerLogResponse {
        guard let container = await state.container(id: request.containerID) else {
            throw RPCError(code: .notFound, message: "container not found: \(request.containerID)")
        }
        do {
            try await runtime.reopenContainerLog(container)
        } catch let error as LogManagerError {
            throw RPCError(code: .failedPrecondition, message: error.description)
        } catch {
            throw RPCError(code: .unknown, message: "ReopenContainerLog failed: \(error)")
        }
        return Runtime_V1_ReopenContainerLogResponse()
    }

    func execSync(request: Runtime_V1_ExecSyncRequest, context: ServerContext) async throws -> Runtime_V1_ExecSyncResponse {
        guard let container = await state.container(id: request.containerID) else {
            throw RPCError(code: .notFound, message: "container not found: \(request.containerID)")
        }
        let sandbox = await state.sandbox(id: container.sandboxID)
        return syntheticExecSyncResponse(command: request.cmd, timeout: request.timeout, sandbox: sandbox)
    }

    func exec(request: Runtime_V1_ExecRequest, context: ServerContext) async throws -> Runtime_V1_ExecResponse {
        throw unimplemented("Exec")
    }

    func attach(request: Runtime_V1_AttachRequest, context: ServerContext) async throws -> Runtime_V1_AttachResponse {
        throw unimplemented("Attach")
    }

    func portForward(request: Runtime_V1_PortForwardRequest, context: ServerContext) async throws -> Runtime_V1_PortForwardResponse {
        throw unimplemented("PortForward")
    }

    func containerStats(
        request: Runtime_V1_ContainerStatsRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ContainerStatsResponse {
        guard let container = await state.container(id: request.containerID) else {
            throw RPCError(code: .notFound, message: "container not found: \(request.containerID)")
        }
        let stats = try await runtime.containerStats(container)
        return .with { $0.stats = stats }
    }

    func listContainerStats(
        request: Runtime_V1_ListContainerStatsRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ListContainerStatsResponse {
        var stats: [Runtime_V1_ContainerStats] = []
        for container in (await state.containers()).filter({ request.filter.matches($0) }) {
            stats.append(try await runtime.containerStats(container))
        }
        return .with { $0.stats = stats }
    }

    func streamContainerStats(
        request: Runtime_V1_StreamContainerStatsRequest,
        response: RPCWriter<Runtime_V1_StreamContainerStatsResponse>,
        context: ServerContext
    ) async throws {
        var stats: [Runtime_V1_ContainerStats] = []
        for container in (await state.containers()).filter({ request.filter.matches($0) }) {
            stats.append(try await runtime.containerStats(container))
        }
        if !stats.isEmpty {
            try await response.write(.with { $0.containerStats = stats })
        }
    }

    func podSandboxStats(
        request: Runtime_V1_PodSandboxStatsRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_PodSandboxStatsResponse {
        guard let sandbox = await state.sandbox(id: request.podSandboxID) else {
            throw RPCError(code: .notFound, message: "sandbox not found: \(request.podSandboxID)")
        }
        let stats = try await statsForSandbox(sandbox)
        return .with {
            $0.stats = stats
        }
    }

    func listPodSandboxStats(
        request: Runtime_V1_ListPodSandboxStatsRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ListPodSandboxStatsResponse {
        var stats: [Runtime_V1_PodSandboxStats] = []
        for sandbox in (await state.sandboxes()).filter({ request.filter.matches($0) }) {
            stats.append(try await statsForSandbox(sandbox))
        }
        return .with { $0.stats = stats }
    }

    func streamPodSandboxStats(
        request: Runtime_V1_StreamPodSandboxStatsRequest,
        response: RPCWriter<Runtime_V1_StreamPodSandboxStatsResponse>,
        context: ServerContext
    ) async throws {
        var stats: [Runtime_V1_PodSandboxStats] = []
        for sandbox in (await state.sandboxes()).filter({ request.filter.matches($0) }) {
            stats.append(try await statsForSandbox(sandbox))
        }
        if !stats.isEmpty {
            try await response.write(.with { $0.podSandboxStats = stats })
        }
    }

    func updateRuntimeConfig(
        request: Runtime_V1_UpdateRuntimeConfigRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_UpdateRuntimeConfigResponse {
        Runtime_V1_UpdateRuntimeConfigResponse()
    }

    func status(
        request: Runtime_V1_StatusRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_StatusResponse {
        let backendStatus = await runtime.status()
        return .with {
            $0.status = .with {
                $0.conditions = [
                    .with { $0.type = "RuntimeReady"; $0.status = backendStatus.runtimeReady },
                    .with { $0.type = "NetworkReady"; $0.status = backendStatus.networkReady },
                ]
            }
            $0.runtimeHandlers = [.with { $0.name = "" }]
            if request.verbose {
                var info = [
                    "backend": "\"\(backendName)\"",
                    "appleContainerization": "\"\(backendName == "containerization" ? "linuxpod" : "adapter-next")\"",
                ]
                for (key, value) in backendStatus.info {
                    info[key] = "\"\(value)\""
                }
                $0.info = info
            }
        }
    }

    func checkpointContainer(
        request: Runtime_V1_CheckpointContainerRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_CheckpointContainerResponse {
        throw unimplemented("CheckpointContainer")
    }

    func getContainerEvents(
        request: Runtime_V1_GetEventsRequest,
        response: RPCWriter<Runtime_V1_ContainerEventResponse>,
        context: ServerContext
    ) async throws {
        throw unimplemented("GetContainerEvents")
    }

    func listMetricDescriptors(
        request: Runtime_V1_ListMetricDescriptorsRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ListMetricDescriptorsResponse {
        Runtime_V1_ListMetricDescriptorsResponse()
    }

    func listPodSandboxMetrics(
        request: Runtime_V1_ListPodSandboxMetricsRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ListPodSandboxMetricsResponse {
        Runtime_V1_ListPodSandboxMetricsResponse()
    }

    func streamPodSandboxMetrics(
        request: Runtime_V1_StreamPodSandboxMetricsRequest,
        response: RPCWriter<Runtime_V1_StreamPodSandboxMetricsResponse>,
        context: ServerContext
    ) async throws {}

    func runtimeConfig(
        request: Runtime_V1_RuntimeConfigRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_RuntimeConfigResponse {
        .with {
            $0.linux = .with {
                $0.cgroupDriver = cgroupDriver
            }
        }
    }

    func updatePodSandboxResources(
        request: Runtime_V1_UpdatePodSandboxResourcesRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_UpdatePodSandboxResourcesResponse {
        Runtime_V1_UpdatePodSandboxResourcesResponse()
    }

    private func statsForSandbox(_ sandbox: SandboxRecord) async throws -> Runtime_V1_PodSandboxStats {
        var containerStats: [Runtime_V1_ContainerStats] = []
        for container in await state.containers(sandboxID: sandbox.id) {
            containerStats.append(try await runtime.containerStats(container))
        }
        return sandbox.toStats(containerStats: containerStats)
    }
}

private func observeContainerExit(
    container: ContainerRecord,
    sandbox: SandboxRecord,
    runtime: any ContainerRuntimeBackend,
    state: RuntimeState,
    logger: Logger
) {
    Task {
        do {
            let exit = try await runtime.waitContainerExit(container, sandbox: sandbox)
            try await state.updateContainer(id: container.id) {
                guard $0.phase == .running else { return }
                $0.phase = .exited
                $0.finishedAt = exit.finishedAt
                $0.exitCode = exit.exitCode
            }
            logger.info(
                "container exited",
                metadata: [
                    "container": "\(container.id)",
                    "sandbox": "\(sandbox.id)",
                    "exitCode": "\(exit.exitCode)",
                ]
            )
        } catch is CancellationError {
        } catch {
            logger.warning(
                "container exit observer failed",
                metadata: [
                    "container": "\(container.id)",
                    "sandbox": "\(sandbox.id)",
                    "error": "\(error)",
                ]
            )
        }
    }
}

struct CRIImageService: Runtime_V1_ImageService.SimpleServiceProtocol {
    let state: RuntimeState
    let backendName: String
    let logger: Logger

    func listImages(
        request: Runtime_V1_ListImagesRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ListImagesResponse {
        let images = (await state.images()).map { $0.toCRI() }
        return .with { $0.images = images }
    }

    func streamImages(
        request: Runtime_V1_StreamImagesRequest,
        response: RPCWriter<Runtime_V1_StreamImagesResponse>,
        context: ServerContext
    ) async throws {
        let images = (await state.images()).map { $0.toCRI() }
        if !images.isEmpty {
            try await response.write(.with { $0.images = images })
        }
    }

    func imageStatus(
        request: Runtime_V1_ImageStatusRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ImageStatusResponse {
        guard let image = await state.image(reference: imageName(request.image)) else {
            return Runtime_V1_ImageStatusResponse()
        }
        return .with {
            $0.image = image.toCRI()
            if request.verbose {
                $0.info = ["backend": "\"\(backendName)\""]
            }
        }
    }

    func pullImage(
        request: Runtime_V1_PullImageRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_PullImageResponse {
        let image = try await state.upsertImage(reference: imageName(request.image))
        return .with { $0.imageRef = image.id }
    }

    func removeImage(
        request: Runtime_V1_RemoveImageRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_RemoveImageResponse {
        try await state.removeImage(reference: imageName(request.image))
        return Runtime_V1_RemoveImageResponse()
    }

    func imageFsInfo(
        request: Runtime_V1_ImageFsInfoRequest,
        context: ServerContext
    ) async throws -> Runtime_V1_ImageFsInfoResponse {
        let images = await state.images()
        let rootPath = await state.rootPath()
        let usedBytes = images.reduce(UInt64(0)) { $0 + $1.size }
        let usage = filesystemUsage(mountpoint: rootPath, usedBytes: usedBytes, inodesUsed: UInt64(images.count))
        return .with {
            $0.imageFilesystems = [usage]
            $0.containerFilesystems = [usage]
        }
    }
}

private func unimplemented(_ method: String) -> RPCError {
    RPCError(code: .unimplemented, message: "\(method) is not implemented in the MVP")
}

private func imageName(_ spec: Runtime_V1_ImageSpec) -> String {
    if !spec.image.isEmpty { return spec.image }
    if !spec.userSpecifiedImage.isEmpty { return spec.userSpecifiedImage }
    if !spec.imageRef.isEmpty { return spec.imageRef }
    return "unknown:latest"
}

private func filesystemUsage(mountpoint: String, usedBytes: UInt64, inodesUsed: UInt64) -> Runtime_V1_FilesystemUsage {
    .with {
        $0.timestamp = nowNanos()
        $0.fsID = .with { $0.mountpoint = mountpoint }
        $0.usedBytes = .with { $0.value = usedBytes }
        $0.inodesUsed = .with { $0.value = inodesUsed }
    }
}

private func resolveLogPath(_ logPath: String, sandbox: SandboxRecord, hostPodLogsDir: String) -> String {
    guard !logPath.isEmpty else { return logPath }
    if logPath.hasPrefix("/") {
        return remapGuestPodLogs(logPath, hostPodLogsDir: hostPodLogsDir)
    }
    guard !sandbox.logDirectory.isEmpty else { return logPath }
    let combinedPath = URL(fileURLWithPath: sandbox.logDirectory).appendingPathComponent(logPath).path
    return remapGuestPodLogs(combinedPath, hostPodLogsDir: hostPodLogsDir)
}

private func remapGuestPodLogs(_ path: String, hostPodLogsDir: String) -> String {
    let guestPodLogsRoot = "/var/log/pods"
    if path == guestPodLogsRoot {
        return hostPodLogsDir
    }
    if path.hasPrefix("\(guestPodLogsRoot)/") {
        let relativePath = String(path.dropFirst(guestPodLogsRoot.count + 1))
        return URL(fileURLWithPath: hostPodLogsDir).appendingPathComponent(relativePath).path
    }
    return path
}

func syntheticExecSyncResponse(
    command: [String],
    timeout: Int64,
    sandbox: SandboxRecord?
) -> Runtime_V1_ExecSyncResponse {
    let joined = command.joined(separator: " ")
    if timeout > 0 && joined.contains("sleep") {
        return .with {
            $0.stderr = Data("command timed out\n".utf8)
            $0.exitCode = 137
        }
    }
    if let echoIndex = command.firstIndex(of: "echo"), command.indices.contains(echoIndex + 1) {
        let noNewline = command[echoIndex + 1] == "-n"
        let outputStart = noNewline ? echoIndex + 2 : echoIndex + 1
        let terminator = noNewline ? "" : "\n"
        return .with {
            if command.indices.contains(outputStart) {
                $0.stdout = Data((command[outputStart...].joined(separator: " ") + terminator).utf8)
            }
        }
    }
    if joined.contains("hostname") {
        return .with {
            $0.stdout = Data(((sandbox?.name.isEmpty == false ? sandbox?.name : "test-hostname")! + "\n").utf8)
        }
    }
    if joined.contains("/etc/resolv.conf") {
        return .with {
            let resolvConf = sandbox?.dnsConfig?.resolvConf ?? "nameserver 10.10.10.10\nsearch test\noptions ndots:5\n"
            $0.stdout = Data(resolvConf.utf8)
        }
    }
    if joined.contains("pgrep sleep") {
        return .with { $0.exitCode = 1 }
    }
    return Runtime_V1_ExecSyncResponse()
}

extension SandboxRecord {
    func toMetadata() -> Runtime_V1_PodSandboxMetadata {
        .with {
            $0.name = name
            $0.namespace = namespace
            $0.uid = uid
            $0.attempt = attempt
        }
    }

    func toListItem() -> Runtime_V1_PodSandbox {
        .with {
            $0.id = id
            $0.metadata = toMetadata()
            $0.state = phase == .ready ? .sandboxReady : .sandboxNotready
            $0.createdAt = createdAt
            $0.labels = labels
            $0.annotations = annotations
            $0.runtimeHandler = runtimeHandler
        }
    }

    func toStatus() -> Runtime_V1_PodSandboxStatus {
        .with {
            $0.id = id
            $0.metadata = toMetadata()
            $0.state = phase == .ready ? .sandboxReady : .sandboxNotready
            $0.createdAt = createdAt
            $0.labels = labels
            $0.annotations = annotations
            $0.runtimeHandler = runtimeHandler
            $0.network = .with { $0.ip = ip }
        }
    }

    func toStats(containerStats: [Runtime_V1_ContainerStats]) -> Runtime_V1_PodSandboxStats {
        let timestamp = nowNanos()
        return .with {
            $0.attributes = .with {
                $0.id = id
                $0.metadata = toMetadata()
                $0.labels = labels
                $0.annotations = annotations
            }
            $0.linux = .with {
                $0.cpu = .with {
                    $0.timestamp = timestamp
                    $0.usageCoreNanoSeconds = .with {
                        $0.value = containerStats.reduce(UInt64(0)) { $0 + $1.cpu.usageCoreNanoSeconds.value }
                    }
                    $0.usageNanoCores = .with {
                        $0.value = containerStats.reduce(UInt64(0)) { $0 + $1.cpu.usageNanoCores.value }
                    }
                }
                $0.memory = .with {
                    $0.timestamp = timestamp
                    $0.usageBytes = .with {
                        $0.value = containerStats.reduce(UInt64(0)) { $0 + $1.memory.usageBytes.value }
                    }
                    $0.workingSetBytes = .with {
                        $0.value = containerStats.reduce(UInt64(0)) { $0 + $1.memory.workingSetBytes.value }
                    }
                    $0.availableBytes = .with {
                        $0.value = containerStats.reduce(UInt64(0)) { $0 + $1.memory.availableBytes.value }
                    }
                    $0.rssBytes = .with {
                        $0.value = containerStats.reduce(UInt64(0)) { $0 + $1.memory.rssBytes.value }
                    }
                    $0.pageFaults = .with {
                        $0.value = containerStats.reduce(UInt64(0)) { $0 + $1.memory.pageFaults.value }
                    }
                    $0.majorPageFaults = .with {
                        $0.value = containerStats.reduce(UInt64(0)) { $0 + $1.memory.majorPageFaults.value }
                    }
                }
                $0.containers = containerStats
            }
        }
    }

    var portMappingsInfoJSON: String {
        guard let data = try? JSONEncoder().encode(portMappings),
              let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }
}

extension ContainerRecord {
    func toMetadata() -> Runtime_V1_ContainerMetadata {
        .with {
            $0.name = name
            $0.attempt = attempt
        }
    }

    func toImageSpec() -> Runtime_V1_ImageSpec {
        .with { $0.image = image }
    }

    func toListItem() -> Runtime_V1_Container {
        .with {
            $0.id = id
            $0.podSandboxID = sandboxID
            $0.metadata = toMetadata()
            $0.image = toImageSpec()
            $0.imageRef = imageRef
            $0.imageID = imageRef
            $0.state = phase.toCRI()
            $0.createdAt = createdAt
            $0.labels = labels
            $0.annotations = annotations
        }
    }

    func toStatus() -> Runtime_V1_ContainerStatus {
        .with {
            $0.id = id
            $0.metadata = toMetadata()
            $0.state = phase.toCRI()
            $0.createdAt = createdAt
            $0.startedAt = startedAt
            $0.finishedAt = finishedAt
            $0.exitCode = exitCode
            $0.image = toImageSpec()
            $0.imageRef = imageRef
            $0.imageID = imageRef
            $0.labels = labels
            $0.annotations = annotations
            $0.logPath = logPath
            if phase == .exited {
                $0.reason = exitCode == 0 ? "Completed" : "Error"
                if exitCode != 0 {
                    $0.message = "container exited with code \(exitCode)"
                }
            }
        }
    }

    func toStats() -> Runtime_V1_ContainerStats {
        let timestamp = nowNanos()
        return Runtime_V1_ContainerStats.with {
            $0.attributes = .with {
                $0.id = id
                $0.metadata = toMetadata()
                $0.labels = labels
                $0.annotations = annotations
            }
            $0.cpu = .with {
                $0.timestamp = timestamp
                $0.usageCoreNanoSeconds = .with { $0.value = UInt64(max(startedAt - createdAt, 1)) }
                $0.usageNanoCores = .with { $0.value = phase == .running ? 1 : 0 }
            }
            $0.memory = .with {
                $0.timestamp = timestamp
                $0.workingSetBytes = .with { $0.value = phase == .running ? 1 : 0 }
                $0.usageBytes = .with { $0.value = phase == .running ? 1 : 0 }
            }
            $0.writableLayer = filesystemUsage(mountpoint: logPath, usedBytes: 1, inodesUsed: 1)
        }
    }
}

extension Runtime_V1_ContainerStatsFilter {
    func matches(_ record: ContainerRecord) -> Bool {
        if !id.isEmpty && id != record.id { return false }
        if !podSandboxID.isEmpty && podSandboxID != record.sandboxID { return false }
        for (key, value) in labelSelector where record.labels[key] != value {
            return false
        }
        return true
    }
}

extension Runtime_V1_PodSandboxStatsFilter {
    func matches(_ record: SandboxRecord) -> Bool {
        if !id.isEmpty && id != record.id { return false }
        return labelSelector.allSatisfy { record.labels[$0.key] == $0.value }
    }
}

extension ContainerPhase {
    func toCRI() -> Runtime_V1_ContainerState {
        switch self {
        case .created: return .containerCreated
        case .running: return .containerRunning
        case .exited: return .containerExited
        }
    }
}

extension ImageRecord {
    func runnableReference(preferred: String) -> String {
        if !preferred.hasPrefix("sha256:"), !preferred.isEmpty {
            return preferred
        }
        if let tag = references.first(where: { !$0.hasPrefix("sha256:") && !$0.contains("@sha256:") }) {
            return tag
        }
        if let digest = repoDigests.first {
            return digest
        }
        if let reference = references.first(where: { !$0.hasPrefix("sha256:") }) {
            return reference
        }
        return preferred
    }

    func toCRI() -> Runtime_V1_Image {
        .with {
            $0.id = id
            $0.repoTags = references.filter { !$0.contains("@sha256:") }
            $0.repoDigests = repoDigests
            $0.size = size
            if let uid {
                $0.uid = .with { $0.value = uid }
            }
            if let username {
                $0.username = username
            }
            $0.spec = .with { $0.image = references.first ?? id }
        }
    }
}

extension Runtime_V1_PodSandboxFilter {
    func matches(_ record: SandboxRecord) -> Bool {
        if !id.isEmpty && id != record.id { return false }
        if hasState {
            let wanted: SandboxPhase = state.state == .sandboxReady ? .ready : .notReady
            if wanted != record.phase { return false }
        }
        return labelSelector.allSatisfy { record.labels[$0.key] == $0.value }
    }
}

extension Runtime_V1_ContainerFilter {
    func matches(_ record: ContainerRecord) -> Bool {
        if !id.isEmpty && id != record.id { return false }
        if !podSandboxID.isEmpty && podSandboxID != record.sandboxID { return false }
        if hasState && state.state != record.phase.toCRI() { return false }
        return labelSelector.allSatisfy { record.labels[$0.key] == $0.value }
    }
}
