import Foundation
import Testing
@testable import GuardianCore

@Test func originTokenSelectsExactCallingThread() throws {
    let sessions = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let wrongID = "019f0000-0000-7000-8000-000000000001"
    let rightID = "019f0000-0000-7000-8000-000000000002"
    let originMarker = "7BBD258F-5BA6-4B2E-BC25-044C252B21A8"
    try rollout(id: wrongID, body: "another restart", in: sessions, name: "wrong")
    try rollout(id: rightID, body: "restart origin \(originMarker)", in: sessions, name: "right")

    let resolver = ThreadOriginResolver(sessionsRoot: sessions)

    #expect(try resolver.resolve(originToken: originMarker) == rightID)
}

private func rollout(id: String, body: String, in directory: URL, name: String) throws {
    let meta = #"{"type":"session_meta","payload":{"id":"\#(id)","session_id":"\#(id)"}}"#
    let event = #"{"type":"response_item","payload":{"arguments":"\#(body)"}}"#
    try Data("\(meta)\n\(event)\n".utf8).write(to: directory.appending(path: "\(name).jsonl"))
}
