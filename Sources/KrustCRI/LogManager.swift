import Foundation
import Containerization
import Synchronization

enum LogManagerError: Error, Equatable, CustomStringConvertible {
    case emptyLogPath

    var description: String {
        switch self {
        case .emptyLogPath:
            return "container log path is empty"
        }
    }
}

func reopenCRIContainerLogFile(_ path: String) throws {
    guard !path.isEmpty else {
        throw LogManagerError.emptyLogPath
    }

    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )

    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
}

func ensureCRIContainerLogFile(_ path: String) throws {
    guard !path.isEmpty else { return }
    try reopenCRIContainerLogFile(path)
}

final class CRIFileLogWriter: Writer, @unchecked Sendable {
    private struct State {
        var handle: FileHandle
    }

    private let path: URL
    private let stream: String
    private let state: Mutex<State>

    init(path: URL, stream: String) throws {
        self.path = path
        self.stream = stream
        self.state = Mutex(State(handle: try Self.openHandle(at: path)))
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(stream) F \(String(decoding: data, as: UTF8.self))"
        guard let encoded = line.data(using: .utf8) else { return }
        try state.withLock { current in
            try current.handle.write(contentsOf: encoded)
        }
    }

    func reopen() throws {
        try state.withLock { current in
            try current.handle.close()
            current.handle = try Self.openHandle(at: path)
        }
    }

    func close() throws {
        try state.withLock { current in
            try current.handle.close()
        }
    }

    private static func openHandle(at path: URL) throws -> FileHandle {
        try reopenCRIContainerLogFile(path.path)
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        return handle
    }
}

struct ContainerLogWriters: Sendable {
    var stdout: CRIFileLogWriter
    var stderr: CRIFileLogWriter

    func reopen() throws {
        try stdout.reopen()
        try stderr.reopen()
    }

    func close() {
        try? stdout.close()
        try? stderr.close()
    }
}
