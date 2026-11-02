import ShazamKit
import XCTest
@testable import Cochlea

#if targetEnvironment(simulator)
@MainActor
final class TerminalReceiptUIFixtureTests: XCTestCase {
    func testPrepareTerminalReceiptOnExplicitDisposableSimulator() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["COCHLEA_TEST_TERMINAL_SIMULATOR"] != nil &&
                          environment["COCHLEA_TEST_TERMINAL_SIMULATOR"] == environment["SIMULATOR_UDID"],
                          "Requires an explicitly selected disposable simulator")
        let controller = try Runtime.controller.get()
        let store = controller.store
        try XCTSkipUnless(try store.records().isEmpty, "Use a fresh disposable simulator; never replace captures")
        let record = try store.capture(signature: SHSignatureGenerator().signature())
        try store.matched(record, metadata: MatchMetadata(title: "Terminal fixture song", artist: "Fixture artist"))
        let id = record.id.uuidString.lowercased()
        try store.deliveryFinished(record, status: 202,
                                   data: Data(#"{"ok":true,"capture_id":"\#(id)","status":"queued"}"#.utf8))
        try store.statusChecked(record, status: 200,
                                data: Data(#"{"capture_id":"\#(id)","status":"not_added","reason":"unavailable","retry_at":null}"#.utf8))
        controller.refresh()
        XCTAssertFalse(record.awaitsSpotify)
    }
}
#endif
