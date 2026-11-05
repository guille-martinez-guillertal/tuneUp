import XCTest
@testable import TuneUpCore

final class TuneUpCoreTests: XCTestCase {
    func testFailedSecurityCheckNeverPasses() {
        let result = Analyzer.findings([Observation(id: "sip", output: "enabled", exitCode: 1)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.severity, .unknown)
    }
    func testTimeoutIsUnknownEvenWithSuccessfulLookingOutput() {
        let result = Analyzer.findings([Observation(id: "updates", output: "No new software available.", timedOut: true)])
        XCTAssertEqual(result.first?.severity, .unknown)
    }
    func testNoUpdatesDoesNotMeanSupported() {
        let result = Analyzer.findings([Observation(id: "updates", output: "No new software available.")])
        XCTAssertEqual(result.first?.severity, .review)
        XCTAssertTrue(result.first!.detail.contains("does not establish"))
    }
    func testFirewallStates() {
        XCTAssertEqual(Analyzer.findings([Observation(id: "firewall", output: "Firewall is disabled. (State = 0)")]).first?.severity, .attention)
        XCTAssertEqual(Analyzer.findings([Observation(id: "firewall", output: "Firewall is enabled. (State = 1)")]).first?.severity, .info)
    }
    func testStorageUsesAvailableColumn() {
        let result = Analyzer.findings([Observation(id: "space", output: "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk1 100000000 95000000 5000000 95% /System/Volumes/Data")])
        XCTAssertEqual(result.first?.severity, .attention)
    }
    func testRecognizesPortalCrashWithoutBlamingOffice() {
        let result = Analyzer.findings([Observation(id: "crashes", output: "Microsoft.ips\n /Applications/Company Portal.app/Contents/test Symbol missing")])
        XCTAssertTrue(result.contains { $0.id == "portal" && $0.severity == .attention })
    }
    func testRedaction() {
        let input = "/Users/alice/Documents Serial Number (system): SECRET123\nHardware UUID: PRIVATE\n192.168.1.1 aa:bb:cc:dd:ee:ff alice@example.org 2a0c:5a85:7007:e700:105e:f071:a05d:670"
        let output = Redactor.scrub(input)
        for secret in ["alice", "SECRET123", "PRIVATE", "192.168.1.1", "aa:bb:cc:dd:ee:ff", "2a0c:5a85"] {
            XCTAssertFalse(output.contains(secret), "Failed to redact \(secret)")
        }
    }
    func testSummaryExportOmitsRawEvidence() {
        var report = Report()
        report.observations = [Observation(id: "cpu", output: "PRIVATE_RAW_OUTPUT")]
        XCTAssertFalse(report.markdown(includeEvidence: false).contains("PRIVATE_RAW_OUTPUT"))
        XCTAssertTrue(report.markdown(includeEvidence: true).contains("PRIVATE_RAW_OUTPUT"))
    }
    func testBaselineRoundTrip() throws {
        var report = Report(); report.completed = true
        report.observations = [Observation(id: "cpu", output: "sample")]
        let restored = try JSONDecoder().decode(Report.self, from: JSONEncoder().encode(report))
        XCTAssertTrue(restored.completed)
        XCTAssertEqual(restored.observations.first?.output, "sample")
    }
    func testRunnerCapturesFailureAndStderr() {
        let item = Runner.run(Probe("test", "Test", "Failure", "/bin/sh", ["-c", "echo diagnostic >&2; exit 7"]))
        XCTAssertEqual(item.exitCode, 7)
        XCTAssertTrue(item.output.contains("diagnostic"))
        XCTAssertFalse(item.succeeded)
    }
    func testRunnerTimesOut() {
        let item = Runner.run(Probe("test", "Test", "Timeout", "/bin/sleep", ["10"], timeout: 0.2))
        XCTAssertTrue(item.timedOut)
        XCTAssertFalse(item.succeeded)
    }
    func testOfflineCatalogNeverContactsUpdateOrConnectivityServices() {
        let probes = Catalog.probes(online: false)
        XCTAssertFalse(probes.contains { ["updates", "https", "lookup"].contains($0.id) })
        XCTAssertTrue(Catalog.probes(online: true).contains { $0.id == "updates" })
        XCTAssertEqual(Set(probes.map(\.id)).count, probes.count)
    }
}
