import Darwin
import Foundation

public struct GuardianRemoteServiceConfiguration: Codable, Equatable, Sendable {
    public let listener: GuardianRemoteListenerConfiguration
    public let identityLabel: String?
    public let rateLimitPolicy: GuardianRemoteRateLimitPolicy

    public init(
        listener: GuardianRemoteListenerConfiguration,
        identityLabel: String?,
        rateLimitPolicy: GuardianRemoteRateLimitPolicy
    ) {
        self.listener = listener
        self.identityLabel = identityLabel
        self.rateLimitPolicy = rateLimitPolicy
    }

    public static let disabled = GuardianRemoteServiceConfiguration(
        listener: .disabled,
        identityLabel: nil,
        rateLimitPolicy: .productionDefault
    )

    public var validation: GuardianRemoteServiceConfigurationValidation {
        switch GuardianRemoteListenerPolicy().evaluate(listener) {
        case .disabled:
            return identityLabel == nil ? .disabled : .rejected(.identityUnexpected)
        case let .rejected(reason):
            return .rejected(.listener(reason))
        case .allowed:
            break
        }
        guard let identityLabel else {
            return .rejected(.identityLabelRequired)
        }
        let trimmed = identityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == identityLabel,
              trimmed.utf8.count <= 256 else {
            return .rejected(.invalidIdentityLabel)
        }
        guard rateLimitPolicy.isValid else {
            return .rejected(.invalidRateLimitPolicy)
        }
        return .allowed
    }
}

public enum GuardianRemoteServiceConfigurationRejection: Codable, Equatable, Sendable {
    case listener(GuardianRemoteListenerRejection)
    case identityUnexpected
    case identityLabelRequired
    case invalidIdentityLabel
    case invalidRateLimitPolicy
}

public enum GuardianRemoteServiceConfigurationValidation: Codable, Equatable, Sendable {
    case disabled
    case allowed
    case rejected(GuardianRemoteServiceConfigurationRejection)
}

public enum GuardianRemoteConfigurationFileError: Error, Equatable, Sendable {
    case untrustedFile
    case invalidLength
    case invalidData
    case invalidConfiguration(GuardianRemoteServiceConfigurationRejection)
    case systemCall(String, Int32)
}

public enum GuardianRemoteConfigurationFile {
    public static let maximumBytes = 64 * 1_024

    public static func loadIfPresent(at url: URL) throws -> GuardianRemoteServiceConfiguration {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .disabled }
            if errno == ELOOP { throw GuardianRemoteConfigurationFileError.untrustedFile }
            throw GuardianRemoteConfigurationFileError.systemCall("open", errno)
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw GuardianRemoteConfigurationFileError.systemCall("fstat", errno)
        }
        guard status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o077 == 0 else {
            throw GuardianRemoteConfigurationFileError.untrustedFile
        }
        guard status.st_size > 0,
              status.st_size <= maximumBytes else {
            throw GuardianRemoteConfigurationFileError.invalidLength
        }

        let length = Int(status.st_size)
        var data = Data(count: length)
        var offset = 0
        try data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw GuardianRemoteConfigurationFileError.invalidLength
            }
            while offset < length {
                let count = Darwin.read(descriptor, base.advanced(by: offset), length - offset)
                if count == 0 { throw GuardianRemoteConfigurationFileError.invalidLength }
                guard count > 0 else {
                    if errno == EINTR { continue }
                    throw GuardianRemoteConfigurationFileError.systemCall("read", errno)
                }
                offset += count
            }
        }

        let configuration: GuardianRemoteServiceConfiguration
        do {
            configuration = try JSONDecoder().decode(
                GuardianRemoteServiceConfiguration.self,
                from: data
            )
        } catch {
            throw GuardianRemoteConfigurationFileError.invalidData
        }
        switch configuration.validation {
        case .disabled, .allowed:
            return configuration
        case let .rejected(reason):
            throw GuardianRemoteConfigurationFileError.invalidConfiguration(reason)
        }
    }
}
