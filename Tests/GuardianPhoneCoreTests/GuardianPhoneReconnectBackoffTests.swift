import Foundation
import Testing
@testable import GuardianPhoneCore

@Suite("Guardian phone reconnect backoff")
struct GuardianPhoneReconnectBackoffTests {
    @Test("transient failures back off, cap, and reset after success")
    func failuresBackOffAndReset() throws {
        var backoff = try PhoneReconnectBackoff(
            initialDelay: 1,
            maximumDelay: 4,
            connectedRefreshDelay: 10
        )

        #expect(backoff.delayAfterFailure() == 1)
        #expect(backoff.delayAfterFailure() == 2)
        #expect(backoff.delayAfterFailure() == 4)
        #expect(backoff.delayAfterFailure() == 4)
        #expect(backoff.delayAfterSuccess() == 10)
        #expect(backoff.delayAfterFailure() == 1)
    }

    @Test("invalid reconnect timing fails closed")
    func invalidTimingRejected() {
        #expect(throws: PhoneReconnectBackoffError.invalidConfiguration) {
            _ = try PhoneReconnectBackoff(
                initialDelay: 0,
                maximumDelay: 4,
                connectedRefreshDelay: 10
            )
        }
    }

    @Test("only transient transport failures are retryable")
    func deterministicFailuresStop() {
        let classifier = PhoneReconnectFailureClassifier()

        #expect(classifier.disposition(for: URLError(.networkConnectionLost)) == .retry)
        #expect(classifier.disposition(for: PhonePinnedTLSExchangeError.timedOut) == .retry)
        #expect(classifier.disposition(for: PhonePinnedTLSExchangeError.invalidFrame) == .stop)
        #expect(classifier.disposition(for: PhoneSecureStorageError.invalidData) == .stop)
        #expect(classifier.disposition(for: PhoneRemoteClientError.notPaired) == .requiresPairing)
        #expect(classifier.disposition(
            for: PhoneRemoteOperationalCodecError.payloadDigestMismatch
        ) == .stop)
    }
}
