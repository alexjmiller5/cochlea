import XCTest
@testable import OfflineShazam

final class EnrollLinkTests: XCTestCase {
    func testEnrollLinkCarriesTheCaptureURLAndToken() throws {
        let link = URL(string: "offlineshazam://enroll?url=https%3A%2F%2Fws--capture-consumer.modal.run&token=abc_DEF-123")!
        let configuration = try XCTUnwrap(try DeliveryConfiguration.fromEnrollLink(link))
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://ws--capture-consumer.modal.run")
        XCTAssertEqual(configuration.token, "abc_DEF-123")
    }

    func testOtherLinksAreNotEnrollment() throws {
        XCTAssertNil(try DeliveryConfiguration.fromEnrollLink(URL(string: "offlineshazam://capture")!))
        XCTAssertNil(try DeliveryConfiguration.fromEnrollLink(URL(string: "https://example.com/enroll?url=x&token=y")!))
    }

    func testIncompleteOrUnsafeEnrollLinksAreRefused() {
        for query in ["url=https%3A%2F%2Fws.modal.run", "url=http%3A%2F%2Fws.modal.run&token=abc", "token=abc",
                      "url=https%3A%2F%2Fws.modal.run&token=a%20b"] {
            XCTAssertThrowsError(try DeliveryConfiguration.fromEnrollLink(URL(string: "offlineshazam://enroll?\(query)")!), query)
        }
    }
}
