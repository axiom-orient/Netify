# Netify

Swift async/await 기반 네트워킹 라이브러리. 간단한 API, 안전한 로깅(민감정보 마스킹), 재시도·인증·플러그인 지원.

## 설치

- Xcode: File > Add Packages... > `https://github.com/AidenJLee/Netify.git`
- Package.swift:

```swift
// Package.swift
dependencies: [
  .package(url: "https://github.com/AidenJLee/Netify.git", from: "1.1.2"),
]
targets: [
  .target(
    name: "YourApp",
    dependencies: [ .product(name: "Netify", package: "Netify") ]
  )
]
```

현재 문서의 저장소 기준은 로컬 `git origin`인 `AidenJLee/Netify`입니다. 배포 저장소가 바뀌면 이 섹션과 CI 기준을 함께 바꾸세요.

`NetifyExamples` 실행 타깃은 배포용 API가 아니라 학습용 샘플입니다. 앱에서 라이브러리를 쓸 때는 `Netify` 제품만 연결하면 됩니다.

## 빠른 시작

```swift
import Netify

// 1) 클라이언트 생성
let config = NetifyConfiguration(
  baseURL: "https://api.example.com",
  logLevel: .info,          // .debug로 상세 로그(마스킹 적용)
  maxRetryCount: 1          // 기본값도 1, 안전한 메서드만 자동 재시도
)
let client = NetifyClient(configuration: config)

// 2) 요청 정의
struct User: Codable { let id: Int; let name: String }

struct GetUser: NetifyRequest {
  typealias ReturnType = User
  let id: Int
  var path: String { "/users/\(id)" }
  // method = .get 기본값 사용
}

// 3) 호출
let user = try await client.send(GetUser(id: 1))
```

## 자주 쓰는 패턴

응답 처리는 JSON 중심입니다. 성공 응답은 `EmptyResponse`, `Data`, 또는 `Decodable` JSON 모델로 받는 흐름을 기준으로 설계되어 있습니다.

- 쿼리/헤더/타임아웃

```swift
struct SearchPosts: NetifyRequest {
  typealias ReturnType = [Post]
  var path: String { "/posts" }
  var queryParams: QueryParameters? { ["q": keyword, "limit": String(limit)] }
  var headers: HTTPHeaders? { ["X-Trace-ID": traceId] }
  var timeoutInterval: TimeInterval? { 10 }
  let keyword: String; let limit: Int; let traceId: String
}
```

- POST: Encodable 본문

```swift
struct CreatePost: NetifyRequest {
  typealias ReturnType = Post
  let path = "/posts"; let method: HTTPMethod = .post
  let payload: NewPost
  var body: RequestBody? { .json(AnyEncodable(payload)) }
  struct NewPost: Encodable { let title: String; let body: String; let userId: Int }
}

let created = try await client.send(CreatePost(payload: .init(title: "Hi", body: "Hello", userId: 1)))
```

- 멀티파트 업로드

```swift
struct UploadImage: NetifyRequest {
  typealias ReturnType = EmptyResponse
  let path = "/upload"; let method: HTTPMethod = .post
  let parts: [MultipartData]
  var body: RequestBody? { .multipart(parts) }
}
```

## 기능 요약(간단)

- 재시도: 기본값 1회, `GET/HEAD/OPTIONS` 같은 안전한 메서드만 자동 재시도
- 취소: 재시도 대기 전후 `Task.checkCancellation()`
- 인증: `AuthenticationProvider`로 토큰 주입/갱신(Bearer 지원)
- 로깅: `logLevel`로 제어(.error/.info/.debug). 민감정보는 항상 마스킹
- 플러그인: 요청 전/후/실패 훅 제공. 실패 컨텍스트는 요약본만 노출(`errorSummary`, `requestSummary`)
- 훅 정책: 기본은 `.ignore`, `hookFailurePolicy: .propagate`로 성공 경로 훅 실패를 요청 실패로 올릴 수 있음

## 예제

- `BasicGetExample`: 가장 작은 GET 요청
- `AuthExample`: Bearer 인증 헤더 주입
- `MultipartExample`: 멀티파트 업로드

```swift
struct MyPlugin: NetifyPlugin {
  func willSend(request: URLRequest) async throws -> URLRequest { request }
  func didReceive(response: URLResponse, data: Data, for request: URLRequest) async throws {}
  func didFail(with context: PluginFailureContext) async throws {
    print(context.errorSummary)
    if let s = context.requestSummary { print(s.method ?? "?", s.url ?? "?") }
  }
}
```

## 로깅 팁

```swift
let config = NetifyConfiguration(baseURL: "…", logLevel: .debug)
let client = NetifyClient(configuration: config)
// 라이브러리 내부에서 민감정보는 자동 마스킹됩니다.
```

## 라이선스

MIT
