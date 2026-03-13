import Foundation
import Netify

struct ExamplePost: Codable {
    let id: Int
    let userId: Int
    let title: String
    let body: String
}

struct HttpBinAnythingResponse: Codable {
    let url: String
    let headers: [String: String]
}

struct HttpBinMultipartResponse: Codable {
    let files: [String: String]
    let headers: [String: String]
}
