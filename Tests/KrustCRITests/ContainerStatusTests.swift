import XCTest
@testable import KrustCRI

final class ContainerStatusTests: XCTestCase {
    func testExitedContainerWithZeroExitCodeReportsCompleted() {
        let status = makeContainer(exitCode: 0).toStatus()

        XCTAssertEqual(status.reason, "Completed")
        XCTAssertEqual(status.message, "")
        XCTAssertEqual(status.exitCode, 0)
    }

    func testExitedContainerWithNonZeroExitCodeReportsError() {
        let status = makeContainer(exitCode: 42).toStatus()

        XCTAssertEqual(status.reason, "Error")
        XCTAssertEqual(status.message, "container exited with code 42")
        XCTAssertEqual(status.exitCode, 42)
    }

    func testRunningContainerDoesNotReportTerminationReason() {
        var container = makeContainer(exitCode: 0)
        container.phase = .running

        let status = container.toStatus()

        XCTAssertEqual(status.reason, "")
        XCTAssertEqual(status.message, "")
    }

    private func makeContainer(exitCode: Int32) -> ContainerRecord {
        ContainerRecord(
            id: "ctr-test",
            sandboxID: "pod-test",
            name: "test",
            attempt: 0,
            image: "docker.io/library/busybox:1.36.1",
            imageRef: "sha256:test",
            command: ["/bin/sh"],
            args: ["-c", "exit \(exitCode)"],
            labels: [:],
            annotations: [:],
            logPath: "/tmp/test.log",
            createdAt: 1,
            startedAt: 2,
            finishedAt: 3,
            exitCode: exitCode,
            phase: .exited
        )
    }
}
