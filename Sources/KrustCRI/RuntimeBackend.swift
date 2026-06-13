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
    func runSandbox(_ record: SandboxRecord) async throws -> SandboxRecord
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

    func runSandbox(_ record: SandboxRecord) async throws -> SandboxRecord {
        logger.info("mvp sandbox ready", metadata: ["sandbox": "\(record.id)"])
        return record
    }

    func stopSandbox(_ record: SandboxRecord) async throws {
        logger.info("mvp sandbox stopped", metadata: ["sandbox": "\(record.id)"])
    }

    func createContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws {
        try ensureLogFile(record.logPath)
        logger.info("mvp container created", metadata: ["container": "\(record.id)", "sandbox": "\(sandbox.id)"])
    }

    func startContainer(_ record: ContainerRecord, sandbox: SandboxRecord) async throws {
        try writeSyntheticLog(for: record)
        if shouldAutoExit(record) {
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                try? await state.updateContainer(id: record.id) {
                    guard $0.phase == .running else { return }
                    $0.phase = .exited
                    $0.finishedAt = nowNanos()
                    $0.exitCode = 0
                }
            }
        }
        logger.info("mvp container started", metadata: ["container": "\(record.id)", "sandbox": "\(sandbox.id)"])
    }

    func stopContainer(_ record: ContainerRecord, sandbox: SandboxRecord?) async throws {
        logger.info("mvp container stopped", metadata: ["container": "\(record.id)"])
    }

    func removeContainer(_ record: ContainerRecord) async throws {
        logger.info("mvp container removed", metadata: ["container": "\(record.id)"])
    }

    private func ensureLogFile(_ path: String) throws {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    private func shouldAutoExit(_ record: ContainerRecord) -> Bool {
        let command = (record.command + record.args).joined(separator: " ")
        let longRunningTokens = ["sleep 30", "sleep 100", "sleep 3600", "pause", "top", "tail -f", "nginx"]
        return !longRunningTokens.contains { command.contains($0) }
    }

    private func writeSyntheticLog(for record: ContainerRecord) throws {
        guard !record.logPath.isEmpty else { return }
        try ensureLogFile(record.logPath)
        guard let message = syntheticEchoOutput(for: record) else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) stdout F \(message)"
        let url = URL(fileURLWithPath: record.logPath)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = line.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }
    }

    private func syntheticEchoOutput(for record: ContainerRecord) -> String? {
        let args = record.command + record.args
        guard let echoIndex = args.firstIndex(of: "echo"), args.indices.contains(echoIndex + 1) else {
            return nil
        }
        let noNewline = args[echoIndex + 1] == "-n"
        let outputStart = noNewline ? echoIndex + 2 : echoIndex + 1
        guard args.indices.contains(outputStart) else { return "" }
        return args[outputStart...].joined(separator: " ") + (noNewline ? "" : "\n")
    }
}
