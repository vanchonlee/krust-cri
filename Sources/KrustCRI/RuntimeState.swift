import Foundation

enum SandboxPhase: String, Codable, Sendable {
    case ready
    case notReady
}

enum ContainerPhase: String, Codable, Sendable {
    case created
    case running
    case exited
}

struct SandboxRecord: Codable, Sendable {
    var id: String
    var name: String
    var namespace: String
    var attempt: UInt32
    var uid: String
    var labels: [String: String]
    var annotations: [String: String]
    var runtimeHandler: String
    var createdAt: Int64
    var phase: SandboxPhase
    var ip: String
}

struct ContainerRecord: Codable, Sendable {
    var id: String
    var sandboxID: String
    var name: String
    var attempt: UInt32
    var image: String
    var imageRef: String
    var command: [String]
    var args: [String]
    var labels: [String: String]
    var annotations: [String: String]
    var logPath: String
    var createdAt: Int64
    var startedAt: Int64
    var finishedAt: Int64
    var exitCode: Int32
    var phase: ContainerPhase
}

struct ImageRecord: Codable, Sendable {
    var id: String
    var reference: String
    var size: UInt64
    var createdAt: Int64
}

struct RuntimeSnapshot: Codable, Sendable {
    var sandboxes: [String: SandboxRecord] = [:]
    var containers: [String: ContainerRecord] = [:]
    var images: [String: ImageRecord] = [:]
}

actor RuntimeState {
    private let fileURL: URL
    private var snapshot: RuntimeSnapshot

    init(path: URL) async throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        self.fileURL = path.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: self.fileURL) {
            self.snapshot = (try? JSONDecoder().decode(RuntimeSnapshot.self, from: data)) ?? RuntimeSnapshot()
        } else {
            self.snapshot = RuntimeSnapshot()
        }
    }

    func addSandbox(_ record: SandboxRecord) async throws {
        snapshot.sandboxes[record.id] = record
        try persist()
    }

    func updateSandbox(id: String, _ update: (inout SandboxRecord) -> Void) async throws {
        guard snapshot.sandboxes[id] != nil else { return }
        update(&snapshot.sandboxes[id]!)
        try persist()
    }

    func removeSandbox(id: String) async throws {
        snapshot.containers = snapshot.containers.filter { $0.value.sandboxID != id }
        snapshot.sandboxes.removeValue(forKey: id)
        try persist()
    }

    func sandbox(id: String) -> SandboxRecord? {
        snapshot.sandboxes[id]
    }

    func sandboxes() -> [SandboxRecord] {
        snapshot.sandboxes.values.sorted { $0.createdAt < $1.createdAt }
    }

    func addContainer(_ record: ContainerRecord) async throws {
        snapshot.containers[record.id] = record
        try persist()
    }

    func updateContainer(id: String, _ update: (inout ContainerRecord) -> Void) async throws {
        guard snapshot.containers[id] != nil else { return }
        update(&snapshot.containers[id]!)
        try persist()
    }

    func removeContainer(id: String) async throws {
        snapshot.containers.removeValue(forKey: id)
        try persist()
    }

    func container(id: String) -> ContainerRecord? {
        snapshot.containers[id]
    }

    func containers() -> [ContainerRecord] {
        snapshot.containers.values.sorted { $0.createdAt < $1.createdAt }
    }

    func containers(sandboxID: String) -> [ContainerRecord] {
        snapshot.containers.values.filter { $0.sandboxID == sandboxID }.sorted { $0.createdAt < $1.createdAt }
    }

    func upsertImage(reference: String) async throws -> ImageRecord {
        if let existing = snapshot.images[reference] {
            return existing
        }
        let record = ImageRecord(
            id: "sha256:\(stableHex(reference))",
            reference: reference,
            size: 1,
            createdAt: nowNanos()
        )
        snapshot.images[reference] = record
        try persist()
        return record
    }

    func removeImage(reference: String) async throws {
        snapshot.images.removeValue(forKey: reference)
        snapshot.images = snapshot.images.filter { $0.value.id != reference }
        try persist()
    }

    func image(reference: String) -> ImageRecord? {
        snapshot.images[reference] ?? snapshot.images.values.first { $0.id == reference }
    }

    func images() -> [ImageRecord] {
        snapshot.images.values.sorted { $0.createdAt < $1.createdAt }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }
}

func nowNanos() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1_000_000_000)
}

func makeID(prefix: String, seed: String) -> String {
    "\(prefix)-\(stableHex(seed + "-\(nowNanos())").prefix(16))"
}

func stableHex(_ string: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}
