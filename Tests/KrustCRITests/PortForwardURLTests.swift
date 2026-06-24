import XCTest
@testable import KrustCRI

final class PortForwardURLTests: XCTestCase {
    func testPortForwardURLIncludesSandboxAndSortedPorts() {
        let url = makePortForwardURL(podSandboxID: "pod-test", ports: [443, 80])

        XCTAssertEqual(url, "krust-cri://portforward/pod-test?ports=80,443")
    }

    func testPortForwardURLEncodesSandboxID() {
        let url = makePortForwardURL(podSandboxID: "pod/test id", ports: [8080])

        XCTAssertEqual(url, "krust-cri://portforward/pod%2Ftest%20id?ports=8080")
    }

    func testPortForwardURLDropsDuplicatePorts() {
        let url = makePortForwardURL(podSandboxID: "pod-test", ports: [8080, 8080, 80])

        XCTAssertEqual(url, "krust-cri://portforward/pod-test?ports=80,8080")
    }

    func testPortForwardFallsBackToSandboxPortMappingsWhenRequestPortsAreEmpty() {
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

        XCTAssertEqual(resolvedPortForwardPorts(requestedPorts: [], sandbox: sandbox), [53, 8080])
    }

    func testPortForwardUsesExplicitRequestPortsBeforeSandboxMappings() {
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
                SandboxPortMapping(protocol: "tcp", containerPort: 8080, hostPort: 18080, hostIP: "127.0.0.1")
            ]
        )

        XCTAssertEqual(resolvedPortForwardPorts(requestedPorts: [9090], sandbox: sandbox), [9090])
    }
}
