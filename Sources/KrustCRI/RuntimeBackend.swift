import Foundation
import Logging

struct RuntimeBackendStatus: Sendable {
    var runtimeReady: Bool
    var networkReady: Bool
    var info: [String: String]

    static let ready = RuntimeBackendStatus(runtimeReady: true, networkReady: true, info: [:])
}

protocol ContainerRuntimeBackend: Sendable {
    func status() async -> RuntimeBackendStatus
    func runSandbox(_ record: SandboxRecord) async throws
    func stopSandbox(_ record: SandboxRecord) async throws
    func createContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws
    func startContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws
    func stopContainer(_ record: ContainerRecord, sandbox: SandboxRecord?) async throws
    func removeContainer(_ record: ContainerRecord) async throws
}

extension ContainerRuntimeBackend {
    func status() async -> RuntimeBackendStatus { .ready }
}

struct MVPContainerRuntime: ContainerRuntimeBackend {
    let state: RuntimeState
    let logger: Logger

    func runSandbox(_ record: SandboxRecord) async throws {
        logger.info("mvp sandbox ready", metadata: ["sandbox": "\(record.id)"])
    }

    func stopSandbox(_ record: SandboxRecord) async throws {
        logger.info("mvp sandbox stopped", metadata: ["sandbox": "\(record.id)"])
    }

    func createContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws {
        logger.info("mvp container created", metadata: ["container": "\(record.id)", "sandbox": "\(sandbox.id)"])
    }

    func startContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws {
        logger.info("mvp container started", metadata: ["container": "\(record.id)", "sandbox": "\(sandbox.id)"])
    }

    func stopContainer(_ record: ContainerRecord, sandbox: SandboxRecord?) async throws {
        logger.info("mvp container stopped", metadata: ["container": "\(record.id)"])
    }

    func removeContainer(_ record: ContainerRecord) async throws {
        logger.info("mvp container removed", metadata: ["container": "\(record.id)"])
    }
}
