import Foundation

public struct CodexRecoveryAutomationVerifier: Sendable {
    public let automationsDirectory: URL

    public init(automationsDirectory: URL = Self.defaultAutomationsDirectory()) {
        self.automationsDirectory = automationsDirectory
    }

    public static func defaultAutomationsDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["CODEX_GUARDIAN_AUTOMATIONS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let codexHome = environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex", directoryHint: .isDirectory)
        return codexHome.appending(path: "automations", directoryHint: .isDirectory)
    }

    public func isArmed(
        automationID: String,
        threadID: String,
        originToken: String
    ) throws -> Bool {
        guard isSafePathComponent(automationID),
              !threadID.isEmpty,
              UUID(uuidString: originToken) != nil else { return false }
        let configURL = automationsDirectory
            .appending(path: automationID, directoryHint: .isDirectory)
            .appending(path: "automation.toml")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return false }
        let values = try readValues(at: configURL)
        guard values["id"] == automationID,
              values["kind"]?.lowercased() == "heartbeat",
              values["status"]?.uppercased() == "ACTIVE",
              values["target_thread_id"] == threadID,
              let prompt = values["prompt"],
              prompt.contains("recovery_tick"),
              prompt.contains(originToken),
              let rrule = values["rrule"] else { return false }
        let recurrenceParts = Set(rrule.split(separator: ";").map(String.init))
        guard recurrenceParts.contains("RRULE:FREQ=MINUTELY")
                || recurrenceParts.contains("FREQ=MINUTELY"),
              recurrenceParts.contains("INTERVAL=1") else { return false }
        return true
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }
    }

    private func readValues(at url: URL) throws -> [String: String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.intValue <= 256_000 else { return [:] }
        let text = try String(contentsOf: url, encoding: .utf8)
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            var value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        return values
    }
}
