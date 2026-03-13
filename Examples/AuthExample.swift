import Foundation
import Netify

@available(iOS 15, macOS 12, *)
func runAuthExample() async {
    let auth = BearerTokenAuthenticationProvider(
        accessToken: "demo-token",
        refreshToken: "demo-refresh-token",
        refreshHandler: { _ in
            .init(accessToken: "refreshed-demo-token")
        }
    )

    let client = NetifyClient(
        configuration: NetifyConfiguration(
            baseURL: "https://httpbin.org",
            logLevel: .info,
            authenticationProvider: auth
        )
    )

    let request = Netify.get(expecting: HttpBinAnythingResponse.self)
        .path("/anything/auth-demo")

    do {
        let response = try await client.send(request)
        let authorization = response.headers["Authorization"] ?? "<missing>"
        print("AuthExample:", authorization)
    } catch {
        print("AuthExample failed:", error)
    }
}
