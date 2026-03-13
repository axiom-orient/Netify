import XCTest
@testable import Netify

@available(iOS 15, macOS 12, *)
extension XCTestCase {
    func extractErrorKind(from error: Error, file: StaticString = #filePath, line: UInt = #line) -> NetworkRequestError {
        if let netifyError = error as? NetifyError {
            return netifyError.kind
        }
        if let requestError = error as? NetworkRequestError {
            return requestError
        }

        XCTFail("Expected NetifyError or NetworkRequestError, got \(error)", file: file, line: line)
        return .unknownError(underlyingError: error)
    }

    func requireLiveTests() throws {
        if ProcessInfo.processInfo.environment["NETIFY_RUN_LIVE_TESTS"] != "1" {
            throw XCTSkip("Set NETIFY_RUN_LIVE_TESTS=1 to run live integration tests.")
        }
    }
}

struct PlaceholderPost: Codable, Equatable, Identifiable {
    let userId: Int
    let id: Int
    let title: String
    let body: String
}

struct PlaceholderPostInput: Codable, Equatable {
    let userId: Int
    let title: String
    let body: String
}
