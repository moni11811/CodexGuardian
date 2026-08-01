import Darwin
import Foundation
import GuardianCore
import Testing

@Test func silentLocalClientHitsBoundedSocketDeadline() throws {
    var descriptors = [Int32](repeating: -1, count: 2)
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    defer {
        Darwin.close(descriptors[0])
        Darwin.close(descriptors[1])
    }

    let started = Date()
    try GuardianSocketIO.configure(
        descriptor: descriptors[0],
        deadline: started.addingTimeInterval(0.05)
    )
    #expect(throws: GuardianSocketIOError.deadlineExceeded) {
        try GuardianSocketIO.readExactly(1, from: descriptors[0])
    }
    #expect(Date().timeIntervalSince(started) < 0.5)
}
