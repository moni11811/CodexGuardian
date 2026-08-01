import Foundation
import Testing
@testable import GuardianCore

@Test func ipcFrameDecoderHandlesFragmentedAndCoalescedFrames() throws {
    let first = Data("first".utf8)
    let second = Data("second".utf8)
    let encoded = try GuardianIPCFrameCodec.encode(first) + GuardianIPCFrameCodec.encode(second)
    var decoder = GuardianIPCFrameDecoder()

    #expect(try decoder.append(encoded.prefix(3)).isEmpty)
    #expect(try decoder.append(encoded.dropFirst(3).prefix(4)).isEmpty)
    #expect(try decoder.append(encoded.dropFirst(7)) == [first, second])
}

@Test func ipcFrameCodecRejectsOversizedPayloadBeforeAllocation() throws {
    #expect(throws: GuardianIPCFrameError.self) {
        try GuardianIPCFrameCodec.encode(Data(repeating: 0, count: 33), maximumBytes: 32)
    }
    var decoder = GuardianIPCFrameDecoder(maximumBytes: 32)
    let oversizedLength = Data([0, 0, 0, 33])
    #expect(throws: GuardianIPCFrameError.self) {
        try decoder.append(oversizedLength)
    }
}
