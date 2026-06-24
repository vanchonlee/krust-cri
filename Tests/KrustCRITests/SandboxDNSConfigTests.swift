import XCTest
@testable import KrustCRI

final class SandboxDNSConfigTests: XCTestCase {
    func testDNSConfigBuildsResolvConf() {
        let config = SandboxDNSConfig(
            servers: ["10.43.0.10", "fd00::10"],
            searches: ["default.svc.cluster.local", "svc.cluster.local"],
            options: ["ndots:5", "timeout:2"]
        )

        XCTAssertEqual(
            config.resolvConf,
            """
            nameserver 10.43.0.10
            nameserver fd00::10
            search default.svc.cluster.local svc.cluster.local
            options ndots:5 timeout:2

            """
        )
    }

    func testDNSConfigFromCRIUsesNilForEmptyConfig() {
        XCTAssertNil(SandboxDNSConfig(cri: Runtime_V1_DNSConfig()))
    }

    func testExecSyncResolvConfUsesSandboxDNSConfig() {
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
            dnsConfig: SandboxDNSConfig(
                servers: ["10.43.0.10"],
                searches: ["default.svc.cluster.local"],
                options: ["ndots:5"]
            )
        )

        let response = syntheticExecSyncResponse(
            command: ["cat", "/etc/resolv.conf"],
            timeout: 0,
            sandbox: sandbox
        )

        XCTAssertEqual(
            String(decoding: response.stdout, as: UTF8.self),
            """
            nameserver 10.43.0.10
            search default.svc.cluster.local
            options ndots:5

            """
        )
    }
}
