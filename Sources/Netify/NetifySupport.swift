import Foundation
import OSLog // 로깅 프레임워크 임포트

// MARK: - Core Protocols

/// Netify 클라이언트의 핵심 기능을 정의하는 프로토콜입니다.
/// 테스트 용이성을 위해 구체적인 클라이언트 구현 대신 이 프로토콜에 의존할 수 있습니다.
@available(iOS 15, macOS 12, *)
public protocol NetifyClientProtocol {
    /// Netify 클라이언트의 설정을 가져옵니다. (Mock 객체 등에서 필요할 수 있음)
    var configuration: NetifyConfiguration { get }
    
    /// 특정 NetifyRequest를 비동기적으로 보내고 응답을 처리합니다.
    func send<Request: NetifyRequest>(_ request: Request) async throws -> Request.ReturnType
}

// MARK: - Network Session Protocol Definition (for Testing)

/// `URLSession`의 `data(for:delegate:)` 메소드에 대한 인터페이스를 제공하여 테스트 중 Mock 객체 주입을 용이하게 합니다.
@available(iOS 15, macOS 12, *)
public protocol NetworkSessionProtocol {
    /// 지정된 URL 요청에 따라 URL의 내용을 비동기적으로 검색합니다.
    /// `URLSession.data(for:delegate:)`에 해당합니다.
    func data(for request: URLRequest, delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse)
}

// MARK: - URLSession Conformance

@available(iOS 15, macOS 12, *)
extension URLSession: NetworkSessionProtocol {} // URLSession이 NetworkSessionProtocol을 준수하도록 합니다.

// MARK: - Internal Constants

@available(iOS 15, macOS 12, *)
internal enum NetifyInternalConstants {
    /// 로깅 및 cURL 명령어 출력 시 마스킹할 민감한 HTTP 헤더 키 목록 (소문자)
    static let sensitiveHeaderKeys: Set<String> = [
        HTTPHeaderField.authorization.rawValue.lowercased(),
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "api-key",
        "x-auth-token",
        "x-csrf-token",
        "client-secret",
        "access-token",
        "refresh-token",
        "bearer-token",
        "password",
        "secret",
        "token",
        "private-token",
        "session-id",
        "session-token"
    ]
    
    /// 로깅 시 요약할 최대 데이터 길이 (바이트)
    static let maxLogSummaryLength = 1024

    /// 민감정보 마스킹에 사용되는 사전 컴파일된 정규식 패턴 목록
    static let sanitizationPatterns: [(NSRegularExpression, String)] = {
        let raw: [(String, String)] = [
            ("(?i)\\bBearer\\s+[A-Za-z0-9\\-._~+/]+=*", "Bearer <masked>"),
            ("(?i)\\bBasic\\s+[A-Za-z0-9+/]+=*", "Basic <masked>"),
            ("(?i)\\b(token|access[_-]?token|password|secret)[\"':\\s=]+[^\\s\"']+", "$1: <masked>"),
            ("\\b[A-Za-z0-9-_]+?\\.[A-Za-z0-9-_]+?\\.[A-Za-z0-9-_]+\\b", "<jwt:masked>"),
            ("([?&](?i)(api[_-]?key|key|access[_-]?token)=)[^&]+", "$1<masked>"),
            ("(?i)(cookie:\\s*)(.+)", "$1<masked>")
        ]
        return raw.compactMap { pattern, replacement in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
            return (regex, replacement)
        }
    }()

    /// 기본 재시도 전 대기 시간 (초)
    static let defaultRetryDelaySeconds: TimeInterval = 1.0
    /// 지수 백오프 기본 배율
    static let exponentialBackoffMultiplier: Double = 2.0
    /// 최대 재시도 대기 시간 (초)
    static let maxRetryDelaySeconds: TimeInterval = 30.0
}

// MARK: - Public Configuration & Basic Types

/// Netify 클라이언트의 설정을 정의하는 구조체입니다. `Sendable`을 준수하여 동시성 환경에서 안전하게 사용될 수 있습니다.
@available(iOS 15, macOS 12, *)
public struct NetifyConfiguration: Sendable {
    public let baseURL: String
    public let sessionConfiguration: URLSessionConfiguration
    public let defaultEncoder: JSONEncoder
    public let defaultDecoder: JSONDecoder
    public let defaultHeaders: HTTPHeaders
    public let logLevel: NetworkingLogLevel
    public let cachePolicy: URLRequest.CachePolicy
    public let maxRetryCount: Int
    public let timeoutInterval: TimeInterval
    public let authenticationProvider: AuthenticationProvider?
    public let waitsForConnectivity: Bool
    public let responseCache: ResponseCache?
    public let plugins: [NetifyPlugin]
    public let metrics: NetworkMetrics
    public let varyIndex: VaryIndex?
    public let hookFailurePolicy: HookFailurePolicy
    
    public init(
        baseURL: String,
        sessionConfiguration: URLSessionConfiguration = .default,
        defaultEncoder: JSONEncoder = JSONEncoder(),
        defaultDecoder: JSONDecoder = JSONDecoder(),
        defaultHeaders: HTTPHeaders = [:],
        logLevel: NetworkingLogLevel = .info,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy,
        maxRetryCount: Int = 1,
        timeoutInterval: TimeInterval = 30.0,
        authenticationProvider: AuthenticationProvider? = nil,
        waitsForConnectivity: Bool = false, // 기본값은 false로 설정 (시스템 기본값은 true)
        responseCache: ResponseCache? = nil,
        plugins: [NetifyPlugin] = [],
        metrics: NetworkMetrics = NoopMetrics(),
        varyIndex: VaryIndex? = nil,
        hookFailurePolicy: HookFailurePolicy = .ignore
    ) {
        // baseURL의 마지막 '/' 문자 제거
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.sessionConfiguration = sessionConfiguration
        self.defaultEncoder = defaultEncoder
        self.defaultDecoder = defaultDecoder
        self.defaultHeaders = defaultHeaders
        self.logLevel = logLevel
        self.cachePolicy = cachePolicy
        self.maxRetryCount = max(0, maxRetryCount) // 음수 방지
        self.timeoutInterval = timeoutInterval
        self.authenticationProvider = authenticationProvider
        self.waitsForConnectivity = waitsForConnectivity
        self.responseCache = responseCache
        self.plugins = plugins
        self.metrics = metrics
        self.varyIndex = varyIndex
        self.hookFailurePolicy = hookFailurePolicy
        
        // sessionConfiguration에 waitsForConnectivity 명시적 적용
        self.sessionConfiguration.waitsForConnectivity = waitsForConnectivity
        // 기본 타임아웃도 sessionConfiguration에 반영 (요청별 타임아웃이 우선됨)
        self.sessionConfiguration.timeoutIntervalForRequest = timeoutInterval
    }
}

/// 네트워크 로깅의 상세 수준을 정의합니다. `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public enum NetworkingLogLevel: Int, Comparable, Sendable {
    case off = 0    // 로깅 비활성화
    case error = 1  // 에러만 로깅
    case info = 2   // 정보성 로깅 (요청/응답 요약)
    case debug = 3  // 상세 디버그 로깅 (헤더, 바디, cURL 등)
    
    public static func < (lhs: NetworkingLogLevel, rhs: NetworkingLogLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

@available(iOS 15, macOS 12, *)
public enum HookFailurePolicy: Sendable {
    case ignore
    case propagate
}

// MARK: - Response Cache Protocol & Implementation

/// 응답 캐시 저장소를 정의하는 프로토콜입니다.
@available(iOS 15, macOS 12, *)
public protocol ResponseCache: Sendable {
    /// 캐시된 응답을 조회합니다.
    func getCachedResponse(for key: String) async -> CachedResponse?
    /// 응답을 캐시에 저장합니다.
    func setCachedResponse(_ response: CachedResponse, for key: String) async
    /// 특정 키의 캐시를 삭제합니다.
    func removeCachedResponse(for key: String) async
    /// 모든 캐시를 삭제합니다.
    func clearCache() async
}

/// 캐시된 응답 데이터를 나타내는 구조체입니다.
@available(iOS 15, macOS 12, *)
public struct CachedResponse: Sendable {
    public let data: Data
    public let response: HTTPURLResponse
    public let cachedAt: Date
    public let etag: String?
    public let maxAge: TimeInterval?
    
    public init(data: Data, response: HTTPURLResponse, etag: String? = nil, maxAge: TimeInterval? = nil) {
        self.data = data
        self.response = response
        self.cachedAt = Date()
        self.etag = etag
        self.maxAge = maxAge
    }
    
    /// 캐시된 응답이 여전히 유효한지 확인합니다.
    public var isValid: Bool {
        guard let maxAge = maxAge else { return true }
        return Date().timeIntervalSince(cachedAt) < maxAge
    }
}

/// 메모리 기반 응답 캐시 구현체입니다.
@available(iOS 15, macOS 12, *)
public actor InMemoryResponseCache: ResponseCache {
    private var cache: [String: CachedResponse] = [:]
    private let maxCacheSize: Int
    private let defaultTTL: TimeInterval
    
    public init(maxCacheSize: Int = 100, defaultTTL: TimeInterval = 300) {
        self.maxCacheSize = maxCacheSize
        self.defaultTTL = defaultTTL
    }
    
    public func getCachedResponse(for key: String) async -> CachedResponse? {
        cache[key]
    }
    
    public func setCachedResponse(_ response: CachedResponse, for key: String) async {
        if cache.count >= maxCacheSize {
            evictOldestEntry()
        }
        cache[key] = response
    }
    
    public func removeCachedResponse(for key: String) async {
        cache.removeValue(forKey: key)
    }
    
    public func clearCache() async {
        cache.removeAll()
    }
    
    private func evictOldestEntry() {
        guard let oldestKey = cache.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key else { return }
        cache.removeValue(forKey: oldestKey)
    }
}

/// Vary 헤더를 기반으로 캐시 키를 관리하는 액터입니다.
@available(iOS 15, macOS 12, *)
public actor VaryIndex: Sendable {
    private var varyHeaders: [String: Set<String>] = [:]
    
    /// URL과 Vary 헤더를 기반으로 캐시 키를 생성합니다.
    public func generateCacheKey(url: String, headers: [String: String], varyHeaders: [String]) async -> String {
        let normalizedHeaders = Dictionary(
            uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) }
        )
        var keyComponents = [url]
        
        for varyHeader in varyHeaders.sorted() {
            let headerValue = normalizedHeaders[varyHeader.lowercased()] ?? ""
            keyComponents.append("\(varyHeader):\(headerValue)")
        }
        
        return keyComponents.joined(separator: "|")
    }
    
    /// URL에 대한 Vary 헤더를 저장합니다.
    public func setVaryHeaders(_ headers: Set<String>, for url: String) async {
        varyHeaders[url] = Set(headers.map { $0.lowercased() })
    }
    
    /// URL에 대한 Vary 헤더를 조회합니다.
    public func getVaryHeaders(for url: String) async -> Set<String> {
        return varyHeaders[url] ?? []
    }
}

// MARK: - Plugin System

/// 플러그인 실패 시 전달되는 컨텍스트 정보입니다.
@available(iOS 15, macOS 12, *)
public struct PluginFailureContext: Sendable {
    /// 마스킹된 요청 요약 (구성 실패 시 nil일 수 있음)
    public let requestSummary: RequestSummary?
    /// 에러 요약 문자열 (민감정보 마스킹 적용된 안전한 요약)
    public let errorSummary: String
    /// 요청 시작 시각
    public let startedAt: Date
    /// 현재 재시도 횟수 (nil이면 재시도 아님)
    public let attemptCount: Int?
    /// 요청 URL (request가 nil인 경우를 위한 백업)
    public let targetURL: String?
    
    public init(
        requestSummary: RequestSummary?,
        errorSummary: String,
        startedAt: Date,
        attemptCount: Int? = nil,
        targetURL: String? = nil
    ) {
        self.requestSummary = requestSummary
        self.errorSummary = errorSummary
        self.startedAt = startedAt
        self.attemptCount = attemptCount
        self.targetURL = targetURL ?? requestSummary?.url
    }
}

/// Netify 플러그인을 정의하는 프로토콜입니다.
@available(iOS 15, macOS 12, *)
public protocol NetifyPlugin: Sendable {
    /// 요청 전송 전에 호출됩니다.
    func willSend(request: URLRequest) async throws -> URLRequest
    /// 응답 수신 후에 호출됩니다.
    func didReceive(response: URLResponse, data: Data, for request: URLRequest) async throws
    /// 에러 발생 시 호출됩니다.
    func didFail(with context: PluginFailureContext) async throws
}

/// 기본 플러그인 구현 (모든 메서드가 기본 동작)
@available(iOS 15, macOS 12, *)
public struct DefaultNetifyPlugin: NetifyPlugin {
    public init() {}
    
    public func willSend(request: URLRequest) async throws -> URLRequest {
        return request
    }
    
    public func didReceive(response: URLResponse, data: Data, for request: URLRequest) async throws {
        // 기본 동작: 아무것도 하지 않음
    }
    
    public func didFail(with context: PluginFailureContext) async throws {
        // 기본 동작: 아무것도 하지 않음
    }
}

/// 플러그인 실행을 안전하게 처리하는 헬퍼
@available(iOS 15, macOS 12, *)
internal struct SafePluginExecutor {
    private let logger: NetifyLogging
    private let policy: HookFailurePolicy
    
    init(logger: NetifyLogging, policy: HookFailurePolicy) {
        self.logger = logger
        self.policy = policy
    }
    
    /// 플러그인의 willSend를 안전하게 실행합니다.
    func executeWillSend(plugins: [NetifyPlugin], request: URLRequest) async throws -> URLRequest {
        var currentRequest = request
        
        for (index, plugin) in plugins.enumerated() {
            do {
                currentRequest = try await plugin.willSend(request: currentRequest)
            } catch {
                if policy == .propagate {
                    throw error
                }
                logger.logForOperation("플러그인 [\(index)] willSend에서 에러 발생, 무시함: \(error.localizedDescription)")
            }
        }
        
        return currentRequest
    }
    
    /// 플러그인의 didReceive를 안전하게 실행합니다.
    func executeDidReceive(plugins: [NetifyPlugin], response: URLResponse, data: Data, request: URLRequest) async throws {
        for (index, plugin) in plugins.enumerated() {
            do {
                try await plugin.didReceive(response: response, data: data, for: request)
            } catch {
                if policy == .propagate {
                    throw error
                }
                logger.logForOperation("플러그인 [\(index)] didReceive에서 에러 발생, 무시함: \(error.localizedDescription)")
            }
        }
    }
    
    /// 플러그인의 didFail을 안전하게 실행합니다.
    func executeDidFail(plugins: [NetifyPlugin], context: PluginFailureContext) async {
        for (index, plugin) in plugins.enumerated() {
            do {
                try await plugin.didFail(with: context)
            } catch {
                logger.logForOperation("플러그인 [\(index)] didFail에서 에러 발생, 원본 요청 에러 보존을 위해 무시함: \(error.localizedDescription)")
            }
        }
    }
}

/// 메트릭 실행을 안전하게 처리하는 헬퍼
@available(iOS 15, macOS 12, *)
internal struct SafeMetricsExecutor {
    private let logger: NetifyLogging
    private let policy: HookFailurePolicy
    
    init(logger: NetifyLogging, policy: HookFailurePolicy) {
        self.logger = logger
        self.policy = policy
    }
    
    /// 요청 성공 메트릭을 안전하게 기록합니다.
    func recordRequest(metrics: NetworkMetrics, url: String, method: String, statusCode: Int, duration: TimeInterval, responseSize: Int) async throws {
        do {
            try await metrics.recordRequest(url: url, method: method, statusCode: statusCode, duration: duration, responseSize: responseSize)
        } catch {
            if policy == .propagate {
                throw error
            }
            logger.logForOperation("메트릭 recordRequest에서 에러 발생, 무시함: \(error.localizedDescription)")
        }
    }
    
    /// 요청 실패 메트릭을 안전하게 기록합니다.
    func recordError(metrics: NetworkMetrics, url: String, method: String, error: Error, duration: TimeInterval) async {
        do {
            try await metrics.recordError(url: url, method: method, error: error, duration: duration)
        } catch {
            logger.logForOperation("메트릭 recordError에서 에러 발생, 무시함: \(error.localizedDescription)")
        }
    }
    
    /// 재시도 메트릭을 안전하게 기록합니다.
    func recordRetry(metrics: NetworkMetrics, url: String, method: String, attempt: Int, error: Error) async {
        do {
            try await metrics.recordRetry(url: url, method: method, attempt: attempt, error: error)
        } catch {
            logger.logForOperation("메트릭 recordRetry에서 에러 발생, 무시함: \(error.localizedDescription)")
        }
    }
}

// MARK: - Metrics System

/// 네트워크 메트릭을 수집하기 위한 프로토콜입니다.
@available(iOS 15, macOS 12, *)
public protocol NetworkMetrics: Sendable {
    /// 요청 성공을 기록합니다.
    func recordRequest(url: String, method: String, statusCode: Int, duration: TimeInterval, responseSize: Int) async throws
    /// 요청 실패를 기록합니다.
    func recordError(url: String, method: String, error: Error, duration: TimeInterval) async throws
    /// 재시도를 기록합니다.
    func recordRetry(url: String, method: String, attempt: Int, error: Error) async throws
}

/// 기본 메트릭 구현체 (아무것도 하지 않음)
@available(iOS 15, macOS 12, *)
public struct NoopMetrics: NetworkMetrics {
    public init() {}
    
    public func recordRequest(url: String, method: String, statusCode: Int, duration: TimeInterval, responseSize: Int) async throws {
        // 기본 동작: 아무것도 하지 않음
    }
    
    public func recordError(url: String, method: String, error: Error, duration: TimeInterval) async throws {
        // 기본 동작: 아무것도 하지 않음
    }
    
    public func recordRetry(url: String, method: String, attempt: Int, error: Error) async throws {
        // 기본 동작: 아무것도 하지 않음
    }
}

/// HTTP 요청 메서드를 정의합니다. `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public struct HTTPMethod: RawRepresentable, Equatable, Hashable, Sendable {
    public static let get = HTTPMethod(rawValue: "GET")
    public static let post = HTTPMethod(rawValue: "POST")
    public static let put = HTTPMethod(rawValue: "PUT")
    public static let delete = HTTPMethod(rawValue: "DELETE")
    public static let patch = HTTPMethod(rawValue: "PATCH")
    public static let head = HTTPMethod(rawValue: "HEAD")
    public static let options = HTTPMethod(rawValue: "OPTIONS")
    
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue.uppercased() } // 일관성을 위해 대문자로 저장
}

/// 표준 HTTP 요청/응답 헤더 필드를 정의합니다. `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public enum HTTPHeaderField: String, Sendable, CaseIterable {
    case authorization = "Authorization"
    case contentType = "Content-Type"
    case acceptType = "Accept"
    case acceptEncoding = "Accept-Encoding"
    case userAgent = "User-Agent"
    case cacheControl = "Cache-Control"
    case eTag = "ETag"
    case ifNoneMatch = "If-None-Match"
    // 필요시 추가
}

/// HTTP 요청 본문의 Content-Type을 정의합니다. `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public enum HTTPContentType: String, Sendable {
    case json = "application/json; charset=utf-8"
    case urlEncoded = "application/x-www-form-urlencoded; charset=utf-8"
    case multipart = "multipart/form-data" // Boundary는 동적으로 추가됨
    case plainText = "text/plain; charset=utf-8"
    case xml = "application/xml; charset=utf-8"
    case octetStream = "application/octet-stream" // 바이너리 데이터
    // 필요시 추가
}

/// 타입이 지워진 `Encodable` 래퍼입니다.
@available(iOS 15, macOS 12, *)
public struct AnyEncodable: Encodable, @unchecked Sendable {
    private let encodeValue: (Encoder) throws -> Void

    public init<Value: Encodable>(_ value: Value) {
        self.encodeValue = { encoder in
            try value.encode(to: encoder)
        }
    }

    public func encode(to encoder: Encoder) throws {
        try encodeValue(encoder)
    }
}

/// 요청 본문을 타입으로 고정하는 모델입니다.
@available(iOS 15, macOS 12, *)
public enum RequestBody: Sendable {
    case json(AnyEncodable)
    case form([String: String])
    case text(String)
    case xml(String)
    case data(Data, contentType: HTTPContentType)
    case multipart([MultipartData])

    var resolvedContentType: HTTPContentType {
        switch self {
        case .json:
            return .json
        case .form:
            return .urlEncoded
        case .text:
            return .plainText
        case .xml:
            return .xml
        case .data(_, let contentType):
            return contentType
        case .multipart:
            return .multipart
        }
    }
}

/// 빈 응답 본문을 나타내는 타입입니다. 성공했지만 내용이 없는 경우 (예: 204 No Content) 사용될 수 있습니다.
/// `Decodable` 및 `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public struct EmptyResponse: Decodable, Sendable {}

/// 쿼리 파라미터 타입 별칭입니다. ([String: String])
@available(iOS 15, macOS 12, *)
public typealias QueryParameters = [String: String]

/// HTTP 헤더 타입 별칭입니다. ([String: String])
@available(iOS 15, macOS 12, *)
public typealias HTTPHeaders = [String: String]

/// 사용자 자격 증명 (기본 인증용). `Sendable`을 준수합니다.
@available(iOS 15, macOS 12, *)
public struct UserCredentials: Sendable {
    let username: String
    let password: String
    
    /// 기본 인증 헤더 값을 생성합니다 (예: "Basic dXNlcjpwYXNzd29yZA==").
    var basicAuthHeaderValue: String {
        let loginString = "\(username):\(password)"
        guard let data = loginString.data(using: .utf8) else { return "" } // UTF-8 인코딩 실패 시 빈 문자열 반환
        return "Basic \(data.base64EncodedString())"
    }
    
    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

// MARK: - Logging Protocol & Implementation

/// Netify 내에서 네트워크 요청 및 응답 로깅을 위한 프로토콜입니다.
@available(iOS 15, macOS 12, *)
public protocol NetifyLogging: Sendable {
    var logLevel: NetworkingLogLevel { get }
    func log(message: String, level: OSLogType)
    func log(request: URLRequest, level: OSLogType)
    func log(response: URLResponse, data: Data?, level: OSLogType)
    func log(error: Error, level: OSLogType)
    
    /// 운영용 간소 로그 (민감정보 자동 마스킹)
    func logForOperation(_ message: String)
    /// 디버깅용 상세 로그 (민감정보 마스킹 + 상세 컨텍스트)
    func logForDebug(_ message: String)
    /// 에러의 향상된 디버그 정보 로그
    func logEnhancedError(_ netifyError: NetifyError)
}

/// `os.Logger`를 사용하는 `NetifyLogging`의 기본 구현체입니다.
@available(iOS 15, macOS 12, *)
public struct DefaultNetifyLogger: NetifyLogging {
    public let logLevel: NetworkingLogLevel
    private let logger: Logger // os.Logger 인스턴스
    
    /// `DefaultNetifyLogger`를 초기화합니다.
    /// - Parameters:
    ///   - logLevel: 로깅 상세 수준.
    ///   - subsystem: `os.Logger`에 사용할 서브시스템 문자열. 기본값은 앱 번들 ID.
    ///   - category: `os.Logger`에 사용할 카테고리 문자열. 기본값은 "Netify".
    public init(
        logLevel: NetworkingLogLevel,
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.unknown.netify", // 기본 서브시스템 개선
        category: String = "Netify"
    ) {
        self.logLevel = logLevel
        self.logger = Logger(subsystem: subsystem, category: category)
    }
    
    public func log(message: String, level: OSLogType = .debug) {
        guard shouldLog(for: level) else { return }
        logger.log(level: level, "\(message)")
    }
    
    public func log(request: URLRequest, level: OSLogType = .debug) {
        guard shouldLog(for: level) else { return }
        
        var logMessage = "\n➡️ Request: \(request.httpMethod ?? "UNKNOWN_METHOD") \(request.url?.absoluteString ?? "UNKNOWN_URL")"
        
        if self.logLevel >= .debug { // logLevel에 따라 상세 정보 로깅 결정
            if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
                logMessage += "\n    Headers: \(headers.maskingSensitiveHeaders())"
            }
            if let bodyData = request.httpBody, !bodyData.isEmpty {
                let bodySummary = summarizeData(bodyData, contentType: request.value(forHTTPHeaderField: HTTPHeaderField.contentType.rawValue))
                logMessage += "\n    Body: \(bodySummary)"
            } else if request.httpBodyStream != nil {
                logMessage += "\n    Body: InputStream data (length unknown)" // 스트림은 길이 알 수 없음 명시
            }
            logMessage += "\n    cURL: \(request.toCurlCommand())"
        }
        logger.log(level: level, "\(logMessage)")
    }
    
    public func log(response: URLResponse, data: Data?, level: OSLogType = .debug) {
        guard shouldLog(for: level) else { return }
        
        var logMessage = "\n⬅️ Response:"
        if let httpResponse = response as? HTTPURLResponse {
            let statusIcon = (200...299).contains(httpResponse.statusCode) ? "✅" : "⚠️"
            logMessage += " \(statusIcon) Status \(httpResponse.statusCode) from \(response.url?.absoluteString ?? "UNKNOWN_URL")"
            
            if self.logLevel >= .debug {
                if let headers = httpResponse.allHeaderFields as? HTTPHeaders, !headers.isEmpty { // 모든 헤더 필드를 HTTPHeaders로 캐스팅
                    logMessage += "\n    Headers: \(headers.maskingSensitiveHeaders())"
                }
                if let data = data, !data.isEmpty {
                    let dataSummary = summarizeData(data, contentType: httpResponse.value(forHTTPHeaderField: HTTPHeaderField.contentType.rawValue))
                    logMessage += "\n    Data: \(dataSummary)"
                } else {
                    logMessage += (data == nil) ? "\n    Data: (No data)" : "\n    Data: (Empty data: 0 bytes)"
                }
            } else if self.logLevel >= .info, let data = data { // .info 레벨에서는 데이터 크기만 로깅
                logMessage += " (\(data.count) bytes)"
            }
        } else {
            logMessage += " Non-HTTP response from \(response.url?.absoluteString ?? "UNKNOWN_URL") (\(type(of: response)))"
        }
        logger.log(level: level, "\(logMessage)")
    }
    
    public func log(error: Error, level: OSLogType = .error) {
        guard shouldLog(for: level) else { return }
        var logMessage = "\n❌ Error: "
        if let netifyError = error as? NetworkRequestError {
            logMessage += "\(netifyError.localizedDescription)"
            if self.logLevel >= .debug { // 상세 에러 정보는 .debug 레벨에서
                logMessage += "\n    Debug Info: \(netifyError.debugDescription)"
            }
        } else {
            logMessage += "\(error.localizedDescription)"
            if self.logLevel >= .debug {
                logMessage += "\n    Error Type: \(type(of: error))\n    Raw Error: \(error)"
            }
        }
        logger.log(level: level, "\(logMessage)")
    }
    
    /// 지정된 `OSLogType`에 대해 로깅을 수행해야 하는지 여부를 결정합니다.
    private func shouldLog(for targetLevel: OSLogType) -> Bool {
        guard self.logLevel != .off else { return false } // 로깅 꺼져있으면 항상 false
        
        let currentOsLogEquivalent: OSLogType
        switch self.logLevel {
        case .error: currentOsLogEquivalent = .error
        case .info: currentOsLogEquivalent = .info
        case .debug: currentOsLogEquivalent = .debug
        default: return false // .off는 위에서 처리
        }
        // targetLevel이 현재 설정된 로그 레벨보다 같거나 중요할 때만 로깅 (숫자가 클수록 덜 중요)
        return targetLevel.rawValue <= currentOsLogEquivalent.rawValue
    }
    
    // MARK: - 새로운 로깅 메서드들
    
    /// 운영용 간소 로그 (민감정보 자동 마스킹)
    public func logForOperation(_ message: String) {
        guard logLevel >= .info else { return }
        logger.log(level: .info, "[운영] \(sanitizeForOperationString(message))")
    }

    /// 디버깅용 상세 로그 (민감정보 마스킹 + 상세 컨텍스트)
    public func logForDebug(_ message: String) {
        guard logLevel >= .debug else { return }
        logger.log(level: .debug, "[디버그] \(sanitizeForOperationString(message))")
    }
    
    /// 에러의 향상된 디버그 정보 로그
    public func logEnhancedError(_ netifyError: NetifyError) {
        guard logLevel >= .debug else { return }
        let enhancedDescription = netifyError.enhancedDebugDescription
        logger.log(level: .error, "[향상된 에러 정보]\n\(enhancedDescription)")
    }
    
    /// 데이터를 요약하여 문자열로 반환합니다. 너무 길면 잘라냅니다.
    private func summarizeData(_ data: Data, contentType: String?) -> String {
        let maxLen = NetifyInternalConstants.maxLogSummaryLength
        if let contentType = contentType?.lowercased(),
           (contentType.contains("json") || contentType.contains("text") || contentType.contains("xml") || contentType.contains("urlencoded")),
           let stringValue = String(data: data, encoding: .utf8) {
            return stringValue.count > maxLen ? "\(stringValue.prefix(maxLen))... (총 \(data.count) bytes)" : stringValue
        }
        return "<binary data: \(data.count) bytes>"
    }
}

// MARK: - Network Request Error

/// 에러 발생 시점의 요청/응답 컨텍스트 정보를 담는 구조체입니다.
@available(iOS 15, macOS 12, *)
public struct ErrorContext: Sendable, Codable {
    public let url: String?
    public let method: String?
    public let requestHeaders: [String: String]?
    public let requestBody: String? // 민감하지 않은 경우만
    public let responseHeaders: [String: String]?
    public let statusCode: Int?
    public let timestamp: Date
    public let attemptCount: Int
    public let totalDuration: TimeInterval?
    
    public init(
        url: String? = nil,
        method: String? = nil,
        requestHeaders: [String: String]? = nil,
        requestBody: String? = nil,
        responseHeaders: [String: String]? = nil,
        statusCode: Int? = nil,
        attemptCount: Int = 1,
        totalDuration: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.requestHeaders = requestHeaders?.maskingSensitiveHeaders()
        self.requestBody = requestBody
        self.responseHeaders = responseHeaders
        self.statusCode = statusCode
        self.timestamp = Date()
        self.attemptCount = attemptCount
        self.totalDuration = totalDuration
    }
}

/// HTTPHeaders에 민감한 헤더 마스킹 기능을 추가하는 확장입니다.
@available(iOS 15, macOS 12, *)
extension Dictionary where Key == String, Value == String {
    func maskingSensitiveHeaders() -> [String: String] {
        var masked = self
        for (key, _) in self where NetifyInternalConstants.sensitiveHeaderKeys.contains(key.lowercased()) {
            masked[key] = "<masked>"
        }
        return masked
    }
}

/// Netify 에러 포맷터 유틸리티입니다.
@available(iOS 15, macOS 12, *)
public enum NetifyErrorFormatter {
    /// 향상된 디버그 설명을 생성합니다.
    public static func enhanced(kind: NetworkRequestError, context: ErrorContext?) -> String {
        let description = kind.debugDescription
        
        guard let ctx = context else {
            return description + "\n\n[컨텍스트 정보 없음]"
        }
        
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        
        var lines: [String] = []
        lines.append("=== 에러 컨텍스트 정보 ===")
        lines.append("• 시간: \(formatter.string(from: ctx.timestamp))")
        
        if let url = ctx.url { lines.append("• URL: \(url)") }
        if let method = ctx.method { lines.append("• 메서드: \(method)") }
        if let statusCode = ctx.statusCode { lines.append("• 상태 코드: \(statusCode)") }
        lines.append("• 시도 횟수: \(ctx.attemptCount)")
        
        if let duration = ctx.totalDuration {
            lines.append("• 총 소요 시간: \(String(format: "%.3f", duration))초")
        }
        
        if let headers = ctx.requestHeaders, !headers.isEmpty {
            lines.append("• 요청 헤더:")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(key): \(value)")
            }
        }
        
        if let headers = ctx.responseHeaders, !headers.isEmpty {
            lines.append("• 응답 헤더:")
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(key): \(value)")
            }
        }
        
        if let body = ctx.requestBody {
            lines.append("• 요청 본문: \(body)")
        }
        
        return description + "\n\n" + lines.joined(separator: "\n")
    }
}

/// Netify 라이브러리의 통합 에러 타입입니다. 기존 NetworkRequestError를 래핑하고 컨텍스트 정보를 포함합니다.
@available(iOS 15, macOS 12, *)
public struct NetifyError: LocalizedError, CustomDebugStringConvertible, Equatable {
    public let kind: NetworkRequestError
    public let context: ErrorContext?
    
    public init(kind: NetworkRequestError, context: ErrorContext? = nil) {
        self.kind = kind
        self.context = context
    }
    
    // LocalizedError 준수
    public var errorDescription: String? { kind.errorDescription }
    
    // CustomDebugStringConvertible 준수
    public var debugDescription: String { kind.debugDescription }
    
    /// 향상된 디버그 설명 (컨텍스트 정보 포함)
    public var enhancedDebugDescription: String {
        NetifyErrorFormatter.enhanced(kind: kind, context: context)
    }
    
    // Equatable 준수 (컨텍스트는 비교에서 제외)
    public static func == (lhs: NetifyError, rhs: NetifyError) -> Bool {
        return lhs.kind == rhs.kind
    }
    
    // NetworkRequestError의 편의 속성들을 위임
    public var isRetryable: Bool { kind.isRetryable }
    public var retryAfter: TimeInterval? { kind.retryAfter }
}

/// 네트워크 요청 처리 중 발생할 수 있는 다양한 에러 타입을 정의합니다.
@available(iOS 15, macOS 12, *)
public enum NetworkRequestError: LocalizedError, Equatable {
    /// 요청 구성 오류 (URL 생성 실패, 미지원 인코딩 등). 연관값으로 실패 사유(String)를 가집니다.
    case invalidRequest(reason: String)
    /// HTTP 응답이 아니거나 응답 객체 자체가 없는 경우. 연관값으로 원본 `URLResponse` (옵셔널)를 가집니다.
    case invalidResponse(response: URLResponse?)
    /// 400 Bad Request. 연관값으로 응답 데이터(옵셔널 `Data`)를 가집니다.
    case badRequest(data: Data?)
    /// 401 Unauthorized. 연관값으로 응답 데이터(옵셔널 `Data`)를 가집니다.
    case unauthorized(data: Data?)
    /// 403 Forbidden. 연관값으로 응답 데이터(옵셔널 `Data`)를 가집니다.
    case forbidden(data: Data?)
    /// 404 Not Found. 연관값으로 응답 데이터(옵셔널 `Data`)를 가집니다.
    case notFound(data: Data?)
    /// 429 Too Many Requests. 연관값으로 응답 데이터와 Retry-After 값을 가집니다.
    case tooManyRequests(data: Data?, retryAfter: TimeInterval?)
    /// 400번대 기타 클라이언트 에러. 연관값으로 상태 코드(Int), 응답 데이터(옵셔널 `Data`), Retry-After 값을 가집니다.
    case clientError(statusCode: Int, data: Data?, retryAfter: TimeInterval?)
    /// 500번대 서버 에러. 연관값으로 상태 코드(Int), 응답 데이터(옵셔널 `Data`), Retry-After 값을 가집니다.
    case serverError(statusCode: Int, data: Data?, retryAfter: TimeInterval?)
    /// 응답 데이터 디코딩 실패. 연관값으로 원본 디코딩 에러(`Error`)와 디코딩 시도된 데이터(옵셔널 `Data`)를 가집니다.
    case decodingError(underlyingError: Error, data: Data?)
    /// 요청 본문 인코딩 실패. 연관값으로 원본 인코딩 에러(`Error`)를 가집니다.
    case encodingError(underlyingError: Error)
    /// URLSession 레벨 에러 (네트워크 연결 문제 등). 연관값으로 원본 `URLError`를 가집니다.
    case urlSessionFailed(underlyingError: Error) // URLError로 제한하지 않고 일반 Error로 받음
    /// 기타 알 수 없는 에러. 연관값으로 원본 에러(옵셔널 `Error`)를 가집니다.
    case unknownError(underlyingError: Error?)
    /// 사용자 또는 시스템에 의해 요청이 취소됨.
    case cancelled
    /// 요청 시간 초과.
    case timedOut
    /// 인터넷 연결 없음.
    case noInternetConnection
    
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason): return "잘못된 요청: \(reason)"
        case .invalidResponse: return "잘못된 응답 (HTTP 응답이 아니거나 형식이 맞지 않음)"
        case .badRequest: return "잘못된 요청 (400)"
        case .unauthorized: return "인증 실패 (401)"
        case .forbidden: return "접근 금지 (403)"
        case .notFound: return "찾을 수 없음 (404)"
        case .tooManyRequests: return "너무 많은 요청 (429)"
        case .clientError(let code, _, _): return "클라이언트 에러 (\(code))"
        case .serverError(let code, _, _): return "서버 에러 (\(code))"
        case .decodingError(let error, _): return "디코딩 에러: \(error.localizedDescription)"
        case .encodingError(let error): return "인코딩 에러: \(error.localizedDescription)"
        case .urlSessionFailed(let error): return "URLSession 실패: \(error.localizedDescription)"
        case .unknownError(let error): return "알 수 없는 에러: \(error?.localizedDescription ?? "정보 없음")"
        case .cancelled: return "요청 취소됨"
        case .timedOut: return "요청 시간 초과"
        case .noInternetConnection: return "인터넷 연결 없음"
        }
    }
    
    public var debugDescription: String {
        var desc = "\(errorDescription ?? "알 수 없는 에러") (NetifyError.\(String(describing: self).components(separatedBy: "(").first ?? "")))"
        switch self {
        case .invalidRequest(let reason): desc += "\n  사유: \(reason)"
        case .invalidResponse(let resp): desc += "\n  응답 객체: \(String(describing: resp))"
        case .badRequest(let d), .unauthorized(let d), .forbidden(let d), .notFound(let d), .tooManyRequests(let d, _):
            if let data = d, !data.isEmpty { desc += formatDataForDebug(data) }
            else { desc += "\n  응답 데이터: 없음" }
        case .clientError(_, let d, _), .serverError(_, let d, _):
            if let data = d, !data.isEmpty { desc += formatDataForDebug(data) }
            else { desc += "\n  응답 데이터: 없음" }
        case .decodingError(let err, let d):
            desc += "\n  원본 에러: \(err)"
            if let data = d, !data.isEmpty { desc += formatDataForDebug(data, prefix: "디코딩 시도 데이터") }
            else { desc += "\n  디코딩 시도 데이터: 없음"}
        case .encodingError(let err): desc += "\n  원본 에러: \(err)"
        case .urlSessionFailed(let err):
            desc += "\n  원본 에러: \(err)"
            if let urlError = err as? URLError {
                desc += "\n  URLError 코드: \(urlError.code.rawValue), 상세: \(urlError.localizedDescription)"
            }
        case .unknownError(let err):
            if let error = err { desc += "\n  원본 에러: \(error)" }
        default: break // .cancelled, .timedOut, .noInternetConnection는 추가 정보 없음
        }
        return desc
    }
    
    private func formatDataForDebug(_ data: Data, prefix: String = "응답 본문") -> String {
        if let body = String(data: data, encoding: .utf8) {
            let maxLen = NetifyInternalConstants.maxLogSummaryLength
            return "\n  \(prefix): \(body.prefix(maxLen))\(body.count > maxLen ? "..." : "") (총 \(data.count) bytes)"
        } else {
            return "\n  \(prefix) (바이너리 데이터): \(data.count) bytes"
        }
    }
    
    /// 이 에러가 재시도 가능한 유형인지 여부를 반환합니다.
    public var isRetryable: Bool {
        switch self {
        case .serverError: return true // 5xx 서버 에러는 종종 일시적임
        case .tooManyRequests: return true // 429 에러는 재시도 가능 (Retry-After 고려)
        case .timedOut: return true
        case .noInternetConnection: return true // 연결 복구 시 재시도 가능
        case .urlSessionFailed(let error):
            if let urlError = error as? URLError {
                // 재시도 가능한 특정 URLError 코드들
                return [
                    .timedOut, .networkConnectionLost, .notConnectedToInternet,
                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                    .resourceUnavailable, .internationalRoamingOff
                ].contains(urlError.code)
            }
            return false // 일반적인 URLSession 에러는 재시도하지 않음
        default: return false // 클라이언트 에러, 디코딩/인코딩 에러 등은 일반적으로 재시도 불가
        }
    }
    
    /// Retry-After 값을 반환합니다 (있는 경우).
    public var retryAfter: TimeInterval? {
        switch self {
        case .tooManyRequests(_, let retryAfter): return retryAfter
        case .clientError(_, _, let retryAfter): return retryAfter
        case .serverError(_, _, let retryAfter): return retryAfter
        default: return nil
        }
    }
    
    public static func == (lhs: NetworkRequestError, rhs: NetworkRequestError) -> Bool {
        // Equatable 비교 로직 (기존 코드와 동일하게 유지)
        // ... (이 부분은 사용자가 제공한 원래 코드의 Equatable 구현을 그대로 사용합니다) ...
        switch (lhs, rhs) {
        case (.invalidRequest(let l), .invalidRequest(let r)): return l == r
        case (.invalidResponse, .invalidResponse): return true // 데이터 없이 타입만 비교
        case (.badRequest, .badRequest): return true
        case (.unauthorized, .unauthorized): return true
        case (.forbidden, .forbidden): return true
        case (.notFound, .notFound): return true
        case (.tooManyRequests, .tooManyRequests): return true
        case (.clientError(let lc, _, _), .clientError(let rc, _, _)): return lc == rc // 데이터 없이 코드만 비교
        case (.serverError(let lc, _, _), .serverError(let rc, _, _)): return lc == rc // 데이터 없이 코드만 비교
        case (.decodingError(let lhsError, _), .decodingError(let rhsError, _)):
            let lns = lhsError as NSError
            let rns = rhsError as NSError
            return lns.domain == rns.domain && lns.code == rns.code
        case (.encodingError(let lhsError), .encodingError(let rhsError)):
            let lns = lhsError as NSError
            let rns = rhsError as NSError
            return lns.domain == rns.domain && lns.code == rns.code
        case (.urlSessionFailed(let lhsError), .urlSessionFailed(let rhsError)):
            let lns = lhsError as NSError
            let rns = rhsError as NSError
            return lns.domain == rns.domain && lns.code == rns.code
        case (.unknownError(let le), .unknownError(let re)):
            if le == nil && re == nil { return true }
            if let lerr = le as NSError?, let rerr = re as NSError? {
                return lerr.domain == rerr.domain && lerr.code == rerr.code
            }
            return false
        case (.cancelled, .cancelled): return true
        case (.timedOut, .timedOut): return true
        case (.noInternetConnection, .noInternetConnection): return true
        default: return false
        }
    }
}
