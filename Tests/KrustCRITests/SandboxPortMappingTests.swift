import XCTest
@testable import KrustCRI

final class SandboxPortMappingTests: XCTestCase {
    func testPortMappingFromCRIKeepsProtocolPortsAndHostIP() {
        let mapping = SandboxPortMapping(cri: Runtime_V1_PortMapping.with {
            $0.protocol = .udp
            $0.containerPort = 53
            $0.hostPort = 1053
            $0.hostIp = "127.0.0.1"
        })

        XCTAssertEqual(mapping.protocol, "udp")
        XCTAssertEqual(mapping.containerPort, 53)
        XCTAssertEqual(mapping.hostPort, 1053)
        XCTAssertEqual(mapping.hostIP, "127.0.0.1")
    }

    func testPortMappingsInfoJSONIsStable() throws {
        let sandbox = SandboxRecord(
            id: "pod-test",
            name: "demo",
            namespace: "default",
            attempt: 0,
            uid: "uid-test",
            labels: [:],
            annotations: [:],
            runtimeHandler: "",
            logDirectory: "/tmp/pods/demo",
            createdAt: 100,
            phase: .ready,
            ip: "10.88.0.2",
            portMappings: [
                SandboxPortMapping(protocol: "tcp", containerPort: 8080, hostPort: 18080, hostIP: "127.0.0.1"),
                SandboxPortMapping(protocol: "udp", containerPort: 53, hostPort: 1053, hostIP: ""),
            ]
        )

        let data = Data(sandbox.portMappingsInfoJSON.utf8)
        let decoded = try JSONDecoder().decode([SandboxPortMapping].self, from: data)

        XCTAssertEqual(decoded, sandbox.portMappings)
        XCTAssertTrue(sandbox.portMappingsInfoJSON.contains("\"containerPort\":8080"))
        XCTAssertTrue(sandbox.portMappingsInfoJSON.contains("\"hostPort\":18080"))
    }

    func testEmptyPortMappingsInfoJSONIsEmptyArray() {
        XCTAssertEqual(SandboxRecord.makePortMappingTestRecord().portMappingsInfoJSON, "[]")
    }
}

private extension SandboxRecord {
    static func makePortMappingTestRecord() -> SandboxRecord {
        SandboxRecord(
            id: "pod-test",
            name: "demo",
            namespace: "default",
            attempt: 0,
            uid: "uid-test",
            labels: [:],
            annotations: [:],
            runtimeHandler: "",
            logDirectory: "/tmp/pods/demo",
            createdAt: 100,
            phase: .ready,
            ip: "10.88.0.2"
        )
    }
}
