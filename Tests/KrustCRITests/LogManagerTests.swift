import XCTest
@testable import KrustCRI

final class LogManagerTests: XCTestCase {
    func testReopenContainerLogCreatesMissingParentAndFile() throws {
        let root = try temporaryDirectory()
        let logPath = root.appendingPathComponent("pods/default_test_uid/container/0.log")

        try reopenCRIContainerLogFile(logPath.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath.path))
    }

    func testReopenContainerLogKeepsExistingContent() throws {
        let root = try temporaryDirectory()
        let logPath = root.appendingPathComponent("container/0.log")
        try FileManager.default.createDirectory(
            at: logPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "existing\n".write(to: logPath, atomically: true, encoding: .utf8)

        try reopenCRIContainerLogFile(logPath.path)

        XCTAssertEqual(try String(contentsOf: logPath, encoding: .utf8), "existing\n")
    }

    func testReopenContainerLogRejectsEmptyPath() throws {
        XCTAssertThrowsError(try reopenCRIContainerLogFile("")) { error in
            XCTAssertEqual(error as? LogManagerError, .emptyLogPath)
        }
    }

    func testFileLogWriterReopensAfterLogRotation() throws {
        let root = try temporaryDirectory()
        let logPath = root.appendingPathComponent("container/0.log")
        let rotatedLogPath = root.appendingPathComponent("container/0.log.1")
        let writer = try CRIFileLogWriter(path: logPath, stream: "stdout")

        try writer.write(Data("before\n".utf8))
        try FileManager.default.moveItem(at: logPath, to: rotatedLogPath)

        try writer.reopen()
        try writer.write(Data("after\n".utf8))
        try writer.close()

        let rotated = try String(contentsOf: rotatedLogPath, encoding: .utf8)
        let current = try String(contentsOf: logPath, encoding: .utf8)
        XCTAssertTrue(rotated.contains("stdout F before\n"))
        XCTAssertTrue(current.contains("stdout F after\n"))
    }

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("krust-cri-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
