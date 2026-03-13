import Foundation
import Netify

@available(iOS 15, macOS 12, *)
func runBasicGetExample() async {
    let client = NetifyClient(
        configuration: NetifyConfiguration(
            baseURL: "https://jsonplaceholder.typicode.com",
            logLevel: .info
        )
    )

    let request = Netify.get(expecting: ExamplePost.self)
        .path("/posts/{id}")
        .pathArgument("id", 1)
        .authentication(required: false)

    do {
        let post = try await client.send(request)
        print("BasicGetExample:", post.id, post.title)
    } catch {
        print("BasicGetExample failed:", error)
    }
}
