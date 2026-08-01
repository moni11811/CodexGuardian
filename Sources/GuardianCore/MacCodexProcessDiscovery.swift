#if os(macOS)
import AppKit
import CoreServices
import Darwin
import Foundation
import Security

public enum MacCodexProcessDiscoveryError: Error, Equatable, Sendable {
    case launchServicesFailure
    case invalidApplicationURL
    case bundleMetadataUnavailable
    case codeObjectUnavailable
    case invalidCodeSignature
    case signingInformationUnavailable
    case processIdentityUnavailable
}

public struct MacCodexProcessDiscovery: CodexProcessDiscovering {
    public init() {}

    public func applicationCandidates(
        bundleIdentifier: String
    ) throws -> [CodexApplicationCandidate] {
        var unmanagedError: Unmanaged<CFError>?
        guard let unmanagedURLs = LSCopyApplicationURLsForBundleIdentifier(
            bundleIdentifier as CFString,
            &unmanagedError
        ) else {
            if unmanagedError != nil {
                throw MacCodexProcessDiscoveryError.launchServicesFailure
            }
            return []
        }

        let rawValues = unmanagedURLs.takeRetainedValue() as NSArray
        let urls = rawValues.compactMap { $0 as? URL }
        guard urls.count == rawValues.count else {
            throw MacCodexProcessDiscoveryError.invalidApplicationURL
        }
        return try Array(Set(urls.map(applicationIdentity(at:))))
            .sorted { $0.bundleURLPath < $1.bundleURLPath }
    }

    public func runningProcessCandidates(
        bundleIdentifier: String
    ) throws -> [CodexRunningProcessCandidate] {
        try NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).map { application in
            guard !application.isTerminated,
                  application.processIdentifier > 0,
                  let bundleURL = application.bundleURL else {
                throw MacCodexProcessDiscoveryError.processIdentityUnavailable
            }
            return CodexRunningProcessCandidate(
                application: try applicationIdentity(at: bundleURL),
                processID: application.processIdentifier,
                processStartIdentity: try processStartIdentity(
                    processID: application.processIdentifier
                )
            )
        }
    }

    public func terminate(processID: Int32, force: Bool) -> Bool {
        guard processID > 0,
              let application = NSRunningApplication(
                processIdentifier: processID
              ),
              !application.isTerminated else {
            return false
        }
        return force ? application.forceTerminate() : application.terminate()
    }

    public func launch(applicationPath: String) -> Bool {
        guard applicationPath.hasPrefix("/") else { return false }
        return NSWorkspace.shared.open(URL(fileURLWithPath: applicationPath))
    }

    public func applicationIdentity(
        at applicationURL: URL
    ) throws -> CodexApplicationCandidate {
        let canonicalURL = applicationURL.standardizedFileURL
            .resolvingSymlinksInPath()
        guard canonicalURL.isFileURL,
              canonicalURL.path.hasPrefix("/"),
              let bundleIdentifier = Bundle(url: canonicalURL)?.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            throw MacCodexProcessDiscoveryError.bundleMetadataUnavailable
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            canonicalURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            throw MacCodexProcessDiscoveryError.codeObjectUnavailable
        }
        let strictValidation = SecCSFlags(rawValue: 1 << 4)
        guard SecStaticCodeCheckValidity(
            staticCode,
            strictValidation,
            nil
        ) == errSecSuccess else {
            throw MacCodexProcessDiscoveryError.invalidCodeSignature
        }

        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: 1 << 1),
            &signingInformation
        ) == errSecSuccess,
        let information = signingInformation as? [String: Any],
        let signingIdentifier = information[
            kSecCodeInfoIdentifier as String
        ] as? String,
        !signingIdentifier.isEmpty,
        let teamIdentifier = information[
            kSecCodeInfoTeamIdentifier as String
        ] as? String,
        !teamIdentifier.isEmpty else {
            throw MacCodexProcessDiscoveryError.signingInformationUnavailable
        }

        return CodexApplicationCandidate(
            bundleIdentifier: bundleIdentifier,
            bundleURLPath: canonicalURL.path,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier
        )
    }

    public func processStartIdentity(processID: Int32) throws -> UInt64 {
        guard processID > 0 else {
            throw MacCodexProcessDiscoveryError.processIdentityUnavailable
        }
        var information = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let actualSize = proc_pidinfo(
            processID,
            PROC_PIDTBSDINFO,
            0,
            &information,
            expectedSize
        )
        guard actualSize == expectedSize,
              information.pbi_start_tvsec > 0,
              information.pbi_start_tvusec >= 0 else {
            throw MacCodexProcessDiscoveryError.processIdentityUnavailable
        }

        let seconds = UInt64(information.pbi_start_tvsec)
        let microseconds = UInt64(information.pbi_start_tvusec)
        let (scaledSeconds, overflowedSeconds) = seconds.multipliedReportingOverflow(
            by: 1_000_000
        )
        let (identity, overflowedAddition) = scaledSeconds.addingReportingOverflow(
            microseconds
        )
        guard !overflowedSeconds, !overflowedAddition, identity > 0 else {
            throw MacCodexProcessDiscoveryError.processIdentityUnavailable
        }
        return identity
    }
}
#endif
