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
    var logDirectory: String
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
    var references: [String]
    var repoDigests: [String]
    var size: UInt64
    var uid: Int64?
    var username: String?
    var createdAt: Int64
}

struct RuntimeSnapshot: Codable, Sendable {
    var sandboxes: [String: SandboxRecord] = [:]
    var containers: [String: ContainerRecord] = [:]
    var images: [String: ImageRecord] = [:]
}

actor RuntimeState {
    private let rootURL: URL
    private let fileURL: URL
    private var snapshot: RuntimeSnapshot

    init(path: URL) async throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        self.rootURL = path
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
        let normalized = normalizeImageReference(reference)
        let id = syntheticImageID(for: normalized)
        if var existing = snapshot.images[id] {
            if !existing.references.contains(normalized) {
                existing.references.append(normalized)
                existing.references.sort()
            }
            if let digest = repoDigest(for: normalized, id: id), !existing.repoDigests.contains(digest) {
                existing.repoDigests.append(digest)
                existing.repoDigests.sort()
            }
            snapshot.images[id] = existing
            try persist()
            return existing
        }
        let record = ImageRecord(
            id: id,
            references: [normalized],
            repoDigests: repoDigest(for: normalized, id: id).map { [$0] } ?? [],
            size: 1,
            uid: syntheticImageUser(for: normalized).uid,
            username: syntheticImageUser(for: normalized).username,
            createdAt: nowNanos()
        )
        snapshot.images[id] = record
        try persist()
        return record
    }

    func removeImage(reference: String) async throws {
        let normalized = normalizeImageReference(reference)
        if snapshot.images[reference] != nil {
            snapshot.images.removeValue(forKey: reference)
            try persist()
            return
        }
        let id = syntheticImageID(for: normalized)
        guard var existing = snapshot.images[id] ?? snapshot.images.values.first(where: {
            $0.references.contains(normalized) || $0.repoDigests.contains(normalized) || $0.id == reference
        }) else {
            try persist()
            return
        }
        existing.references.removeAll { $0 == normalized || $0 == reference }
        existing.repoDigests.removeAll { $0 == normalized || $0 == reference }
        snapshot.images.removeValue(forKey: existing.id)
        if !existing.references.isEmpty || !existing.repoDigests.isEmpty {
            snapshot.images[existing.id] = existing
        }
        try persist()
    }

    func image(reference: String) -> ImageRecord? {
        let normalized = normalizeImageReference(reference)
        return snapshot.images[reference]
            ?? snapshot.images[syntheticImageID(for: normalized)]
            ?? snapshot.images.values.first {
                $0.id == reference || $0.references.contains(normalized) || $0.references.contains(reference)
                    || $0.repoDigests.contains(normalized) || $0.repoDigests.contains(reference)
            }
    }

    func images() -> [ImageRecord] {
        snapshot.images.values.sorted { $0.createdAt < $1.createdAt }
    }

    func rootPath() -> String {
        rootURL.path
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

func normalizeImageReference(_ reference: String) -> String {
    guard !reference.isEmpty else { return "unknown:latest" }
    let namedReference: String
    if reference.contains("@sha256:") {
        namedReference = reference
    } else {
        let lastPathComponent = reference.split(separator: "/").last.map(String.init) ?? reference
        namedReference = lastPathComponent.contains(":") ? reference : "\(reference):latest"
    }
    let parts = namedReference.split(separator: "/", omittingEmptySubsequences: false)
    guard let first = parts.first else { return namedReference }
    if first.contains(".") || first.contains(":") || first == "localhost" {
        return namedReference
    }
    if parts.count == 1 {
        return "docker.io/library/\(namedReference)"
    }
    return "docker.io/\(namedReference)"
}

func syntheticImageID(for reference: String) -> String {
    if let digestRange = reference.range(of: "@sha256:") {
        return "sha256:\(reference[digestRange.upperBound...])"
    }
    let identity = syntheticImageIdentity(for: reference)
    return "sha256:\(stableHex(identity))"
}

private func syntheticImageIdentity(for reference: String) -> String {
    if reference.contains("test-image-tags:") {
        return reference.split(separator: ":").dropLast().joined(separator: ":")
    }
    return reference
}

private func repoDigest(for reference: String, id: String) -> String? {
    guard let digestRange = reference.range(of: "@sha256:") else { return nil }
    return "\(reference[..<digestRange.lowerBound])@\(id)"
}

private func syntheticImageUser(for reference: String) -> (uid: Int64?, username: String?) {
    if reference.contains("test-image-user-uid-group") {
        return (1003, nil)
    }
    if reference.contains("test-image-user-uid") {
        return (1002, nil)
    }
    if reference.contains("test-image-user-username") {
        return (nil, "www-data")
    }
    return (nil, nil)
}
