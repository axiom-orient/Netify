import Foundation
import OSLog

public protocol NetifyRequest: Sendable {
    /// 응답으로 기대하는 타입. `Decodable`을 준수해야 합니다.
    /// 내용 없는 성공 응답(예: 204 No Content)은 `EmptyResponse`를 사용합니다.
    associatedtype ReturnType: Decodable
    
    /// BaseURL을 제외한 API 경로 (예: "/users/1").
    var path: String { get }
    /// HTTP 요청 메소드 (기본값: `.get`).
    var method: HTTPMethod { get }
    /// URL 쿼리 파라미터 (예: `["page": "1", "limit": "20"]`).
    var queryParams: QueryParameters? { get }
    /// 요청 본문.
    var body: RequestBody? { get }
    /// 커스텀 HTTP 헤더. 클라이언트 기본 헤더에 병합되며, 중복 시 이 헤더가 우선합니다.
    var headers: HTTPHeaders? { get }
    /// 이 요청에만 사용할 특정 `JSONDecoder`. `nil`이면 클라이언트 기본 디코더를 사용합니다.
    var decoder: JSONDecoder? { get }
    /// 이 요청의 캐시 정책. `nil`이면 클라이언트 기본 캐시 정책을 사용합니다.
    var cachePolicy: URLRequest.CachePolicy? { get }
    /// 이 요청의 타임아웃 간격(초). `nil`이면 클라이언트 기본 타임아웃을 사용합니다.
    var timeoutInterval: TimeInterval? { get }
    /// 이 요청이 인증을 필요로 하는지 여부 (기본값: `true`).
    var requiresAuthentication: Bool { get }
}

// NetifyRequest 프로토콜의 기본 구현
@available(iOS 15, macOS 12, *)
extension NetifyRequest {
    public var method: HTTPMethod { .get }
    public var queryParams: QueryParameters? { nil }
    public var body: RequestBody? { nil }
    public var headers: HTTPHeaders? { nil }
    public var decoder: JSONDecoder? { nil }
    public var cachePolicy: URLRequest.CachePolicy? { nil }
    public var timeoutInterval: TimeInterval? { nil }
    public var requiresAuthentication: Bool { true } // 대부분의 요청은 인증이 필요하다고 가정
}

// MARK: - Declarative API Layer - Configuration (새로운 코드)
@available(iOS 15, macOS 12, *)
internal struct DeclarativeNetifyTaskConfiguration<ReturnType: Decodable>: @unchecked Sendable {
    var pathTemplate: String = ""
    var method: HTTPMethod = .get
    var headers: HTTPHeaders = [:]
    var queryParams: QueryParameters = [:]
    var body: RequestBody? = nil
    var customDecoder: JSONDecoder? = nil
    var cachePolicy: URLRequest.CachePolicy? = nil
    var timeoutInterval: TimeInterval? = nil
    var requiresAuth: Bool = true
    var pathArguments: [String: String] = [:]
}

// MARK: - Declarative API Layer - Task Builder (새로운 코드)
/// 선언적 방식으로 네트워크 요청을 구성하는 빌더입니다.
/// 이 빌더를 통해 생성된 작업은 `NetifyRequest` 프로토콜을 준수합니다.
@available(iOS 15, macOS 12, *)
public struct DeclarativeNetifyTask<ReturnType: Decodable> {
    private var configuration: DeclarativeNetifyTaskConfiguration<ReturnType>
    
    private init() {
        self.configuration = DeclarativeNetifyTaskConfiguration<ReturnType>()
    }
    
    /// 내부적으로 빌더 인스턴스를 생성합니다. `Netify.task()`를 통해 사용하세요.
    internal static func new() -> DeclarativeNetifyTask<ReturnType> {
        DeclarativeNetifyTask<ReturnType>()
    }
    
    // --- Modifier Methods ---
    
    /// 요청의 HTTP 메소드를 설정합니다.
    public func method(_ method: HTTPMethod) -> Self {
        var newRequest = self; newRequest.configuration.method = method; return newRequest
    }
    
    /// 요청 경로 템플릿을 설정합니다. (예: "/users/{id}")
    public func path(_ pathTemplate: String) -> Self {
        var newRequest = self; newRequest.configuration.pathTemplate = pathTemplate; return newRequest
    }
    
    /// 경로 템플릿 내의 특정 인자 값을 설정합니다.
    public func pathArgument(_ key: String, _ value: CustomStringConvertible) -> Self {
        var newRequest = self; newRequest.configuration.pathArguments[key] = value.description; return newRequest
    }

    /// 여러 경로 인자들을 한 번에 설정합니다.
    public func pathArguments(_ args: [String: CustomStringConvertible]) -> Self {
        var newRequest = self
        args.forEach { newRequest.configuration.pathArguments[$0.key] = $0.value.description }
        return newRequest
    }
    
    /// 요청에 커스텀 HTTP 헤더를 추가합니다.
    public func header(_ name: String, _ value: String) -> Self {
        var newRequest = self; newRequest.configuration.headers[name] = value; return newRequest
    }
    
    /// 여러 커스텀 HTTP 헤더를 한 번에 설정합니다.
    public func headers(_ headersToAdd: HTTPHeaders) -> Self {
        var newRequest = self; newRequest.configuration.headers.merge(headersToAdd) { (_, new) in new }; return newRequest
    }
    
    /// 요청 URL에 쿼리 파라미터를 추가합니다. 값이 `nil`이면 추가하지 않습니다.
    public func queryParam(_ name: String, _ value: CustomStringConvertible?) -> Self {
        guard let value = value else { return self }
        var newRequest = self; newRequest.configuration.queryParams[name] = value.description; return newRequest
    }
    
    /// 여러 쿼리 파라미터를 한 번에 설정합니다.
    public func queryParams(_ paramsToAdd: QueryParameters) -> Self {
        var newRequest = self; newRequest.configuration.queryParams.merge(paramsToAdd) { (_, new) in new }; return newRequest
    }
    
    /// `Encodable` 객체를 JSON 본문으로 설정합니다.
    public func body<B: Encodable>(_ encodableBody: B) -> Self {
        var newRequest = self
        newRequest.configuration.body = .json(AnyEncodable(encodableBody))
        return newRequest
    }

    /// 폼 데이터를 요청 본문으로 설정합니다.
    public func body(_ formBody: QueryParameters) -> Self {
        var newRequest = self
        newRequest.configuration.body = .form(formBody)
        return newRequest
    }
    
    /// 문자열을 요청 본문으로 설정합니다. 기본 Content-Type은 `.plainText`입니다.
    public func body(_ stringBody: String, contentType: HTTPContentType = .plainText) -> Self {
        var newRequest = self
        switch contentType {
        case .plainText:
            newRequest.configuration.body = .text(stringBody)
        case .xml:
            newRequest.configuration.body = .xml(stringBody)
        default:
            newRequest.configuration.body = .data(Data(stringBody.utf8), contentType: contentType)
        }
        return newRequest
    }
    
    /// `Data`를 요청 본문으로 설정합니다. `contentType`을 명시적으로 지정해야 합니다.
    public func body(_ data: Data, contentType: HTTPContentType) -> Self {
        var newRequest = self
        newRequest.configuration.body = .data(data, contentType: contentType)
        return newRequest
    }
    
    /// 멀티파트 데이터를 요청 본문으로 설정합니다. Content-Type은 자동으로 `.multipart`로 설정됩니다.
    public func multipart(_ parts: [MultipartData]) -> Self {
        var newRequest = self
        newRequest.configuration.body = parts.isEmpty ? nil : .multipart(parts)
        return newRequest
    }
    
    /// 이 요청에 사용할 커스텀 `JSONDecoder`를 지정합니다.
    public func customDecoder(_ decoder: JSONDecoder) -> Self {
        var newRequest = self; newRequest.configuration.customDecoder = decoder; return newRequest
    }
    
    /// 이 요청의 `URLRequest.CachePolicy`를 설정합니다.
    public func cachePolicy(_ policy: URLRequest.CachePolicy) -> Self {
        var newRequest = self; newRequest.configuration.cachePolicy = policy; return newRequest
    }
    
    /// 이 요청의 타임아웃 간격(초)을 설정합니다.
    public func timeout(_ interval: TimeInterval) -> Self {
        var newRequest = self; newRequest.configuration.timeoutInterval = interval; return newRequest
    }
    
    /// 이 요청이 인증을 필요로 하는지 여부를 지정합니다.
    public func authentication(required: Bool) -> Self {
        var newRequest = self; newRequest.configuration.requiresAuth = required; return newRequest
    }
}

// MARK: - Declarative API Layer - NetifyRequest Conformance (새로운 코드)
@available(iOS 15, macOS 12, *)
extension DeclarativeNetifyTask: NetifyRequest {
    // ReturnType은 이미 구조체의 제네릭 파라미터로 정의됨
    
    public var path: String {
        configuration.pathArguments.reduce(configuration.pathTemplate) { currentPath, argument in
            let encodedValue = argument.value.addingPercentEncoding(withAllowedCharacters: .urlPathValueAllowed) ?? argument.value
            return currentPath.replacingOccurrences(of: "{\(argument.key)}", with: encodedValue)
        }
    }
    public var method: HTTPMethod { configuration.method }
    public var queryParams: QueryParameters? { configuration.queryParams.isEmpty ? nil : configuration.queryParams }
    public var body: RequestBody? { configuration.body }
    public var headers: HTTPHeaders? { configuration.headers.isEmpty ? nil : configuration.headers }
    public var decoder: JSONDecoder? { configuration.customDecoder }
    public var cachePolicy: URLRequest.CachePolicy? { configuration.cachePolicy }
    public var timeoutInterval: TimeInterval? { configuration.timeoutInterval }
    public var requiresAuthentication: Bool { configuration.requiresAuth }
}

// MARK: - Declarative API Layer - Entry Point (새로운 코드)
/// Netify의 선언적 API 진입점을 제공하는 네임스페이스입니다.
@available(iOS 15, macOS 12, *)
public enum Netify {
    /// 특정 `Decodable` 응답 타입을 기대하는 선언적 네트워크 작업을 빌드하기 시작합니다.
    public static func task<R: Decodable>(expecting responseType: R.Type = R.self) -> DeclarativeNetifyTask<R> {
        return DeclarativeNetifyTask<R>.new()
    }
    
    /// 선언적 GET 네트워크 작업을 빌드하기 시작합니다.
    public static func get<R: Decodable>(expecting responseType: R.Type = R.self) -> DeclarativeNetifyTask<R> {
        return DeclarativeNetifyTask<R>.new().method(.get)
    }
    /// 선언적 POST 네트워크 작업을 빌드하기 시작합니다.
    public static func post<R: Decodable>(expecting responseType: R.Type = R.self) -> DeclarativeNetifyTask<R> {
        return DeclarativeNetifyTask<R>.new().method(.post)
    }
    /// 선언적 PUT 네트워크 작업을 빌드하기 시작합니다.
    public static func put<R: Decodable>(expecting responseType: R.Type = R.self) -> DeclarativeNetifyTask<R> {
        return DeclarativeNetifyTask<R>.new().method(.put)
    }
    /// 선언적 DELETE 네트워크 작업을 빌드하기 시작합니다.
    public static func delete<R: Decodable>(expecting responseType: R.Type = R.self) -> DeclarativeNetifyTask<R> {
        return DeclarativeNetifyTask<R>.new().method(.delete)
    }
    /// 선언적 PATCH 네트워크 작업을 빌드하기 시작합니다.
    public static func patch<R: Decodable>(expecting responseType: R.Type = R.self) -> DeclarativeNetifyTask<R> {
        return DeclarativeNetifyTask<R>.new().method(.patch)
    }
}

// MARK: - Authentication Provider Protocol & Implementations

/// 인증 관련 동작을 정의하는 프로토콜입니다. `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public protocol AuthenticationProvider: Sendable {
    /// 요청에 인증 정보를 비동기적으로 추가합니다.
    func authenticate(request: URLRequest) async throws -> URLRequest
    /// 인증 토큰 만료 시 호출되어 비동기적으로 갱신을 시도합니다.
    func refreshAuthentication() async throws -> Bool
    /// 주어진 에러가 인증 만료(예: 401 Unauthorized)를 나타내는지 확인합니다.
    func isAuthenticationExpired(from error: Error) -> Bool
}

private func extractRequestError(from error: Error) -> NetworkRequestError? {
    if let requestError = error as? NetworkRequestError {
        return requestError
    }
    if let netifyError = error as? NetifyError {
        return netifyError.kind
    }
    return nil
}

/// HTTP 기본 인증 프로바이더입니다. `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public struct BasicAuthenticationProvider: AuthenticationProvider { // Sendable은 이미 UserCredentials에 의해 암시적으로 준수
    private let credentials: UserCredentials
    
    public init(credentials: UserCredentials) {
        self.credentials = credentials
    }
    
    public func authenticate(request: URLRequest) async throws -> URLRequest {
        var req = request
        req.setValue(credentials.basicAuthHeaderValue, forHTTPHeaderField: HTTPHeaderField.authorization.rawValue)
        return req
    }
    
    // 기본 인증은 토큰 갱신 개념이 없습니다.
    public func refreshAuthentication() async throws -> Bool { return false }
    
    // 기본 인증에서 401은 일반적으로 자격 증명 실패 또는 만료를 의미합니다.
    public func isAuthenticationExpired(from error: Error) -> Bool {
        if let netErr = extractRequestError(from: error), case .unauthorized = netErr { return true }
        return false
    }
}

/// Bearer 토큰 인증 프로바이더입니다. 토큰 관리 및 갱신 로직을 포함하며, `actor`로 구현되어 동시 접근에 안전합니다.
@available(iOS 15, macOS 12, *)
public actor BearerTokenAuthenticationProvider: AuthenticationProvider {
    private var accessToken: String
    private var refreshToken: String?
    private let refreshHandler: RefreshTokenHandler? // 토큰 갱신 로직을 담는 클로저
    private var refreshTask: Task<Bool, Error>? // 동시 토큰 갱신 방지를 위한 Task
    
    /// 리프레시 토큰을 사용하여 새 토큰 정보를 가져오는 클로저 타입 정의. `@Sendable`을 준수합니다.
    public typealias RefreshTokenHandler = @Sendable (String) async throws -> TokenInfo
    
    /// 갱신된 토큰 정보를 담는 구조체. `Codable` 및 `Sendable`을 준수합니다.
    public struct TokenInfo: Codable, Sendable {
        public let accessToken: String
        public let refreshToken: String? // 옵셔널: 리프레시 토큰이 갱신되지 않을 수도 있음
        public let expiresIn: TimeInterval? // 옵셔널: 토큰 만료 시간(초)
        
        public init(accessToken: String, refreshToken: String? = nil, expiresIn: TimeInterval? = nil) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresIn = expiresIn
        }
    }
    
    public init(accessToken: String, refreshToken: String? = nil, refreshHandler: RefreshTokenHandler? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.refreshHandler = refreshHandler
    }
    
    public func authenticate(request: URLRequest) async throws -> URLRequest {
        var req = request
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: HTTPHeaderField.authorization.rawValue)
        return req
    }
    
    public func refreshAuthentication() async throws -> Bool {
        // 이미 갱신 작업이 진행 중이면 해당 작업의 결과를 기다림
        if let existingTask = refreshTask {
            return try await existingTask.value
        }
        
        // 리프레시 토큰이나 핸들러가 없으면 갱신 불가
        guard let currentRefreshToken = refreshToken, let handler = refreshHandler else {
            return false
        }
        
        // 새로운 Task를 생성하여 토큰 갱신 수행
        let task = Task<Bool, Error> {
            defer { self.refreshTask = nil } // 작업 완료 시 refreshTask를 nil로 설정
            
            let newTokens = try await handler(currentRefreshToken) // 핸들러 호출
            
            self.accessToken = newTokens.accessToken // 새 액세스 토큰으로 업데이트
            // 핸들러가 새 리프레시 토큰을 제공하면 업데이트, 아니면 기존 값 유지 (nil일 수도 있음)
            self.refreshToken = newTokens.refreshToken ?? self.refreshToken
            
            // TODO: expiresIn을 사용하여 다음 자동 갱신 스케줄링 등의 로직 추가 가능
            return true // 갱신 성공
        }
        self.refreshTask = task // 현재 진행 중인 작업으로 저장
        return try await task.value // 작업 결과 반환
    }
    
    // isAuthenticationExpired는 외부 상태에 의존하지 않으므로 nonisolated로 선언 가능
    public nonisolated func isAuthenticationExpired(from error: Error) -> Bool {
        if let netErr = extractRequestError(from: error), case .unauthorized = netErr { return true }
        // TODO: API가 특정 에러 코드로 토큰 만료를 알리는 경우 추가 검사 로직 구현 가능
        return false
    }
    
    /// 외부에서 토큰을 직접 업데이트할 수 있는 메소드 (예: 로그인 성공 후).
    public func updateTokens(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
    
    /// 현재 액세스 토큰을 안전하게 가져옵니다.
    public func getCurrentAccessToken() -> String {
        return accessToken
    }
}


// MARK: - Multipart Data Structures

/// HTTP 요청 본문의 일부를 나타내는 프로토콜입니다 (주로 멀티파트).
@available(iOS 15, macOS 12, *)
public protocol HttpBodyConvertible {
    /// 멀티파트 요청의 한 부분을 구성하는 데이터를 생성합니다.
    /// - Parameter boundary: 멀티파트 경계 문자열.
    /// - Returns: 생성된 `Data` 객체.
    func buildHttpBodyPart(boundary: String) -> Data
}

/// 멀티파트 요청에 포함될 파일 또는 데이터 청크를 나타냅니다. `Identifiable`, `HttpBodyConvertible`, `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public struct MultipartData: Identifiable, HttpBodyConvertible, Sendable {
    public let id = UUID() // 각 파트의 고유 식별자
    let name: String       // 폼 필드의 이름 (API 명세에 따름)
    let fileData: Data     // 실제 파일 또는 데이터
    let fileName: String   // 서버에 전달될 파일 이름
    let mimeType: String   // 데이터의 MIME 타입 (예: "image/jpeg", "application/pdf")
    
    public init(name: String, fileData: Data, fileName: String, mimeType: String) {
        self.name = name
        self.fileData = fileData
        self.fileName = fileName
        self.mimeType = mimeType
    }
    
    public func buildHttpBodyPart(boundary: String) -> Data {
        let body = NSMutableData()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n") // 헤더와 데이터 사이에는 CRLF 두 번
        body.append(fileData)
        body.appendString("\r\n") // 각 파트의 끝
        return body as Data
    }
}

// MARK: - URL Utilities & Extensions

/// URL 경로 결합 및 생성을 위한 헬퍼 구조체입니다.
@available(iOS 15, macOS 12, *)
public struct URLPathBuilder {
    /// 기본 URL 문자열과 경로 문자열을 결합하여 URL 객체를 생성합니다.
    /// 기본 URL과 경로 사이의 슬래시(/)를 적절히 처리합니다.
    public static func buildURL(baseURL: String, path: String) throws -> URL {
        guard var components = URLComponents(string: baseURL) else {
            throw NetworkRequestError.invalidRequest(reason: "잘못된 기본 URL 문자열입니다: \(baseURL)")
        }
        
        let basePath = components.path // 기본 URL 자체의 경로 부분
        let pathToAppend = path.starts(with: "/") ? String(path.dropFirst()) : path // 추가할 경로의 첫 슬래시 제거
        
        // 기본 경로가 비어있거나 슬래시로 끝나면 바로 연결, 아니면 슬래시 추가 후 연결
        if basePath.isEmpty || basePath.hasSuffix("/") {
            components.path = basePath + pathToAppend
        } else {
            components.path = basePath + "/" + pathToAppend
        }
        
        // 경로 정규화: 중복 슬래시 제거 (예: /api//v1/users -> /api/v1/users)
        // URLComponents.path는 자동으로 선행 슬래시를 관리하므로, 수동으로 추가/제거할 필요가 줄어듭니다.
        // 하지만, 여기서 명시적으로 한번 더 정제하여 일관성을 높입니다.
        let normalizedPath = components.path.split(separator: "/", omittingEmptySubsequences: true).joined(separator: "/")
        components.path = normalizedPath.isEmpty ? "/" : "/" + normalizedPath // 비어있지 않으면 항상 슬래시로 시작
        
        guard let url = components.url else {
            throw NetworkRequestError.invalidRequest(reason: "최종 URL 생성 실패: baseURL '\(baseURL)', path '\(path)'")
        }
        return url
    }
}

@available(iOS 15, macOS 12, *)
extension CharacterSet {
    /// RFC 3986 path segment 인코딩에 허용되는 문자 집합입니다.
    public static let urlPathValueAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    /// RFC 3986에 따른 URL 쿼리 값 인코딩에 허용되는 문자 집합입니다.
    /// 알파벳, 숫자 및 '-', '.', '_', '~'를 포함합니다. 일반 구분자와 하위 구분자는 제외합니다.
    public static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~") // 비예약(unreserved) 문자
        return allowed
    }()
}

/// `QueryParameters` ([String: String])를 URL 쿼리 문자열로 변환하는 확장입니다.
@available(iOS 15, macOS 12, *)
extension Dictionary where Key == String, Value == String {
    /// 딕셔너리를 URL 인코딩된 쿼리 문자열로 변환합니다 (예: "key1=value1&key2=value2").
    /// 키와 값은 `CharacterSet.urlQueryValueAllowed`를 사용하여 퍼센트 인코딩됩니다.
    public func toUrlEncodedQueryString() -> String? {
        guard !self.isEmpty else { return nil }
        return self.map { key, value in
            // 키와 값 모두 퍼센트 인코딩
            let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
            return "\(escapedKey)=\(escapedValue)"
        }.joined(separator: "&")
    }
    
    // toURLQueryItems()는 URLComponents가 내부적으로 인코딩을 처리하므로 유지합니다.
    public func toURLQueryItems() -> [URLQueryItem]? {
        guard !isEmpty else { return nil }
        return map { URLQueryItem(name: $0.key, value: $0.value) }
    }
}

/// `NSMutableData`에 문자열을 UTF-8 데이터로 추가하는 내부 확장 기능입니다.
internal extension NSMutableData {
    /// 지정된 문자열을 UTF-8 인코딩을 사용하여 `NSMutableData`에 추가합니다.
    func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            self.append(data)
        }
        // UTF-8 인코딩 실패 시 (거의 발생하지 않음) 로깅 또는 에러 처리 고려 가능
    }
}

/// `URLRequest`를 cURL 명령어 문자열로 변환하는 확장 기능입니다 (디버깅 목적).
@available(iOS 15, macOS 12, *)
extension URLRequest {
    /// 디버깅을 위해 `URLRequest`의 cURL 명령어 문자열 표현을 생성합니다.
    /// 민감한 헤더(Authorization, Cookie 등)는 마스킹 처리됩니다.
    public func toCurlCommand() -> String {
        guard let url = self.url else { return "# Netify: cURL 명령어 생성 실패 (유효하지 않은 URL)" }
        var command = [#"curl -v "\#(url.absoluteString)""#] // -v 옵션으로 상세 출력
        
        // HTTP 메소드 추가 (GET이 아니면)
        if let httpMethod = self.httpMethod, httpMethod.uppercased() != "GET" {
            command.append("-X \(httpMethod.uppercased())")
        }
        
        // 헤더 추가 (민감 정보 마스킹)
        self.allHTTPHeaderFields?.sorted(by: { $0.key < $1.key }).forEach { key, value in
            let displayValue = NetifyInternalConstants.sensitiveHeaderKeys.contains(key.lowercased()) ? "<masked>" : value
            let escapedValue = displayValue.replacingOccurrences(of: "'", with: #"\'"#) // 작은 따옴표 이스케이프
            command.append("-H '\(key): \(escapedValue)'")
        }
        
        // 본문 데이터 추가
        if let httpBodyData = self.httpBody {
            if let bodyString = String(data: httpBodyData, encoding: .utf8), !bodyString.isEmpty {
                let maxLen = NetifyInternalConstants.maxLogSummaryLength
                let truncatedBody = bodyString.prefix(maxLen)
                let escapedBody = String(truncatedBody).replacingOccurrences(of: "'", with: #"\'"#)
                command.append("-d '\(escapedBody)\(bodyString.count > maxLen ? "..." : "")'")
            } else if !httpBodyData.isEmpty {
                command.append("--data-binary '<바이너리 데이터: \(httpBodyData.count) bytes>'")
            }
        } else if let stream = self.httpBodyStream {
            command.append("--data-binary '<입력 스트림 데이터: \(stream.description)>'")
        }
        
        // 가독성을 위해 줄바꿈 및 들여쓰기 적용
        return command.joined(separator: " \\\n    ")
    }
}

// MARK: - Sanitization Utilities for Plugins

@available(iOS 15, macOS 12, *)
internal func sanitizeForOperationString(_ message: String) -> String {
    var s = message
    for (regex, replacement) in NetifyInternalConstants.sanitizationPatterns {
        let range = NSRange(s.startIndex..., in: s)
        s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
    }
    return s
}

@available(iOS 15, macOS 12, *)
public struct RequestSummary: Sendable {
    public let url: String?
    public let method: String?
    public let headers: [String: String]?
    public let bodyPreview: String?
}

@available(iOS 15, macOS 12, *)
internal extension URLRequest {
    /// 플러그인에 안전하게 전달하기 위한 요청 요약을 생성합니다.
    func toRequestSummaryForPlugins(maxBody: Int = 256) -> RequestSummary {
        let urlString = self.url?.absoluteString
        let maskedURL = urlString.map { sanitizeForOperationString($0) }

        var headersSummary: [String: String]? = nil
        if let headers = self.allHTTPHeaderFields, !headers.isEmpty {
            var masked: [String: String] = [:]
            for (k, v) in headers {
                if NetifyInternalConstants.sensitiveHeaderKeys.contains(k.lowercased()) {
                    masked[k] = "<masked>"
                } else {
                    masked[k] = sanitizeForOperationString(v)
                }
            }
            headersSummary = masked
        }

        var bodyPreview: String? = nil
        if let body = self.httpBody, !body.isEmpty {
            if let s = String(data: body, encoding: .utf8) {
                let truncated = s.prefix(maxBody)
                bodyPreview = sanitizeForOperationString(String(truncated)) + (s.count > maxBody ? "..." : "")
            } else {
                bodyPreview = "<binary data: \(body.count) bytes>"
            }
        } else if self.httpBodyStream != nil {
            bodyPreview = "<input stream>"
        }

        return RequestSummary(
            url: maskedURL,
            method: self.httpMethod,
            headers: headersSummary,
            bodyPreview: bodyPreview
        )
    }
}
