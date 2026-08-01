import Darwin
import Foundation

public enum GuardianCredentialFileError: Error, Equatable, Sendable {
    case untrustedFile
    case invalidLength
    case systemCall(String, Int32)
}

public enum GuardianCredentialFile {
    public static let byteCount = 32

    public static func load(at url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw GuardianCredentialFileError.untrustedFile }
            throw GuardianCredentialFileError.systemCall("open", errno)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw GuardianCredentialFileError.systemCall("fstat", errno)
        }
        guard status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o077 == 0 else {
            throw GuardianCredentialFileError.untrustedFile
        }
        guard status.st_size == byteCount else {
            throw GuardianCredentialFileError.invalidLength
        }

        var credential = Data(count: byteCount)
        var offset = 0
        try credential.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            while offset < byteCount {
                let count = Darwin.read(
                    descriptor,
                    base.advanced(by: offset),
                    byteCount - offset
                )
                if count == 0 { throw GuardianCredentialFileError.invalidLength }
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw GuardianCredentialFileError.systemCall("read", errno)
                }
                offset += count
            }
        }
        return credential
    }
}
