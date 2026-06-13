import ArgumentParser
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Logging
import NIOCore
import NIOPosix

@main
struct KrustCRICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "krust-cri",
        abstract: "Minimal macOS CRI runtime proof of concept."
    )

    @Option(help: "Unix domain socket path to listen on.")
    var listen: String = "/tmp/krust-cri.sock"

    @Option(help: "Runtime state directory.")
    var stateDir: String = "/tmp/krust-cri-state"

    @Option(help: "Runtime name reported through CRI.")
    var runtimeName: String = "krust-cri"

    @Option(help: "Runtime version reported through CRI.")
    var runtimeVersion: String = "0.1.0-mvp"

    @Option(help: "Backend to use: mvp or containerization.")
    var backend: String = "mvp"

    @Option(help: "Linux cgroup driver reported through RuntimeConfig: systemd or cgroupfs.")
    var cgroupDriver: String = "systemd"

    @Option(help: "Host directory used when kubelet requests container logs under /var/log/pods.")
    var hostPodLogsDir: String = "/tmp/krust-cri-pod-logs"

    @Option(help: "Linux kernel path for the containerization backend.")
    var kernel: String?

    @Option(help: "Init filesystem OCI reference for the containerization backend.")
    var initfsReference: String = "vminit:latest"

    @Option(help: "Image/rootfs state root for the containerization backend.")
    var containerizationRoot: String?

    @Flag(help: "Enable Rosetta for linux/amd64 containers in the containerization backend.")
    var rosetta = false

    func run() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardError)
        let logger = Logger(label: "krust-cri")
        let state = try await RuntimeState(path: URL(fileURLWithPath: stateDir))
        let runtime: any ContainerRuntimeBackend
        switch backend {
        case "mvp":
            runtime = MVPContainerRuntime(state: state, logger: logger)
        case "containerization":
            guard let kernel else {
                throw ValidationError("--kernel is required when --backend containerization")
            }
            runtime = try await ContainerizationRuntimeBackend(
                kernelPath: URL(fileURLWithPath: kernel),
                initfsReference: initfsReference,
                root: containerizationRoot.map { URL(fileURLWithPath: $0) },
                rosetta: rosetta,
                logger: logger
            )
        default:
            throw ValidationError("--backend must be either 'mvp' or 'containerization'")
        }
        let runtimeCgroupDriver: Runtime_V1_CgroupDriver
        switch cgroupDriver {
        case "systemd":
            runtimeCgroupDriver = .systemd
        case "cgroupfs":
            runtimeCgroupDriver = .cgroupfs
        default:
            throw ValidationError("--cgroup-driver must be either 'systemd' or 'cgroupfs'")
        }
        let runtimeService = CRIRuntimeService(
            runtimeName: runtimeName,
            runtimeVersion: runtimeVersion,
            state: state,
            runtime: runtime,
            backendName: backend,
            cgroupDriver: runtimeCgroupDriver,
            hostPodLogsDir: hostPodLogsDir,
            logger: logger
        )
        let imageService = CRIImageService(state: state, backendName: backend, logger: logger)

        try? FileManager.default.removeItem(atPath: listen)

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let server = GRPCServer(
            transport: .http2NIOPosix(
                address: .unixDomainSocket(path: listen),
                transportSecurity: .plaintext,
                eventLoopGroup: group
            ),
            services: [runtimeService, imageService]
        )

        logger.info("starting CRI server", metadata: ["listen": "\(listen)", "state": "\(stateDir)"])
        try await server.serve()
        try await group.shutdownGracefully()
    }
}
