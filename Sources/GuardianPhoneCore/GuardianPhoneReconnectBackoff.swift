import Foundation
import Network

public enum PhoneReconnectBackoffError: Error, Equatable, Sendable {
    case invalidConfiguration
}

public enum PhoneReconnectFailureDisposition: Equatable, Sendable {
    case retry
    case requiresPairing
    case stop
}

public struct PhoneReconnectFailureClassifier: Sendable {
    public init() {}

    public func disposition(
        for error: any Error
    ) -> PhoneReconnectFailureDisposition {
        if error is CancellationError { return .stop }
        if let error = error as? PhonePinnedTLSExchangeError {
            switch error {
            case .connectionClosed, .timedOut:
                return .retry
            case .invalidEndpoint, .invalidTimeout, .invalidFrame, .oversizedFrame:
                return .stop
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .networkConnectionLost, .dnsLookupFailed,
                 .notConnectedToInternet, .internationalRoamingOff,
                 .callIsActive, .dataNotAllowed:
                return .retry
            default:
                return .stop
            }
        }
        if let error = error as? NWError {
            switch error {
            case let .posix(code):
                switch code {
                case .ECONNABORTED, .ECONNREFUSED, .ECONNRESET,
                     .EHOSTDOWN, .EHOSTUNREACH, .ENETDOWN, .ENETRESET,
                     .ENETUNREACH, .ENOTCONN, .EPIPE, .ETIMEDOUT:
                    return .retry
                default:
                    return .stop
                }
            case .dns:
                return .retry
            case .tls:
                return .stop
            default:
                return .stop
            }
        }
        if let error = error as? PhoneRemoteClientError,
           error == .notPaired {
            return .requiresPairing
        }
        if let error = error as? PhoneRemoteOperationalCodecError,
           error == .rejected("serverUnavailable") {
            return .retry
        }
        return .stop
    }
}

public struct PhoneReconnectBackoff: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let connectedRefreshDelay: TimeInterval
    public private(set) var consecutiveFailures: Int

    public init(
        initialDelay: TimeInterval,
        maximumDelay: TimeInterval,
        connectedRefreshDelay: TimeInterval
    ) throws {
        guard initialDelay.isFinite,
              maximumDelay.isFinite,
              connectedRefreshDelay.isFinite,
              initialDelay > 0,
              maximumDelay >= initialDelay,
              connectedRefreshDelay > 0 else {
            throw PhoneReconnectBackoffError.invalidConfiguration
        }
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.connectedRefreshDelay = connectedRefreshDelay
        consecutiveFailures = 0
    }

    public static var standard: PhoneReconnectBackoff {
        PhoneReconnectBackoff(
            uncheckedInitialDelay: 1,
            maximumDelay: 30,
            connectedRefreshDelay: 5
        )
    }

    public mutating func delayAfterFailure() -> TimeInterval {
        consecutiveFailures = min(consecutiveFailures + 1, 63)
        var delay = initialDelay
        if consecutiveFailures > 1 {
            for _ in 1..<consecutiveFailures {
                guard delay < maximumDelay else { return maximumDelay }
                guard delay <= maximumDelay / 2 else { return maximumDelay }
                delay *= 2
            }
        }
        return min(delay, maximumDelay)
    }

    public mutating func delayAfterSuccess() -> TimeInterval {
        consecutiveFailures = 0
        return connectedRefreshDelay
    }

    private init(
        uncheckedInitialDelay: TimeInterval,
        maximumDelay: TimeInterval,
        connectedRefreshDelay: TimeInterval
    ) {
        initialDelay = uncheckedInitialDelay
        self.maximumDelay = maximumDelay
        self.connectedRefreshDelay = connectedRefreshDelay
        consecutiveFailures = 0
    }
}
