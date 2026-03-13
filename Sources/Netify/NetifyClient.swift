import Foundation
import OSLog

// MARK: - Netify Client (Core Logic)

/// 실제 네트워크 요청 실행 및 관리를 담당하는 클라이언트입니다. `NetifyClientProtocol`을 준수합니다.
@available(iOS 15, macOS 12, *)
public final class NetifyClient: NetifyClientProtocol {
    public let configuration: NetifyConfiguration
    private let networkSession: NetworkSessionProtocol // URLSession 대신 프로토콜 사용
    private let logger: NetifyLogging
    private let requestBuilder: RequestBuilder // 내부 RequestBuilder 사용
    private let pluginExecutor: SafePluginExecutor
    private let metricsExecutor: SafeMetricsExecutor
    
    /// Netify 클라이언트를 초기화합니다.
    /// - Parameters:
    ///   - configuration: 클라이언트 동작을 정의하는 설정 객체.
    ///   - networkSession: 네트워크 요청을 처리할 세션 객체 (테스트 목적으로 주입 가능). 기본값은 `configuration`에 기반한 `URLSession`.
    ///   - logger: 로깅을 처리할 로거 객체 (테스트 목적으로 주입 가능). 기본값은 `DefaultNetifyLogger`.
    public init(
        configuration: NetifyConfiguration,
        networkSession: NetworkSessionProtocol? = nil,
        logger: NetifyLogging? = nil // 로거 주입 옵션 추가
    ) {
        self.configuration = configuration
        self.networkSession = networkSession ?? URLSession(configuration: configuration.sessionConfiguration)
        self.logger = logger ?? DefaultNetifyLogger(logLevel: configuration.logLevel) // 주입받거나 기본 로거 사용
        self.requestBuilder = RequestBuilder(configuration: configuration, logger: self.logger) // 빌더에 로거 전달
        self.pluginExecutor = SafePluginExecutor(logger: self.logger, policy: configuration.hookFailurePolicy)
        self.metricsExecutor = SafeMetricsExecutor(logger: self.logger, policy: configuration.hookFailurePolicy)
        
        self.logger.logForOperation("NetifyClient 초기화 완료. BaseURL: \(configuration.baseURL), LogLevel: \(configuration.logLevel)")
    }
    
    /// 특정 `NetifyRequest`를 비동기적으로 보내고 응답을 처리합니다.
    /// 재시도 및 인증 토큰 갱신 로직을 포함합니다.
    public func send<Request: NetifyRequest>(_ request: Request) async throws -> Request.ReturnType {
        try await sendRequestWithRetry(request)
    }
    
    /// 재시도 및 인증 갱신 로직을 포함하여 요청을 처리하는 내부 메소드입니다.
    private func sendRequestWithRetry<Request: NetifyRequest>(_ request: Request) async throws -> Request.ReturnType {
        let requestStartedAt = Date()
        var retryCount = 0
        var attemptCount = 0
        var didRefreshAuthentication = false

        while true {
            try Task.checkCancellation()
            attemptCount += 1

            var urlRequest: URLRequest

            do {
                urlRequest = try await requestBuilder.buildURLRequest(from: request)
                urlRequest = try await pluginExecutor.executeWillSend(plugins: configuration.plugins, request: urlRequest)

                let reqMethod = urlRequest.httpMethod ?? "UNKNOWN_METHOD"
                let reqURL = urlRequest.url?.absoluteString ?? "UNKNOWN_URL"
                logger.logForDebug("➡️ Request: \(reqMethod) \(reqURL)\n    cURL: \(urlRequest.toCurlCommand())")
            } catch {
                let context = makeBuildFailureContext(for: request, attemptCount: attemptCount, startedAt: requestStartedAt)
                let netifyError = mapToNetifyError(error, context: context)
                logger.logForOperation("요청 구성 실패: \(netifyError.localizedDescription)")
                logger.logEnhancedError(netifyError)

                let pluginContext = PluginFailureContext(
                    requestSummary: nil,
                    errorSummary: netifyError.localizedDescription,
                    startedAt: requestStartedAt,
                    attemptCount: attemptCount,
                    targetURL: context.url
                )
                await pluginExecutor.executeDidFail(plugins: configuration.plugins, context: pluginContext)
                throw netifyError
            }

            do {
                var requestForExecution = urlRequest
                var lookupCacheKey: String?
                var cachedResponse: CachedResponse?

                if isCacheEligible(requestForExecution),
                   let responseCache = configuration.responseCache {
                    lookupCacheKey = await cacheKey(for: requestForExecution)

                    if let lookupCacheKey {
                        cachedResponse = await responseCache.getCachedResponse(for: lookupCacheKey)
                    }

                    if let cachedResponse, cachedResponse.isValid {
                        logger.logForOperation("응답 캐시 사용: \(lookupCacheKey ?? requestForExecution.url?.absoluteString ?? "UNKNOWN_URL")")
                        return try handleResponse(
                            response: cachedResponse.response,
                            data: cachedResponse.data,
                            for: request,
                            request: requestForExecution,
                            attemptCount: attemptCount,
                            startedAt: requestStartedAt
                        )
                    }

                    if let cachedResponse, let etag = cachedResponse.etag {
                        requestForExecution.setValue(etag, forHTTPHeaderField: HTTPHeaderField.ifNoneMatch.rawValue)
                    }
                }

                let (data, response) = try await performDataTask(for: requestForExecution)
                let resolvedPayload = try await resolveCachedPayload(
                    request: requestForExecution,
                    response: response,
                    data: data,
                    cachedResponse: cachedResponse,
                    cacheKey: lookupCacheKey
                )

                if let httpResponse = response as? HTTPURLResponse {
                    let status = httpResponse.statusCode
                    let resURL = response.url?.absoluteString ?? "UNKNOWN_URL"
                    logger.logForDebug("⬅️ Response: Status \(status) from \(resURL) (\(data.count) bytes)")
                } else {
                    logger.logForDebug("⬅️ Response: Non-HTTP response (\(type(of: response)))")
                }

                let result = try handleResponse(
                    response: resolvedPayload.response,
                    data: resolvedPayload.data,
                    for: request,
                    request: requestForExecution,
                    attemptCount: attemptCount,
                    startedAt: requestStartedAt
                )

                try await pluginExecutor.executeDidReceive(
                    plugins: configuration.plugins,
                    response: resolvedPayload.response,
                    data: resolvedPayload.data,
                    request: requestForExecution
                )

                if let httpResponse = resolvedPayload.response as? HTTPURLResponse {
                    await storeCachedResponseIfNeeded(
                        for: requestForExecution,
                        response: httpResponse,
                        data: resolvedPayload.data
                    )

                    let duration = Date().timeIntervalSince(requestStartedAt)
                    try await metricsExecutor.recordRequest(
                        metrics: configuration.metrics,
                        url: requestForExecution.url?.absoluteString ?? "",
                        method: requestForExecution.httpMethod ?? "",
                        statusCode: httpResponse.statusCode,
                        duration: duration,
                        responseSize: resolvedPayload.data.count
                    )
                }

                return result
            } catch {
                let context = makeErrorContext(for: urlRequest, attemptCount: attemptCount, startedAt: requestStartedAt)
                let netifyError = mapToNetifyError(error, context: context)
                let duration = Date().timeIntervalSince(requestStartedAt)

                logger.logForOperation("요청 실행 실패: \(netifyError.localizedDescription)")
                logger.logEnhancedError(netifyError)

                let pluginContext = PluginFailureContext(
                    requestSummary: urlRequest.toRequestSummaryForPlugins(),
                    errorSummary: netifyError.localizedDescription,
                    startedAt: requestStartedAt,
                    attemptCount: attemptCount
                )
                await pluginExecutor.executeDidFail(plugins: configuration.plugins, context: pluginContext)

                await metricsExecutor.recordError(
                    metrics: configuration.metrics,
                    url: urlRequest.url?.absoluteString ?? "",
                    method: urlRequest.httpMethod ?? "",
                    error: netifyError,
                    duration: duration
                )

                if request.requiresAuthentication,
                   let authProvider = configuration.authenticationProvider,
                   authProvider.isAuthenticationExpired(from: netifyError) {

                    if didRefreshAuthentication {
                        logger.logForOperation("인증 재시도 한도를 초과하여 더 이상 갱신하지 않음")
                        throw netifyError
                    }

                    logger.logForOperation("인증 만료 감지, 토큰 갱신 시도")
                    logger.logForDebug("인증 만료 세부사항: \(netifyError.localizedDescription)")
                    didRefreshAuthentication = true

                    if await attemptAuthRefresh(using: authProvider) {
                        logger.logForOperation("인증 토큰 갱신 성공, 요청 재시도")
                        continue
                    }

                    logger.logForOperation("인증 토큰 갱신 실패: \(netifyError.localizedDescription)")
                    throw netifyError
                }

                if netifyError.isRetryable && retryCount < configuration.maxRetryCount {
                    if isSafeToRetry(request: urlRequest) {
                        let delaySeconds = await calculateRetryDelay(for: netifyError, attempt: retryCount)
                        retryCount += 1

                        logger.logForOperation("재시도 실행: (\(retryCount)/\(configuration.maxRetryCount)), \(delaySeconds)초 대기")
                        logger.logForDebug("재시도 상세정보: \(netifyError.localizedDescription)")

                        await metricsExecutor.recordRetry(
                            metrics: configuration.metrics,
                            url: urlRequest.url?.absoluteString ?? "",
                            method: urlRequest.httpMethod ?? "",
                            attempt: retryCount,
                            error: netifyError
                        )

                        try Task.checkCancellation()
                        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                        try Task.checkCancellation()
                        continue
                    } else {
                        logger.logForOperation("재시도 생략: 중복 실행 위험이 있는 메서드 \(urlRequest.httpMethod ?? "UNKNOWN_METHOD")")
                    }
                }

                throw netifyError
            }
        }
    }
    
    /// `NetworkSessionProtocol`을 사용하여 실제 데이터 작업을 수행합니다.
    private func performDataTask(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await networkSession.data(for: request, delegate: nil) // URLSessionTaskDelegate는 현재 사용하지 않음
    }

    private func hasMethod(_ request: URLRequest, allowed: Set<String>) -> Bool {
        guard let method = request.httpMethod?.uppercased() else {
            return false
        }
        return allowed.contains(method)
    }

    private func isCacheEligible(_ request: URLRequest) -> Bool {
        hasMethod(request, allowed: [HTTPMethod.get.rawValue, HTTPMethod.head.rawValue])
    }

    private func isSafeToRetry(request: URLRequest) -> Bool {
        hasMethod(
            request,
            allowed: [
                HTTPMethod.get.rawValue,
                HTTPMethod.head.rawValue,
                HTTPMethod.options.rawValue,
            ]
        )
    }

    private func cacheKey(for request: URLRequest) async -> String? {
        guard let url = request.url?.absoluteString else {
            return nil
        }
        guard let varyIndex = configuration.varyIndex else {
            return url
        }

        let varyHeaders = Array(await varyIndex.getVaryHeaders(for: url))
        guard !varyHeaders.isEmpty else {
            return url
        }

        return await varyIndex.generateCacheKey(
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            varyHeaders: varyHeaders
        )
    }

    private func resolveCachedPayload(
        request: URLRequest,
        response: URLResponse,
        data: Data,
        cachedResponse: CachedResponse?,
        cacheKey: String?
    ) async throws -> (data: Data, response: URLResponse) {
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 304,
              let cachedResponse else {
            return (data, response)
        }

        if let responseCache = configuration.responseCache, let cacheKey {
            let refreshedResponse = CachedResponse(
                data: cachedResponse.data,
                response: cachedResponse.response,
                etag: httpResponse.value(forHTTPHeaderField: HTTPHeaderField.eTag.rawValue) ?? cachedResponse.etag,
                maxAge: parseCacheMaxAge(from: httpResponse) ?? cachedResponse.maxAge
            )
            await responseCache.setCachedResponse(refreshedResponse, for: cacheKey)
        }

        logger.logForOperation("ETag 재검증 성공: \(request.url?.absoluteString ?? "UNKNOWN_URL")")
        return (cachedResponse.data, cachedResponse.response)
    }

    private func storeCachedResponseIfNeeded(
        for request: URLRequest,
        response: HTTPURLResponse,
        data: Data
    ) async {
        guard isCacheEligible(request),
              let responseCache = configuration.responseCache,
              let url = request.url?.absoluteString else {
            return
        }

        let varyHeaders = parseVaryHeaders(from: response)
        if let varyIndex = configuration.varyIndex, !varyHeaders.isEmpty {
            await varyIndex.setVaryHeaders(Set(varyHeaders), for: url)
        }

        let storageKey: String
        if let varyIndex = configuration.varyIndex, !varyHeaders.isEmpty {
            storageKey = await varyIndex.generateCacheKey(
                url: url,
                headers: request.allHTTPHeaderFields ?? [:],
                varyHeaders: varyHeaders
            )
        } else {
            storageKey = url
        }

        let maxAge = parseCacheMaxAge(from: response)
        if maxAge == nil && response.value(forHTTPHeaderField: HTTPHeaderField.eTag.rawValue) == nil {
            return
        }

        let cachedResponse = CachedResponse(
            data: data,
            response: response,
            etag: response.value(forHTTPHeaderField: HTTPHeaderField.eTag.rawValue),
            maxAge: maxAge
        )
        await responseCache.setCachedResponse(cachedResponse, for: storageKey)
    }

    private func parseVaryHeaders(from response: HTTPURLResponse) -> [String] {
        guard let varyHeader = response.value(forHTTPHeaderField: "Vary") else {
            return []
        }

        return varyHeader
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0 != "*" }
    }

    private func parseCacheMaxAge(from response: HTTPURLResponse) -> TimeInterval? {
        guard let cacheControl = response.value(forHTTPHeaderField: "Cache-Control") else {
            return nil
        }

        for directive in cacheControl.split(separator: ",") {
            let trimmed = directive.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("max-age="),
               let seconds = TimeInterval(trimmed.replacingOccurrences(of: "max-age=", with: "")) {
                return seconds
            }
        }

        return nil
    }
    
    /// `URLResponse` 및 `Data`를 처리하고, 상태 코드를 검증하며, 데이터를 디코딩합니다.
    /// `NetifyRequest` 정보를 사용하여 적절한 디코더를 선택합니다.
    private func handleResponse<Request: NetifyRequest>(
        response: URLResponse,
        data: Data,
        for netifyRequest: Request,
        request urlRequest: URLRequest,
        attemptCount: Int,
        startedAt: Date
    ) throws -> Request.ReturnType {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetifyError(
                kind: .invalidResponse(response: response),
                context: makeErrorContext(for: urlRequest, response: nil, attemptCount: attemptCount, startedAt: startedAt)
            )
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw mapStatusCodeToError(
                statusCode: httpResponse.statusCode,
                data: data,
                response: httpResponse,
                context: makeErrorContext(for: urlRequest, response: httpResponse, attemptCount: attemptCount, startedAt: startedAt)
            )
        }
        
        if Request.ReturnType.self == Data.self {
            guard let rawData = data as? Request.ReturnType else {
                throw NetifyError(
                    kind: .unknownError(underlyingError: NSError(domain: "Netify.HandleResponse", code: -1004, userInfo: [NSLocalizedDescriptionKey: "Data 객체 캐스팅 실패"])),
                    context: makeErrorContext(for: urlRequest, response: httpResponse, attemptCount: attemptCount, startedAt: startedAt)
                )
            }
            return rawData
        }

        // 성공 응답 (2xx) 처리
        if data.isEmpty {
            if Request.ReturnType.self == EmptyResponse.self {
                guard let empty = EmptyResponse() as? Request.ReturnType else {
                    throw NetifyError(
                        kind: .unknownError(underlyingError: NSError(domain: "Netify.HandleResponse", code: -1001, userInfo: [NSLocalizedDescriptionKey: "EmptyResponse 캐스팅 실패"])),
                        context: makeErrorContext(for: urlRequest, response: httpResponse, attemptCount: attemptCount, startedAt: startedAt)
                    )
                }
                return empty
            } else { // 다른 Decodable 타입을 기대하는데 데이터가 비어있으면 에러 (Data.self는 위에서 이미 처리됨)
                throw NetifyError(
                    kind: .decodingError(underlyingError: NSError(domain: "Netify.HandleResponse", code: -1003, userInfo: [NSLocalizedDescriptionKey: "\(Request.ReturnType.self) 타입을 기대했으나 빈 응답 본문을 받았습니다."]), data: data),
                    context: makeErrorContext(for: urlRequest, response: httpResponse, attemptCount: attemptCount, startedAt: startedAt)
                )
            }
        } else { // 데이터가 있는 경우 디코딩 시도
            do {
                let decoder = netifyRequest.decoder ?? configuration.defaultDecoder // 요청별 디코더 또는 클라이언트 기본 디코더 사용
                return try decoder.decode(Request.ReturnType.self, from: data)
            } catch let decodingError {
                throw NetifyError(
                    kind: .decodingError(underlyingError: decodingError, data: data),
                    context: makeErrorContext(for: urlRequest, response: httpResponse, attemptCount: attemptCount, startedAt: startedAt)
                )
            }
        }
    }
    
    /// 인증 토큰 갱신을 시도하는 헬퍼 함수입니다.
    private func attemptAuthRefresh(using authProvider: AuthenticationProvider) async -> Bool {
        do {
            logger.logForDebug("AuthenticationProvider.refreshAuthentication() 호출 중")
            let success = try await authProvider.refreshAuthentication()
            if success {
                logger.logForOperation("인증 토큰 갱신 완료")
            } else {
                logger.logForOperation("인증 토큰 갱신 실패: 프로바이더가 false 반환")
            }
            return success
        } catch {
            let refreshError = mapToNetifyError(error) // 갱신 중 발생한 에러 매핑
            logger.logForOperation("인증 토큰 갱신 중 예외 발생: \(refreshError.localizedDescription)")
            logger.logEnhancedError(refreshError)
            return false // 갱신 실패
        }
    }

    private func makeBuildFailureContext<Request: NetifyRequest>(
        for request: Request,
        attemptCount: Int,
        startedAt: Date
    ) -> ErrorContext {
        let path = request.path.starts(with: "/") ? request.path : "/" + request.path
        return ErrorContext(
            url: configuration.baseURL + path,
            method: request.method.rawValue,
            requestHeaders: request.headers,
            attemptCount: attemptCount,
            totalDuration: Date().timeIntervalSince(startedAt)
        )
    }

    private func makeErrorContext(
        for request: URLRequest,
        response: HTTPURLResponse? = nil,
        attemptCount: Int,
        startedAt: Date
    ) -> ErrorContext {
        let requestSummary = request.toRequestSummaryForPlugins()
        var responseHeaders: [String: String]? = nil

        if let httpResponse = response, let headerFields = httpResponse.allHeaderFields as? [String: String] {
            responseHeaders = headerFields
        }

        return ErrorContext(
            url: requestSummary.url,
            method: requestSummary.method,
            requestHeaders: requestSummary.headers,
            requestBody: requestSummary.bodyPreview,
            responseHeaders: responseHeaders,
            statusCode: response?.statusCode,
            attemptCount: attemptCount,
            totalDuration: Date().timeIntervalSince(startedAt)
        )
    }
    
    /// 다양한 `Error` 타입을 일관된 `NetifyError`로 매핑합니다.
    private func mapToNetifyError(_ error: Error, context: ErrorContext? = nil) -> NetifyError {
        let kind: NetworkRequestError
        
        switch error {
        case let netifyError as NetworkRequestError: 
            kind = netifyError // 이미 NetworkRequestError인 경우
        case let netifyError as NetifyError:
            if netifyError.context == nil, let context {
                return NetifyError(kind: netifyError.kind, context: context)
            }
            return netifyError
        case let urlError as URLError:
            switch urlError.code {
            case .cancelled: kind = .cancelled
            case .timedOut: kind = .timedOut
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
                    .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .resourceUnavailable,
                    .internationalRoamingOff, .secureConnectionFailed, .serverCertificateHasBadDate,
                    .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                kind = .noInternetConnection // 다양한 연결 관련 문제 그룹화
            default: kind = .urlSessionFailed(underlyingError: urlError)
            }
        case let encodingError as EncodingError: 
            kind = .encodingError(underlyingError: encodingError)
        case let decodingError as DecodingError:
            // handleResponse에서 이미 data와 함께 .decodingError로 래핑하므로, 여기서 data는 nil일 수 있음
            kind = .decodingError(underlyingError: decodingError, data: nil)
        case is CancellationError: 
            kind = .cancelled // Task 취소 에러
        default: 
            kind = .unknownError(underlyingError: error)
        }
        
        return NetifyError(kind: kind, context: context)
    }
    
    /// 재시도 지연 시간을 계산합니다 (지수 백오프 + 지터 + Retry-After 헤더 고려).
    private func calculateRetryDelay(for error: NetifyError, attempt: Int) async -> TimeInterval {
        // 1. Retry-After 헤더가 있으면 우선 사용
        if let retryAfter = error.retryAfter {
            return min(retryAfter, NetifyInternalConstants.maxRetryDelaySeconds)
        }
        
        // 2. 지수 백오프 계산 (기본 지연 시간 * 2^시도횟수)
        let baseDelay = NetifyInternalConstants.defaultRetryDelaySeconds
        let exponentialDelay = baseDelay * pow(NetifyInternalConstants.exponentialBackoffMultiplier, Double(attempt))
        
        // 3. 지터 추가 (0%~25% 랜덤 변동)
        let jitterFactor = 1.0 + (Double.random(in: 0...0.25))
        let delayWithJitter = exponentialDelay * jitterFactor
        
        // 4. 최대 지연 시간 제한
        return min(delayWithJitter, NetifyInternalConstants.maxRetryDelaySeconds)
    }
    
    private static let retryAfterDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(abbreviation: "GMT")
        return f
    }()

    /// HTTP 응답에서 Retry-After 헤더를 파싱합니다.
    private func parseRetryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let retryAfterValue = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(retryAfterValue) {
            return seconds
        }
        if let date = NetifyClient.retryAfterDateFormatter.date(from: retryAfterValue) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }
    
    /// HTTP 상태 코드(2xx 범위 외)를 적절한 `NetifyError`로 매핑합니다.
    private func mapStatusCodeToError(statusCode: Int, data: Data?, response: HTTPURLResponse, context: ErrorContext? = nil) -> NetifyError {
        let retryAfter = parseRetryAfter(from: response)
        
        let kind: NetworkRequestError
        switch statusCode {
        case 400: kind = .badRequest(data: data)
        case 401: kind = .unauthorized(data: data)
        case 403: kind = .forbidden(data: data)
        case 404: kind = .notFound(data: data)
        case 429: kind = .tooManyRequests(data: data, retryAfter: retryAfter)
        case 405...499: kind = .clientError(statusCode: statusCode, data: data, retryAfter: retryAfter) // 기타 4xx 에러
        case 500...599: kind = .serverError(statusCode: statusCode, data: data, retryAfter: retryAfter) // 모든 5xx 에러
        default: // 예상치 못한 상태 코드 (예: 1xx, 3xx - 3xx는 URLSession에서 자동 처리되는 경우가 많음)
            logger.logForOperation("처리되지 않은 HTTP 상태 코드 수신: \(statusCode)")
            kind = .unknownError(underlyingError: NSError(domain: "Netify.StatusCodeMapping", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "처리되지 않은 HTTP 상태 코드: \(statusCode)"]))
        }
        
        return NetifyError(kind: kind, context: context)
    }
}

// MARK: - Request Builder (Internal Helper)

/// `URLRequest` 생성을 담당하는 내부 헬퍼 클래스/구조체입니다.
/// `NetifyConfiguration`과 `NetifyLogging`을 주입받아 사용합니다.
@available(iOS 15, macOS 12, *)
internal struct RequestBuilder {
    let configuration: NetifyConfiguration
    let logger: NetifyLogging
    
    /// `NetifyRequest`로부터 `URLRequest`를 빌드합니다.
    /// URL 구성, 쿼리 파라미터, 헤더, 본문 인코딩, 인증 처리를 담당합니다.
    func buildURLRequest<Request: NetifyRequest>(from netifyRequest: Request) async throws -> URLRequest {
        // 1. 최종 URL 구성 (경로 + 쿼리 파라미터)
        let url = try buildFinalURL(for: netifyRequest)
        
        // 2. URLRequest 초기화 및 기본 속성 설정
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = netifyRequest.method.rawValue
        urlRequest.timeoutInterval = netifyRequest.timeoutInterval ?? configuration.timeoutInterval // 요청별 설정 우선
        urlRequest.cachePolicy = netifyRequest.cachePolicy ?? configuration.cachePolicy // 요청별 설정 우선
        
        // 3. 헤더 준비 (클라이언트 기본 헤더 + 요청별 헤더)
        var headers = configuration.defaultHeaders // 기본 헤더로 시작
        netifyRequest.headers?.forEach { headers[$0.key] = $0.value } // 요청별 헤더가 기본 헤더 덮어씀
        
        // 4. 본문 및 Content-Type 헤더 준비
        if let body = netifyRequest.body {
            try encodeAndSetBody(&urlRequest, body: body, headers: &headers)
        }
        // body가 nil이면 아무것도 하지 않음 (예: GET 요청)
        
        // 5. 최종 헤더 설정
        if !headers.isEmpty {
            urlRequest.allHTTPHeaderFields = headers
        }
        
        // 6. 인증 처리 (모든 헤더와 본문 설정 후 마지막에 적용)
        if netifyRequest.requiresAuthentication, let authProvider = configuration.authenticationProvider {
            do {
                urlRequest = try await authProvider.authenticate(request: urlRequest)
            } catch {
                throw mapAuthenticationError(error) // 인증 과정 자체의 에러 매핑
            }
        }
        return urlRequest
    }
    
    /// 경로와 쿼리 파라미터를 포함한 최종 URL을 빌드하는 헬퍼 함수.
    private func buildFinalURL<Request: NetifyRequest>(for netifyRequest: Request) throws -> URL {
        let baseURL = configuration.baseURL
        let path = netifyRequest.path // NetifyRequest에서 제공된 경로 (예: /users/{id})
        
        // URLPathBuilder를 사용하여 baseURL과 path 결합
        let initialURL = try URLPathBuilder.buildURL(baseURL: baseURL, path: path)
        
        // 쿼리 파라미터 추가 (있는 경우)
        guard let queryParams = netifyRequest.queryParams, !queryParams.isEmpty else {
            return initialURL // 쿼리 파라미터 없으면 바로 반환
        }
        
        guard var components = URLComponents(url: initialURL, resolvingAgainstBaseURL: false) else {
            throw NetworkRequestError.invalidRequest(reason: "URLComponents 생성 실패: \(initialURL)")
        }
        
        var queryItems = components.queryItems ?? []
        // NetifyRequest의 queryParams ([String: String])를 URLQueryItem 배열로 변환하여 추가
        queryItems.append(contentsOf: queryParams.map { URLQueryItem(name: $0.key, value: $0.value) })
        
        if !queryItems.isEmpty { components.queryItems = queryItems }
        
        guard let finalURL = components.url else {
            throw NetworkRequestError.invalidRequest(reason: "쿼리 파라미터를 포함한 최종 URL 생성 실패 (경로: \(path))")
        }
        return finalURL
    }
    
    /// RequestBody에 따라 본문을 인코딩하고 요청에 설정하는 헬퍼 함수.
    private func encodeAndSetBody(_ urlRequest: inout URLRequest, body: RequestBody, headers: inout HTTPHeaders) throws {
        do {
            switch body {
            case .json(let encodableBody):
                urlRequest.httpBody = try configuration.defaultEncoder.encode(encodableBody)
            case .form(let paramsBody):
                urlRequest.httpBody = paramsBody.toUrlEncodedQueryString()?.data(using: .utf8)
            case .text(let stringBody), .xml(let stringBody):
                urlRequest.httpBody = stringBody.data(using: .utf8)
            case .data(let dataBody, _):
                urlRequest.httpBody = dataBody
            case .multipart(let parts):
                let boundary = "Boundary-\(UUID().uuidString)"
                headers[HTTPHeaderField.contentType.rawValue] = "\(HTTPContentType.multipart.rawValue); boundary=\(boundary)"
                urlRequest.httpBody = buildMultipartBody(parts: parts, boundary: boundary)
            }
            
            let contentType = body.resolvedContentType
            if headers[HTTPHeaderField.contentType.rawValue] == nil {
                headers[HTTPHeaderField.contentType.rawValue] = contentType.rawValue
            } else if headers[HTTPHeaderField.contentType.rawValue] != contentType.rawValue && contentType != .multipart {
                logger.logForOperation("경고: 요청 헤더에 Content-Type ('\(headers[HTTPHeaderField.contentType.rawValue] ?? "")')이 명시되었으나, body 타입에 따른 Content-Type ('\(contentType.rawValue)')과 다를 수 있습니다. '\(contentType.rawValue)'를 사용합니다.")
                headers[HTTPHeaderField.contentType.rawValue] = contentType.rawValue
            }
        } catch let error as NetworkRequestError {
            throw error
        } catch {
            throw NetworkRequestError.encodingError(underlyingError: error)
        }
    }
    
    /// 멀티파트 요청 본문을 구성합니다.
    private func buildMultipartBody(parts: [MultipartData], boundary: String) -> Data {
        let body = NSMutableData()
        for part in parts {
            body.append(part.buildHttpBodyPart(boundary: boundary)) // 각 파트 데이터 추가
        }
        body.appendString("--\(boundary)--\r\n") // 전체 본문의 끝을 알리는 최종 경계
        return body as Data
    }
    
    /// `AuthenticationProvider.authenticate`에서 발생할 수 있는 에러를 매핑합니다.
    private func mapAuthenticationError(_ error: Error) -> NetworkRequestError {
        if let netifyError = error as? NetworkRequestError { // 인증 프로바이더가 NetifyError를 throw한 경우
            return netifyError
        } else { // 그 외 에러는 알 수 없는 인증 관련 문제로 처리
            logger.logForOperation("인증 프로바이더 실행 중 알 수 없는 에러 발생: \(error.localizedDescription)")
            return .unknownError(underlyingError: error)
        }
    }
}
