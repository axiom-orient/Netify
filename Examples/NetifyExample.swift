import Foundation

@main
struct NetifyExamplesApp {
    static func main() async {
        await runBasicGetExample()
        await runAuthExample()
        await runMultipartExample()
    }
}
