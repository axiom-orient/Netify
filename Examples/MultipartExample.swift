import Foundation
import Netify

@available(iOS 15, macOS 12, *)
func runMultipartExample() async {
    let fileData = Data("hello from netify".utf8)

    let client = NetifyClient(
        configuration: NetifyConfiguration(
            baseURL: "https://httpbin.org",
            logLevel: .info
        )
    )

    let request = Netify.post(expecting: HttpBinMultipartResponse.self)
        .path("/post")
        .multipart([
            MultipartData(
                name: "file",
                fileData: fileData,
                fileName: "hello.txt",
                mimeType: "text/plain"
            )
        ])
        .authentication(required: false)

    do {
        let response = try await client.send(request)
        print("MultipartExample:", response.files["file"] ?? "<missing>")
    } catch {
        print("MultipartExample failed:", error)
    }
}
