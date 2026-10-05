import XCTest
@testable import Cochlea

final class EnrollLinkTests: XCTestCase {
    func testEnrollLinkCarriesTheCaptureURLAndToken() throws {
        let link = URL(string: "offlineshazam://enroll?url=https%3A%2F%2Fws--capture-consumer.modal.run&token=abc_DEF-123")!
        let configuration = try XCTUnwrap(try DeliveryConfiguration.fromEnrollLink(link))
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://ws--capture-consumer.modal.run")
        XCTAssertEqual(configuration.token, "abc_DEF-123")
    }

    func testCochleaEnrollmentLinkUsesTheSameConsumerContract() throws {
        let link = URL(string: "cochlea://enroll?url=https%3A%2F%2Fexample.com%2Fcapture&token=example-token")!
        let configuration = try XCTUnwrap(try DeliveryConfiguration.fromEnrollLink(link))
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://example.com/capture")
        XCTAssertEqual(configuration.token, "example-token")
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

final class ConnectionStoreTests: XCTestCase {
    func testDeleteForgetsTheSavedConnection() throws {
        let store = ConnectionStore(service: "cochlea.tests.\(UUID().uuidString)")
        try store.save(DeliveryConfiguration(endpoint: "https://ws--capture-consumer.modal.run", token: "tok"))
        XCTAssertEqual(try store.load()?.token, "tok")
        try store.delete()
        XCTAssertNil(try store.load())
        try store.delete()  // deleting nothing is fine
    }
}
