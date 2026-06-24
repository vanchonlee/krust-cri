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
}
