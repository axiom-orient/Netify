import XCTest
@testable import Netify

@available(iOS 15, macOS 12, *)
final class NetifyIntegrationTests: XCTestCase {
    private let integrationBaseURL = "https://jsonplaceholder.typicode.com"

    private func makeRealNetifyClient() -> NetifyClient {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let config = NetifyConfiguration(
            baseURL: integrationBaseURL,
            defaultEncoder: encoder,
            defaultDecoder: decoder,
            logLevel: .debug,
            maxRetryCount: 1,
            timeoutInterval: 30.0,
            waitsForConnectivity: false
        )
        return NetifyClient(configuration: config)
    }

    func testIntegration_fetchSinglePost_Success() async throws {
        try requireLiveTests()
        let client = makeRealNetifyClient()

        let request = Netify.get(expecting: PlaceholderPost.self)
            .path("/posts/{id}")
            .pathArgument("id", 1)
            .authentication(required: false)

        let post = try await client.send(request)
        XCTAssertEqual(post.id, 1)
        XCTAssertEqual(post.userId, 1)
        XCTAssertEqual(post.title, "sunt aut facere repellat provident occaecati excepturi optio reprehenderit")
        XCTAssertFalse(post.body.isEmpty)
    }

    func testIntegration_fetchAllPosts_Success() async throws {
        try requireLiveTests()
        let client = makeRealNetifyClient()

        let request = Netify.get(expecting: [PlaceholderPost].self)
            .path("/posts")
            .authentication(required: false)

        let posts = try await client.send(request)
        XCTAssertFalse(posts.isEmpty)
        XCTAssertEqual(posts.count, 100)
        XCTAssertEqual(posts.first?.id, 1)
    }

    func testIntegration_createPost_Success() async throws {
        try requireLiveTests()
        let client = makeRealNetifyClient()
        let newPostInput = PlaceholderPostInput(
            userId: 5,
            title: "Netify Declarative Integration Test",
            body: "This post was created via declarative API."
        )

        let request = Netify.post(expecting: PlaceholderPost.self)
            .path("/posts")
            .body(newPostInput)
            .authentication(required: false)

        let createdPost = try await client.send(request)
        XCTAssertNotNil(createdPost.id)
        XCTAssertGreaterThanOrEqual(createdPost.id, 101)
        XCTAssertEqual(createdPost.title, newPostInput.title)
        XCTAssertEqual(createdPost.body, newPostInput.body)
        XCTAssertEqual(createdPost.userId, newPostInput.userId)
    }

    func testIntegration_HttpBin_Returns404Error() async throws {
        try requireLiveTests()
        let httpBinClient = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: "https://httpbin.org",
                logLevel: .debug,
                maxRetryCount: 0
            )
        )

        let request = Netify.get(expecting: Data.self)
            .path("/status/{code}")
            .pathArgument("code", 404)
            .authentication(required: false)

        do {
            _ = try await httpBinClient.send(request)
            XCTFail("Request to HTTPBin /status/404 should have failed.")
        } catch {
            let errorKind = extractErrorKind(from: error)
            if case .notFound(let data) = errorKind {
                XCTAssertNotNil(data, "Data from HTTPBin 404 should not be nil.")
            } else {
                XCTFail("Expected .notFound from HTTPBin, got \(errorKind)")
            }
        }
    }
}
