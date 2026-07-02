import XCTest
@testable import KrustCRI

final class PortForwardURLTests: XCTestCase {
    func testPortForwardURLIncludesSandboxAndSortedPorts() {
        let url = makePortForwardURL(
            podSandboxID: "pod-test",
            targetHost: "10.88.0.2",
            ports: [443, 80],
            streamBaseURL: "http://127.0.0.1:10443"
        )

        XCTAssertEqual(url, "http://127.0.0.1:10443/portforward/pod-test?ports=80,443&target=10.88.0.2")
    }

    func testPortForwardURLEncodesSandboxID() {
        let url = makePortForwardURL(
            podSandboxID: "pod/test id",
            targetHost: "fd00::10",
            ports: [8080],
            streamBaseURL: "http://127.0.0.1:10443/cri"
        )

        XCTAssertEqual(url, "http://127.0.0.1:10443/cri/portforward/pod%2Ftest%20id?ports=8080&target=fd00::10")
    }

    func testPortForwardURLDropsDuplicatePorts() {
        let url = makePortForwardURL(
            podSandboxID: "pod-test",
            targetHost: "10.88.0.2",
            ports: [8080, 8080, 80],
            streamBaseURL: "http://127.0.0.1:10443/"
        )

        XCTAssertEqual(url, "http://127.0.0.1:10443/portforward/pod-test?ports=80,8080&target=10.88.0.2")
    }

    func testPortForwardURLFallsBackToLegacySchemeWhenBridgeIsNotConfigured() {
        let url = makePortForwardURL(
            podSandboxID: "pod-test",
            targetHost: "10.88.0.2",
            ports: [8080],
            streamBaseURL: ""
        )

        XCTAssertEqual(url, "krust-cri://portforward/pod-test?ports=8080&target=10.88.0.2")
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
