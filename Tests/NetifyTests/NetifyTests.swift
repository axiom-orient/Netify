import XCTest
@testable import Netify // 실제 프로젝트 모듈 이름으로 변경하세요.

// MARK: - Main Test Class
@available(iOS 15, macOS 12, *)
final class NetifyTests: XCTestCase {
    
    // MARK: Properties
    var mockNetworkSession: MockNetworkSession!
    var mockNetifyClient: NetifyClient!
    let mockBaseURL = "https://mock.api.example.com"
    
    // MARK: Test Lifecycle
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Mock Test Setup
        mockNetworkSession = MockNetworkSession()
        let sharedEncoder = JSONEncoder()
        sharedEncoder.dateEncodingStrategy = .iso8601
        sharedEncoder.outputFormatting = .sortedKeys // 요청 본문 비교 일관성 확보
        
        let sharedDecoder = JSONDecoder()
        sharedDecoder.dateDecodingStrategy = .iso8601
        
        let mockConfig = NetifyConfiguration(
            baseURL: mockBaseURL,
            sessionConfiguration: .ephemeral, // 테스트 시 네트워크 캐시 등 방지
            defaultEncoder: sharedEncoder,
            defaultDecoder: sharedDecoder,
            logLevel: .debug // 테스트 중 상세 로그 확인 (필요시 .off 또는 .error로 변경)
        )
        mockNetifyClient = NetifyClient(configuration: mockConfig, networkSession: mockNetworkSession)
    }
    
    override func tearDownWithError() throws {
        mockNetworkSession = nil
        mockNetifyClient = nil
        try super.tearDownWithError()
    }

    // MARK: - Mock Based Unit Tests (NetifyRequest Protocol Based)
    
    /**
     * @Intent: 프로토콜 기반 GET 요청이 성공적으로 처리되고 응답이 디코딩되는지 검증합니다.
     * @Given: `MockUser` 데이터와 200 OK 응답이 `MockNetworkSession`에 설정됩니다. `GetMockUserRequest`가 준비됩니다.
     * @When: `mockNetifyClient.send()`로 요청을 전송합니다.
     * @Then: 반환된 `MockUser`가 예상과 같고, 요청 URL과 메소드가 올바른지 확인합니다.
     */
    func testMock_SuccessfulGETRequest_ProtocolBased() async throws {
        // Given
        let expectedUser = MockUser(id: 1, name: "John Doe")
        let mockData = try JSONEncoder().encode(expectedUser)
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/users/1"))
        let mockResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        
        mockNetworkSession.mockData = mockData
        mockNetworkSession.mockResponse = mockResponse
        
        let request = GetMockUserRequest(userId: 1)
        
        // When
        let user: MockUser = try await mockNetifyClient.send(request)
        
        // Then
        XCTAssertEqual(user, expectedUser)
        XCTAssertEqual(mockNetworkSession.lastRequest?.url?.absoluteString, "\(mockBaseURL)/users/1")
        XCTAssertEqual(mockNetworkSession.lastRequest?.httpMethod, "GET")
    }
    
    /**
     * @Intent: 프로토콜 기반 POST 요청의 본문 인코딩 및 응답 디코딩을 검증합니다.
     * @Given: `MockUserResponse` 데이터와 201 Created 응답이 `MockNetworkSession`에 설정됩니다. `CreateMockUserRequest`가 준비됩니다.
     * @When: `mockNetifyClient.send()`로 요청을 전송합니다.
     * @Then: 반환된 응답이 예상과 같고, 요청 URL, 메소드, 본문, Content-Type이 올바른지 확인합니다.
     */
    func testMock_SuccessfulPOSTRequest_ProtocolBased() async throws {
        // Given
        let inputUserPayload = MockUserInput(name: "Jane Doe", job: "Developer")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        
        let now = Date()
        let expectedResponseUser = MockUserResponse(id: "123", name: "Jane Doe", job: "Developer", createdAt: now)
        let mockResponseData = try encoder.encode(expectedResponseUser)
        
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/users"))
        let mockResponse = HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        
        mockNetworkSession.mockData = mockResponseData
        mockNetworkSession.mockResponse = mockResponse
        
        let request = CreateMockUserRequest(userInput: inputUserPayload)
        
        // When
        let createdUserResponse: MockUserResponse = try await mockNetifyClient.send(request)
        
        // Then
        XCTAssertEqual(createdUserResponse.name, expectedResponseUser.name)
        XCTAssertEqual(createdUserResponse.job, expectedResponseUser.job)
        XCTAssertNotNil(createdUserResponse.id)
        XCTAssertEqual(createdUserResponse.createdAt.timeIntervalSince1970, expectedResponseUser.createdAt.timeIntervalSince1970, accuracy: 1.0)
        
        XCTAssertEqual(mockNetworkSession.lastRequest?.url?.absoluteString, "\(mockBaseURL)/users")
        XCTAssertEqual(mockNetworkSession.lastRequest?.httpMethod, "POST")
        
        guard let actualBodyData = mockNetworkSession.lastRequest?.httpBody else {
            XCTFail("Actual request body data is nil"); return
        }
        let actualInputPayload = try mockNetifyClient.configuration.defaultDecoder.decode(MockUserInput.self, from: actualBodyData)
        XCTAssertEqual(actualInputPayload, inputUserPayload, "Decoded request body mismatch")
        
        XCTAssertEqual(mockNetworkSession.lastRequest?.value(forHTTPHeaderField: "Content-Type"), HTTPContentType.json.rawValue)
    }
    
    // MARK: - Mock Based Error Handling Tests (Protocol Based)

    func testMock_ClientError_404_NotFound() async throws {
        // Given
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/items/999"))
        let mockErrorResponse = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let errorJSONData = #"{"error": "Item not found"}"#.data(using: .utf8)
        mockNetworkSession.mockResponse = mockErrorResponse
        mockNetworkSession.mockData = errorJSONData
        let request = GetMockItemRequest(itemId: 999)

        // When/Then
        do {
            _ = try await mockNetifyClient.send(request)
            XCTFail("Expected NetworkRequestError.notFound")
        } catch {
            let errorKind = extractErrorKind(from: error)
            if case .notFound(let data) = errorKind { XCTAssertEqual(data, errorJSONData) } else { XCTFail("Expected .notFound, got \(errorKind)") }
        }
    }

    func testMock_ClientError_400_BadRequest() async throws {
        // Given
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/users"))
        let mockErrorResponse = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let errorJSONData = #"{"error": "Invalid input"}"#.data(using: .utf8)
        mockNetworkSession.mockResponse = mockErrorResponse
        mockNetworkSession.mockData = errorJSONData
        let request = CreateMockUserRequest(userInput: MockUserInput(name: "", job: "Test"))

        // When/Then
        do {
            _ = try await mockNetifyClient.send(request)
            XCTFail("Expected NetworkRequestError.badRequest")
        } catch {
            let errorKind = extractErrorKind(from: error)
            if case .badRequest(let data) = errorKind { XCTAssertEqual(data, errorJSONData) } else { XCTFail("Expected .badRequest, got \(errorKind)") }
        }
    }
    
    func testMock_ServerError_500() async throws {
        // Given
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/status/500"))
        let mockErrorResponse = HTTPURLResponse(url: url, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
        let errorJSONData = #"{"error": "Server issue"}"#.data(using: .utf8)
        mockNetworkSession.mockResponse = mockErrorResponse
        mockNetworkSession.mockData = errorJSONData
        let request = GetMockStatusRequest(code: 500)

        // When/Then
        do {
            _ = try await mockNetifyClient.send(request)
            XCTFail("Expected NetworkRequestError.serverError")
        } catch {
            let errorKind = extractErrorKind(from: error)
            if case .serverError(let statusCode, let data, _) = errorKind {
                XCTAssertEqual(statusCode, 500)
                XCTAssertEqual(data, errorJSONData)
            } else { XCTFail("Expected .serverError, got \(errorKind)") }
        }
    }

    func testMock_DecodingError() async throws {
        // Given
        let malformedJSONData = #"{"id":1,"name":"Test" corrupted}"#.data(using: .utf8)! // Corrupted JSON
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/users/1"))
        let mockOKResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        mockNetworkSession.mockData = malformedJSONData
        mockNetworkSession.mockResponse = mockOKResponse
        let request = GetMockUserRequest(userId: 1)

        // When/Then
        do {
            _ = try await mockNetifyClient.send(request)
            XCTFail("Expected NetworkRequestError.decodingError")
        } catch {
            let errorKind = extractErrorKind(from: error)
            if case .decodingError(let underlyingError, let data) = errorKind {
                XCTAssert(underlyingError is Swift.DecodingError)
                XCTAssertEqual(data, malformedJSONData)
            } else { XCTFail("Expected .decodingError, got \(errorKind)") }
        }
    }

    func testMock_EmptyResponseSuccess() async throws {
        // Given
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/items/5"))
        let mockNoContentResponse = HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
        mockNetworkSession.mockResponse = mockNoContentResponse
        mockNetworkSession.mockData = Data() // Empty data for 204
        let request = DeleteMockItemRequest(itemId: 5)

        // When
        let result: EmptyResponse = try await mockNetifyClient.send(request)
        
        // Then
        XCTAssertNotNil(result) // Successfully received and mapped to EmptyResponse
    }

    func testMock_EmptyResponseForNonEmptyType_DecodingError() async throws {
        // Given
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/users/1"))
        let mockOKEmptyDataResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        mockNetworkSession.mockResponse = mockOKEmptyDataResponse
        mockNetworkSession.mockData = Data() // Empty data
        let request = GetMockUserRequest(userId: 1) // Expects MockUser

        // When/Then
        do {
            _ = try await mockNetifyClient.send(request)
            XCTFail("Expected NetworkRequestError.decodingError for empty data with non-EmptyResponse type")
        } catch {
            let errorKind = extractErrorKind(from: error)
            if case .decodingError(let underlyingError, let data) = errorKind {
                XCTAssertEqual(data, Data())
                XCTAssert(underlyingError.localizedDescription.contains("타입을 기대했으나 빈 응답 본문을 받았습니다"), "Error message mismatch: \(underlyingError.localizedDescription)")
            } else { XCTFail("Expected .decodingError, got \(errorKind)") }
        }
    }
    
    func testMock_NetworkError_NotConnected() async throws {
        // Given
        mockNetworkSession.simulateError = URLError(.notConnectedToInternet)
        let request = GetMockUserRequest(userId: 1)

        // When/Then
        do {
            _ = try await mockNetifyClient.send(request)
            XCTFail("Expected NetworkRequestError.noInternetConnection")
        } catch {
            let errorKind = extractErrorKind(from: error)
            guard case .noInternetConnection = errorKind else { XCTFail("Expected .noInternetConnection, got \(errorKind)"); return }
        }
    }

    func testMock_NetworkError_Timeout() async throws {
        // Given
        mockNetworkSession.simulateError = URLError(.timedOut)
        let request = GetMockUserRequest(userId: 1)

        // When/Then
        do {
            _ = try await mockNetifyClient.send(request)
            XCTFail("Expected NetworkRequestError.timedOut")
        } catch {
            let errorKind = extractErrorKind(from: error)
            guard case .timedOut = errorKind else { XCTFail("Expected .timedOut, got \(errorKind)"); return }
        }
    }

    func testMock_NetworkError_BadURL() async throws {
        // Given
        mockNetworkSession.simulateError = URLError(.badURL)
        let request = GetMockUserRequest(userId: 1)

        // When/Then
        do {
            _ = try await mockNetifyClient.send(request)
            XCTFail("Expected NetworkRequestError.urlSessionFailed")
        } catch {
            let errorKind = extractErrorKind(from: error)
            if case .urlSessionFailed(let underlyingError) = errorKind {
                XCTAssertEqual((underlyingError as? URLError)?.code, .badURL)
            } else { XCTFail("Expected .urlSessionFailed with URLError.badURL, got \(errorKind)")}
        }
    }
    
    // MARK: - Mock Based Unit Tests (NEW: Declarative API)
    
    /**
     * @Intent: 선언적 API GET 요청(경로 인자, 쿼리 파라미터, 헤더 포함)의 성공 및 응답 디코딩을 검증합니다.
     * @Given: `MockUser` 데이터와 200 OK 응답이 `MockNetworkSession`에 설정됩니다. 선언적 API로 요청이 구성됩니다.
     * @When: `mockNetifyClient.send()`로 선언적 요청을 전송합니다.
     * @Then: 반환된 `MockUser`가 예상과 같고, 요청 URL, 메소드, 헤더가 올바른지 확인합니다.
     */
    func testMock_Declarative_SuccessfulGETRequest_WithParamsAndHeaders() async throws {
        // Given
        let expectedUser = MockUser(id: 7, name: "Declarative User")
        let mockData = try JSONEncoder().encode(expectedUser)
        // URL 구성 시 쿼리 파라미터 순서는 중요하지 않으므로, 검증 시 Set으로 비교
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/declarative/users/7?type=active&role=admin"))
        let mockResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!

        mockNetworkSession.mockData = mockData
        mockNetworkSession.mockResponse = mockResponse

        let declarativeRequest = Netify.get(expecting: MockUser.self)
            .path("/declarative/users/{userID}")
            .pathArgument("userID", 7)
            .queryParam("type", "active")
            .queryParam("role", "admin") // 쿼리 파라미터 순서 변경하여 테스트 가능
            .header("X-Custom-ID", "declarative-test-001")
            .authentication(required: false)

        // When
        let user: MockUser = try await mockNetifyClient.send(declarativeRequest)

        // Then
        XCTAssertEqual(user, expectedUser, "Decoded user mismatch")
        
        let lastRequest = try XCTUnwrap(mockNetworkSession.lastRequest)
        let lastURL = try XCTUnwrap(lastRequest.url)
        
        XCTAssertEqual(lastURL.path, "/declarative/users/7", "Request path mismatch")
        
        let expectedQueryItems = Set([URLQueryItem(name: "type", value: "active"), URLQueryItem(name: "role", value: "admin")])
        let actualQueryItems = Set(URLComponents(url: lastURL, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        XCTAssertEqual(actualQueryItems, expectedQueryItems, "Query parameters mismatch")
        
        XCTAssertEqual(lastRequest.httpMethod, "GET", "HTTP method mismatch")
        XCTAssertEqual(lastRequest.value(forHTTPHeaderField: "X-Custom-ID"), "declarative-test-001", "Custom header mismatch")
    }

    /**
     * @Intent: 선언적 API POST 요청(JSON 본문)의 성공, 요청 본문 인코딩, Content-Type 설정, 응답 디코딩을 검증합니다.
     * @Given: `MockUserResponse` 데이터와 201 Created 응답이 `MockNetworkSession`에 설정됩니다. 선언적 API로 POST 요청이 구성됩니다.
     * @When: `mockNetifyClient.send()`로 선언적 요청을 전송합니다.
     * @Then: 반환된 응답이 예상과 같고, 요청 URL, 메소드, 본문(디코딩 후 비교), Content-Type 헤더가 올바른지 확인합니다.
     */
    func testMock_Declarative_SuccessfulPOSTRequest_WithJSONBody() async throws {
        // Given
        let inputUserPayload = MockUserInput(name: "Declarative POST", job: "Architect")
        let now = Date()
        let expectedResponseUser = MockUserResponse(id: "789", name: inputUserPayload.name, job: inputUserPayload.job, createdAt: now)
        
        let mockResponseData = try mockNetifyClient.configuration.defaultEncoder.encode(expectedResponseUser)
        
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/declarative/users"))
        let mockResponse = HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!

        mockNetworkSession.mockData = mockResponseData
        mockNetworkSession.mockResponse = mockResponse

        let declarativeRequest = Netify.post(expecting: MockUserResponse.self)
            .path("/declarative/users")
            .body(inputUserPayload) // .json contentType 자동 설정 기대
            .header("X-Action", "CreateUser-Declarative")

        // When
        let createdUserResponse: MockUserResponse = try await mockNetifyClient.send(declarativeRequest)

        // Then
        XCTAssertEqual(createdUserResponse.name, expectedResponseUser.name)
        XCTAssertEqual(createdUserResponse.job, expectedResponseUser.job)
        XCTAssertEqual(createdUserResponse.id, expectedResponseUser.id)
        XCTAssertEqual(createdUserResponse.createdAt.timeIntervalSince1970, expectedResponseUser.createdAt.timeIntervalSince1970, accuracy: 1.0)

        let lastRequest = try XCTUnwrap(mockNetworkSession.lastRequest)
        XCTAssertEqual(lastRequest.url?.absoluteString, "\(mockBaseURL)/declarative/users")
        XCTAssertEqual(lastRequest.httpMethod, "POST")
        
        guard let actualBodyData = lastRequest.httpBody else {
            XCTFail("Actual request body data is nil"); return
        }
        let actualInputPayload = try mockNetifyClient.configuration.defaultDecoder.decode(MockUserInput.self, from: actualBodyData)
        XCTAssertEqual(actualInputPayload, inputUserPayload, "Decoded request body mismatch")
        
        XCTAssertEqual(lastRequest.value(forHTTPHeaderField: HTTPHeaderField.contentType.rawValue), HTTPContentType.json.rawValue)
        XCTAssertEqual(lastRequest.value(forHTTPHeaderField: "X-Action"), "CreateUser-Declarative")
    }

    /**
     * @Intent: 선언적 API 멀티파트 POST 요청의 성공 및 Content-Type, 본문 구성을 검증합니다.
     * @Given: `EmptyResponse`와 200 OK 응답이 `MockNetworkSession`에 설정됩니다. 선언적 API로 멀티파트 요청이 구성됩니다.
     * @When: `mockNetifyClient.send()`로 선언적 요청을 전송합니다.
     * @Then: 요청이 성공하고, Content-Type이 멀티파트 형식(boundary 포함)이며, 본문에 파트 데이터가 포함되었는지 확인합니다.
     */
    func testMock_Declarative_SuccessfulPOSTRequest_WithMultipartBody() async throws {
        // Given
        let textData = "Netify Declarative Multipart Test".data(using: .utf8)!
        let fileDataContent = "Fake image content".data(using: .utf8)!

        let multipartParts = [
            MultipartData(name: "description", fileData: textData, fileName: "", mimeType: "text/plain"),
            MultipartData(name: "image_file", fileData: fileDataContent, fileName: "photo.png", mimeType: "image/png")
        ]
        
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/declarative/upload_multipart"))
        let mockResponseData = Data() // EmptyResponse를 기대하므로 빈 데이터
        let mockResponse = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!

        mockNetworkSession.mockData = mockResponseData
        mockNetworkSession.mockResponse = mockResponse

        let declarativeRequest = Netify.post(expecting: EmptyResponse.self)
            .path("/declarative/upload_multipart")
            .multipart(multipartParts)

        // When
        _ = try await mockNetifyClient.send(declarativeRequest)

        // Then
        let lastRequest = try XCTUnwrap(mockNetworkSession.lastRequest)
        XCTAssertEqual(lastRequest.url?.absoluteString, "\(mockBaseURL)/declarative/upload_multipart")
        XCTAssertEqual(lastRequest.httpMethod, "POST")

        let contentTypeHeader = try XCTUnwrap(lastRequest.value(forHTTPHeaderField: HTTPHeaderField.contentType.rawValue))
        XCTAssertTrue(contentTypeHeader.hasPrefix(HTTPContentType.multipart.rawValue))
        XCTAssertTrue(contentTypeHeader.contains("boundary="))

        let actualBodyData = try XCTUnwrap(lastRequest.httpBody)
        XCTAssertFalse(actualBodyData.isEmpty)
        
        let bodyString = String(data: actualBodyData, encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("name=\"description\""))
        XCTAssertTrue(bodyString.contains(String(data: textData, encoding: .utf8)!))
        XCTAssertTrue(bodyString.contains("name=\"image_file\""))
        XCTAssertTrue(bodyString.contains("filename=\"photo.png\""))
        XCTAssertTrue(bodyString.contains("Content-Type: image/png"))
        XCTAssertTrue(bodyString.contains(String(data: fileDataContent, encoding: .utf8)!))
    }

    func testMock_Declarative_PathArguments_ShouldPercentEncodeReservedCharacters() async throws {
        let expectedUser = MockUser(id: 9, name: "Reserved Path")
        mockNetworkSession.mockData = try JSONEncoder().encode(expectedUser)
        mockNetworkSession.mockResponse = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "\(mockBaseURL)/files/folder%2Fname%20with%20space")),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )

        let request = Netify.get(expecting: MockUser.self)
            .path("/files/{path}")
            .pathArgument("path", "folder/name with space")
            .authentication(required: false)

        _ = try await mockNetifyClient.send(request)

        let finalPath = try XCTUnwrap(mockNetworkSession.lastRequest?.url?.path)
        XCTAssertEqual(finalPath, "/files/folder%2Fname%20with%20space")
    }

    func testMock_DataResponse_ReturnsRawDataWithoutJSONDecoding() async throws {
        let rawData = Data([0x00, 0x01, 0x02, 0x03])
        mockNetworkSession.mockData = rawData
        mockNetworkSession.mockResponse = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "\(mockBaseURL)/binary/1")),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        )

        let request = Netify.get(expecting: Data.self)
            .path("/binary/{id}")
            .pathArgument("id", 1)
            .authentication(required: false)

        let result = try await mockNetifyClient.send(request)
        XCTAssertEqual(result, rawData)
    }

    func testMock_Retry_DefaultGETTimeout_RetriesOnce() async throws {
        let expectedUser = MockUser(id: 21, name: "Retry Success")
        mockNetworkSession.queuedErrors = [URLError(.timedOut)]
        mockNetworkSession.queuedResults = [
            (
                try JSONEncoder().encode(expectedUser),
                HTTPURLResponse(
                    url: try XCTUnwrap(URL(string: "\(mockBaseURL)/users/21")),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        ]

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off
            ),
            networkSession: mockNetworkSession
        )

        let user = try await client.send(GetMockUserRequest(userId: 21))
        XCTAssertEqual(user, expectedUser)
        XCTAssertEqual(mockNetworkSession.requestCount, 2)
    }

    func testMock_Retry_DefaultPostTimeout_DoesNotRetry() async throws {
        mockNetworkSession.simulateError = URLError(.timedOut)

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off
            ),
            networkSession: mockNetworkSession
        )

        do {
            _ = try await client.send(CreateMockUserRequest(userInput: .init(name: "No Retry", job: "Writer")))
            XCTFail("Expected timeout")
        } catch {
            let errorKind = extractErrorKind(from: error)
            guard case .timedOut = errorKind else {
                return XCTFail("Expected .timedOut, got \(errorKind)")
            }
        }

        XCTAssertEqual(mockNetworkSession.requestCount, 1)
    }

    func testMock_Retry_DefaultGET503_RetriesOnce() async throws {
        let expectedUser = MockUser(id: 22, name: "Recovered")
        let userURL = try XCTUnwrap(URL(string: "\(mockBaseURL)/users/22"))
        mockNetworkSession.queuedResults = [
            (
                Data(),
                HTTPURLResponse(
                    url: userURL,
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            ),
            (
                try JSONEncoder().encode(expectedUser),
                HTTPURLResponse(
                    url: userURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            )
        ]

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off
            ),
            networkSession: mockNetworkSession
        )

        let user = try await client.send(GetMockUserRequest(userId: 22))
        XCTAssertEqual(user, expectedUser)
        XCTAssertEqual(mockNetworkSession.requestCount, 2)
    }

    func testMock_Retry_DefaultPost503_DoesNotRetry() async throws {
        let userURL = try XCTUnwrap(URL(string: "\(mockBaseURL)/users"))
        mockNetworkSession.mockResponse = HTTPURLResponse(
            url: userURL,
            statusCode: 503,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )
        mockNetworkSession.mockData = Data()

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off
            ),
            networkSession: mockNetworkSession
        )

        do {
            _ = try await client.send(CreateMockUserRequest(userInput: .init(name: "Unsafe Retry", job: "Tester")))
            XCTFail("Expected server error")
        } catch {
            let errorKind = extractErrorKind(from: error)
            guard case .serverError(let statusCode, _, _) = errorKind else {
                return XCTFail("Expected .serverError, got \(errorKind)")
            }
            XCTAssertEqual(statusCode, 503)
        }

        XCTAssertEqual(mockNetworkSession.requestCount, 1)
    }

    func testMock_AuthRefresh_ShouldDetectWrappedUnauthorizedError() async throws {
        let counter = RefreshCounter()
        let protectedURL = try XCTUnwrap(URL(string: "\(mockBaseURL)/protected"))
        mockNetworkSession.queuedResults = [
            (
                Data("{}".utf8),
                HTTPURLResponse(
                    url: protectedURL,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            ),
            (
                Data(),
                HTTPURLResponse(
                    url: protectedURL,
                    statusCode: 204,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        ]

        let auth = BearerTokenAuthenticationProvider(
            accessToken: "expired-token",
            refreshToken: "refresh-token",
            refreshHandler: { _ in
                await counter.increment()
                return .init(accessToken: "fresh-token")
            }
        )

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off,
                authenticationProvider: auth
            ),
            networkSession: mockNetworkSession
        )

        do {
            _ = try await client.send(ProtectedEmptyRequest())
        } catch {
            XCTFail("Expected refresh recovery to succeed, got \(extractErrorKind(from: error))")
        }

        let refreshCount = await counter.value()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(mockNetworkSession.requestCount, 2)
    }

    func testMock_AuthRefresh_ShouldOnlyRunOncePerRequest() async throws {
        let counter = RefreshCounter()
        let protectedURL = try XCTUnwrap(URL(string: "\(mockBaseURL)/protected"))
        mockNetworkSession.queuedResults = [
            (
                Data("{}".utf8),
                HTTPURLResponse(
                    url: protectedURL,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            ),
            (
                Data("{}".utf8),
                HTTPURLResponse(
                    url: protectedURL,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!
            ),
            (
                Data(),
                HTTPURLResponse(
                    url: protectedURL,
                    statusCode: 204,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        ]

        let auth = BearerTokenAuthenticationProvider(
            accessToken: "expired-token",
            refreshToken: "refresh-token",
            refreshHandler: { _ in
                await counter.increment()
                return .init(accessToken: "fresh-token")
            }
        )

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off,
                authenticationProvider: auth
            ),
            networkSession: mockNetworkSession
        )

        do {
            _ = try await client.send(ProtectedEmptyRequest())
            XCTFail("Expected unauthorized after the single refresh budget was exhausted")
        } catch {
            let errorKind = extractErrorKind(from: error)
            guard case .unauthorized = errorKind else {
                return XCTFail("Expected .unauthorized, got \(errorKind)")
            }
        }

        let refreshCount = await counter.value()
        XCTAssertEqual(refreshCount, 1)
    }

    func testMock_ResponseCache_ShouldServeCachedGETBeforeNetwork() async throws {
        let cachedUser = MockUser(id: 77, name: "Cached User")
        let cachedData = try JSONEncoder().encode(cachedUser)
        let cachedURL = try XCTUnwrap(URL(string: "\(mockBaseURL)/users/77"))
        let cachedResponse = CachedResponse(
            data: cachedData,
            response: HTTPURLResponse(
                url: cachedURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json", "ETag": "etag-1"]
            )!,
            etag: "etag-1",
            maxAge: 300
        )

        let cache = InMemoryResponseCache()
        await cache.setCachedResponse(cachedResponse, for: "\(mockBaseURL)/users/77")

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off,
                responseCache: cache,
                varyIndex: VaryIndex()
            ),
            networkSession: mockNetworkSession
        )

        do {
            let user = try await client.send(GetMockUserRequest(userId: 77))
            XCTAssertEqual(user, cachedUser)
            XCTAssertEqual(mockNetworkSession.requestCount, 0)
        } catch {
            XCTFail("Expected cached GET to succeed without network, got \(extractErrorKind(from: error))")
        }
    }

    func testMock_ResponseCache_ShouldRevalidateWithETag() async throws {
        let cachedUser = MockUser(id: 88, name: "Cached With ETag")
        let cachedData = try JSONEncoder().encode(cachedUser)
        let cachedURL = try XCTUnwrap(URL(string: "\(mockBaseURL)/users/88"))
        let cache = InMemoryResponseCache()
        await cache.setCachedResponse(
            CachedResponse(
                data: cachedData,
                response: HTTPURLResponse(
                    url: cachedURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json", "ETag": "etag-88"]
                )!,
                etag: "etag-88",
                maxAge: 0
            ),
            for: "\(mockBaseURL)/users/88"
        )

        mockNetworkSession.queuedResults = [
            (
                Data(),
                HTTPURLResponse(
                    url: cachedURL,
                    statusCode: 304,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["ETag": "etag-88", "Cache-Control": "max-age=60"]
                )!
            )
        ]

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off,
                responseCache: cache,
                varyIndex: VaryIndex()
            ),
            networkSession: mockNetworkSession
        )

        let user = try await client.send(GetMockUserRequest(userId: 88))
        XCTAssertEqual(user, cachedUser)
        XCTAssertEqual(mockNetworkSession.lastRequest?.value(forHTTPHeaderField: HTTPHeaderField.ifNoneMatch.rawValue), "etag-88")
        XCTAssertEqual(mockNetworkSession.requestCount, 1)
    }

    func testMock_ResponseCache_ShouldUseVaryHeadersInCacheKey() async throws {
        let englishUser = MockUser(id: 99, name: "English")
        let koreanUser = MockUser(id: 99, name: "Korean")
        let userURL = try XCTUnwrap(URL(string: "\(mockBaseURL)/users/99"))

        mockNetworkSession.queuedResults = [
            (
                try JSONEncoder().encode(englishUser),
                HTTPURLResponse(
                    url: userURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Cache-Control": "max-age=60",
                        "Vary": "accept-language"
                    ]
                )!
            ),
            (
                try JSONEncoder().encode(koreanUser),
                HTTPURLResponse(
                    url: userURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "Cache-Control": "max-age=60",
                        "Vary": "accept-language"
                    ]
                )!
            )
        ]

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off,
                responseCache: InMemoryResponseCache(),
                varyIndex: VaryIndex()
            ),
            networkSession: mockNetworkSession
        )

        let englishRequest = Netify.get(expecting: MockUser.self)
            .path("/users/99")
            .header("Accept-Language", "en")
            .authentication(required: false)

        let koreanRequest = Netify.get(expecting: MockUser.self)
            .path("/users/99")
            .header("Accept-Language", "ko")
            .authentication(required: false)

        let firstEnglish = try await client.send(englishRequest)
        let secondEnglish = try await client.send(englishRequest)
        let korean = try await client.send(koreanRequest)

        XCTAssertEqual(firstEnglish, englishUser)
        XCTAssertEqual(secondEnglish, englishUser)
        XCTAssertEqual(korean, koreanUser)
        XCTAssertEqual(mockNetworkSession.requestCount, 2)
    }

    func testMock_PluginFailures_AreIgnoredByCurrentSafeExecutor() async throws {
        let plugin = ThrowingPlugin()
        let user = MockUser(id: 11, name: "Plugin Safe")
        mockNetworkSession.mockData = try JSONEncoder().encode(user)
        mockNetworkSession.mockResponse = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "\(mockBaseURL)/users/11")),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off,
                plugins: [plugin]
            ),
            networkSession: mockNetworkSession
        )

        let result = try await client.send(GetMockUserRequest(userId: 11))
        let events = await plugin.events()
        XCTAssertEqual(result, user)
        XCTAssertEqual(events, [.willSend, .didReceive])
    }

    func testMock_PluginFailures_PropagateInStrictMode() async throws {
        let plugin = ThrowingPlugin()
        mockNetworkSession.mockData = try JSONEncoder().encode(MockUser(id: 12, name: "Strict Plugin"))
        mockNetworkSession.mockResponse = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "\(mockBaseURL)/users/12")),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off,
                plugins: [plugin],
                hookFailurePolicy: .propagate
            ),
            networkSession: mockNetworkSession
        )

        do {
            _ = try await client.send(GetMockUserRequest(userId: 12))
            XCTFail("Expected strict hook policy to propagate plugin failure")
        } catch {
            let errorKind = extractErrorKind(from: error)
            guard case .unknownError = errorKind else {
                return XCTFail("Expected .unknownError, got \(errorKind)")
            }
        }
    }

    func testMock_MetricsFailures_PropagateInStrictMode() async throws {
        let user = MockUser(id: 13, name: "Strict Metrics")
        mockNetworkSession.mockData = try JSONEncoder().encode(user)
        mockNetworkSession.mockResponse = HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "\(mockBaseURL)/users/13")),
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )

        let client = NetifyClient(
            configuration: NetifyConfiguration(
                baseURL: mockBaseURL,
                sessionConfiguration: .ephemeral,
                logLevel: .off,
                metrics: ThrowingMetrics(),
                hookFailurePolicy: .propagate
            ),
            networkSession: mockNetworkSession
        )

        do {
            _ = try await client.send(GetMockUserRequest(userId: 13))
            XCTFail("Expected strict hook policy to propagate metrics failure")
        } catch {
            let errorKind = extractErrorKind(from: error)
            guard case .unknownError = errorKind else {
                return XCTFail("Expected .unknownError, got \(errorKind)")
            }
        }
    }

    func testMock_ErrorContext_IsAttachedToDecodingFailure() async throws {
        let malformedJSONData = #"{"id":1,"name":"Test" corrupted}"#.data(using: .utf8)!
        let url = try XCTUnwrap(URL(string: "\(mockBaseURL)/users/1"))
        mockNetworkSession.mockData = malformedJSONData
        mockNetworkSession.mockResponse = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )

        do {
            _ = try await mockNetifyClient.send(GetMockUserRequest(userId: 1))
            XCTFail("Expected decoding failure")
        } catch let error as NetifyError {
            XCTAssertNotNil(error.context)
            XCTAssertTrue(error.context?.url?.contains("/users/1") == true)
            XCTAssertEqual(error.context?.method, "GET")
            XCTAssertEqual(error.context?.statusCode, 200)
            XCTAssertEqual(error.context?.attemptCount, 1)
        }
    }
}

// MARK: - Mock Types for Unit Tests
@available(iOS 15, macOS 12, *)
class MockNetworkSession: NetworkSessionProtocol, @unchecked Sendable {
    var lastRequest: URLRequest?
    var mockData: Data?
    var mockResponse: URLResponse?
    var simulateError: Error?
    var queuedErrors: [Error] = []
    var queuedResults: [(Data, URLResponse)] = []
    var requestCount = 0
    
    func data(for request: URLRequest, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, URLResponse) {
        lastRequest = request
        requestCount += 1
        if !queuedErrors.isEmpty {
            throw queuedErrors.removeFirst()
        }
        if let error = simulateError { throw error }
        if !queuedResults.isEmpty {
            return queuedResults.removeFirst()
        }
        guard let response = mockResponse else {
            throw NSError(domain: "MockNetworkSessionError", code: 1, userInfo: [NSLocalizedDescriptionKey: "mockResponse is nil."])
        }
        return (mockData ?? Data(), response)
    }
}

// MARK: - Helper Types for Mock Tests
actor RefreshCounter {
    private var count = 0

    func increment() {
        count += 1
    }

    func value() -> Int {
        count
    }
}

struct MockUser: Codable, Equatable {
    let id: Int; let name: String
}

struct MockUserInput: Codable, Equatable {
    let name: String; let job: String
}

struct MockUserResponse: Codable, Equatable {
    let id: String; let name: String; let job: String; let createdAt: Date
}

struct MockItem: Codable, Equatable {
    let itemId: Int; let description: String
}

enum ThrowingPluginEvent: Equatable {
    case willSend
    case didReceive
    case didFail
}

actor ThrowingPluginRecorder {
    private var storedEvents: [ThrowingPluginEvent] = []

    func append(_ event: ThrowingPluginEvent) {
        storedEvents.append(event)
    }

    func events() -> [ThrowingPluginEvent] {
        storedEvents
    }
}

struct ThrowingPlugin: NetifyPlugin {
    private let recorder = ThrowingPluginRecorder()

    func willSend(request: URLRequest) async throws -> URLRequest {
        await recorder.append(.willSend)
        throw NetworkRequestError.unknownError(underlyingError: nil)
    }

    func didReceive(response: URLResponse, data: Data, for request: URLRequest) async throws {
        await recorder.append(.didReceive)
        throw NetworkRequestError.unknownError(underlyingError: nil)
    }

    func didFail(with context: PluginFailureContext) async throws {
        await recorder.append(.didFail)
        throw NetworkRequestError.unknownError(underlyingError: nil)
    }

    func events() async -> [ThrowingPluginEvent] {
        await recorder.events()
    }
}

struct ThrowingMetrics: NetworkMetrics {
    func recordRequest(url: String, method: String, statusCode: Int, duration: TimeInterval, responseSize: Int) async throws {
        throw NetworkRequestError.unknownError(underlyingError: nil)
    }

    func recordError(url: String, method: String, error: Error, duration: TimeInterval) async throws {
    }

    func recordRetry(url: String, method: String, attempt: Int, error: Error) async throws {
    }
}

// MARK: - NetifyRequest Implementations for Mock Tests (Protocol Based)
@available(iOS 15, macOS 12, *)
struct GetMockUserRequest: NetifyRequest {
    typealias ReturnType = MockUser
    let userId: Int
    var path: String { "/users/\(userId)" }
}

@available(iOS 15, macOS 12, *)
struct CreateMockUserRequest: NetifyRequest {
    typealias ReturnType = MockUserResponse
    let path = "/users"
    var method: HTTPMethod = .post
    let userInput: MockUserInput
    var body: RequestBody? { .json(AnyEncodable(userInput)) }
}

@available(iOS 15, macOS 12, *)
struct GetMockItemRequest: NetifyRequest {
    typealias ReturnType = MockItem
    let itemId: Int
    var path: String { "/items/\(itemId)" }
}

@available(iOS 15, macOS 12, *)
struct DeleteMockItemRequest: NetifyRequest {
    typealias ReturnType = EmptyResponse
    let itemId: Int
    var path: String { "/delete/item/\(itemId)" }
    var method: HTTPMethod = .delete
}

@available(iOS 15, macOS 12, *)
struct GetMockStatusRequest: NetifyRequest {
    typealias ReturnType = Data // 에러 본문은 Data로 받는 것이 유연함
    let code: Int
    var path: String { "/status/\(code)" }
}

@available(iOS 15, macOS 12, *)
struct ProtectedEmptyRequest: NetifyRequest {
    typealias ReturnType = EmptyResponse
    let path = "/protected"
}

// MARK: - NetifyRequest Implementations for Integration Tests (Protocol Based)
@available(iOS 15, macOS 12, *)
struct GetPlaceholderPostRequest: NetifyRequest {
    typealias ReturnType = PlaceholderPost
    let postId: Int
    var path: String { "/posts/\(postId)" }
    var requiresAuthentication: Bool = false
}

@available(iOS 15, macOS 12, *)
struct GetAllPlaceholderPostsRequest: NetifyRequest {
    typealias ReturnType = [PlaceholderPost]
    let path = "/posts"
    var requiresAuthentication: Bool = false
}

@available(iOS 15, macOS 12, *)
struct CreatePlaceholderPostRequest: NetifyRequest {
    typealias ReturnType = PlaceholderPost
    let path = "/posts"
    let method: HTTPMethod = .post
    let postInput: PlaceholderPostInput
    var body: RequestBody? { .json(AnyEncodable(postInput)) }
    var requiresAuthentication: Bool = false
}

@available(iOS 15, macOS 12, *)
struct GetHttpBinStatusRequest: NetifyRequest {
    typealias ReturnType = Data
    let statusCode: Int
    var path: String { "/status/\(statusCode)" }
    var requiresAuthentication: Bool = false
}
