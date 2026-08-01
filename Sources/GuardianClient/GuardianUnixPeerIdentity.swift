import Darwin
import Foundation

public struct GuardianUnixPeerIdentity: Equatable, Sendable {
    public let processID: pid_t
    public let executablePath: String

    public static func inspect(descriptor: Int32) throws -> GuardianUnixPeerIdentity {
        var processID = pid_t()
        var processIDLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(
            descriptor,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &processID,
            &processIDLength
        ) == 0,
        processID > 0 else {
            throw GuardianUnixSocketError.untrustedPeer
        }

        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { throw GuardianUnixSocketError.untrustedPeer }
        let executablePath = String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return GuardianUnixPeerIdentity(
            processID: processID,
            executablePath: canonicalPath(executablePath)
        )
    }

    public static func verify(
        descriptor: Int32,
        expectedExecutablePath: String
    ) throws {
        let peer = try inspect(descriptor: descriptor)
        guard !expectedExecutablePath.isEmpty,
              peer.executablePath == canonicalPath(expectedExecutablePath) else {
            throw GuardianUnixSocketError.untrustedPeer
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }
}
