import XCTest
@testable import KrustCRI

final class PodSandboxStatsTests: XCTestCase {
    func testPodSandboxStatsAggregatesContainerUsage() {
        let sandbox = makeSandbox()
        let stats = sandbox.toStats(containerStats: [
            makeContainerStats(id: "ctr-a", cpu: 10, memory: 20, workingSet: 15, rss: 12, pageFaults: 3, majorPageFaults: 1, swap: 4, swapAvailable: 40),
            makeContainerStats(id: "ctr-b", cpu: 30, memory: 50, workingSet: 25, rss: 18, pageFaults: 7, majorPageFaults: 2, swap: 6, swapAvailable: 60),
        ])

        XCTAssertEqual(stats.attributes.id, "pod-test")
        XCTAssertEqual(stats.attributes.metadata.name, "demo")
        XCTAssertEqual(stats.attributes.metadata.namespace, "default")
        XCTAssertEqual(stats.attributes.labels["app"], "krust")
        XCTAssertEqual(stats.attributes.annotations["owner"], "tests")
        XCTAssertEqual(stats.linux.containers.map { $0.attributes.id }, ["ctr-a", "ctr-b"])
        XCTAssertEqual(stats.linux.cpu.usageCoreNanoSeconds.value, 40)
        XCTAssertEqual(stats.linux.memory.usageBytes.value, 70)
        XCTAssertEqual(stats.linux.memory.workingSetBytes.value, 40)
        XCTAssertEqual(stats.linux.memory.rssBytes.value, 30)
        XCTAssertEqual(stats.linux.memory.pageFaults.value, 10)
        XCTAssertEqual(stats.linux.memory.majorPageFaults.value, 3)
        XCTAssertEqual(stats.linux.containers[0].swap.swapUsageBytes.value, 4)
        XCTAssertEqual(stats.linux.containers[1].swap.swapAvailableBytes.value, 60)
    }

    func testPodSandboxStatsKeepsZeroUsageWhenSandboxHasNoContainers() {
        let stats = makeSandbox().toStats(containerStats: [])

        XCTAssertEqual(stats.attributes.id, "pod-test")
        XCTAssertTrue(stats.linux.containers.isEmpty)
        XCTAssertEqual(stats.linux.cpu.usageCoreNanoSeconds.value, 0)
        XCTAssertEqual(stats.linux.memory.usageBytes.value, 0)
    }

    func testPodSandboxStatsFilterMatchesSandboxFilterFields() {
        let sandbox = makeSandbox()

        XCTAssertTrue(Runtime_V1_PodSandboxStatsFilter.with {
            $0.id = "pod-test"
            $0.labelSelector = ["app": "krust"]
        }.matches(sandbox))

        XCTAssertFalse(Runtime_V1_PodSandboxStatsFilter.with {
            $0.id = "pod-other"
        }.matches(sandbox))

        XCTAssertFalse(Runtime_V1_PodSandboxStatsFilter.with {
            $0.labelSelector = ["app": "other"]
        }.matches(sandbox))
    }

    private func makeSandbox() -> SandboxRecord {
        SandboxRecord(
            id: "pod-test",
            name: "demo",
            namespace: "default",
            attempt: 0,
            uid: "uid-test",
            labels: ["app": "krust"],
            annotations: ["owner": "tests"],
            runtimeHandler: "",
            logDirectory: "/tmp/pods/demo",
            createdAt: 100,
            phase: .ready,
            ip: "10.88.0.2"
        )
    }

    private func makeContainerStats(
        id: String,
        cpu: UInt64,
        memory: UInt64,
        workingSet: UInt64,
        rss: UInt64,
        pageFaults: UInt64,
        majorPageFaults: UInt64,
        swap: UInt64,
        swapAvailable: UInt64
    ) -> Runtime_V1_ContainerStats {
        Runtime_V1_ContainerStats.with {
            $0.attributes = .with { $0.id = id }
            $0.cpu = .with {
                $0.timestamp = 10
                $0.usageCoreNanoSeconds = .with { $0.value = cpu }
            }
            $0.memory = .with {
                $0.timestamp = 10
                $0.usageBytes = .with { $0.value = memory }
                $0.workingSetBytes = .with { $0.value = workingSet }
                $0.rssBytes = .with { $0.value = rss }
                $0.pageFaults = .with { $0.value = pageFaults }
                $0.majorPageFaults = .with { $0.value = majorPageFaults }
            }
            $0.swap = .with {
                $0.timestamp = 10
                $0.swapUsageBytes = .with { $0.value = swap }
                $0.swapAvailableBytes = .with { $0.value = swapAvailable }
            }
        }
    }
}
