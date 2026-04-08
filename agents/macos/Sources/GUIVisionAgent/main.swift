import Foundation
import Hummingbird

let port = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 8648

let router = buildAgentRouter()
let app = Application(
    router: router,
    configuration: .init(address: .hostname("0.0.0.0", port: port))
)

try await app.runService()
