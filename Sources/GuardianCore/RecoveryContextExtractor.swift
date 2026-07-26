import Foundation

public struct RecoveryContextExtractor: Sendable {
    public static let maximumCharacters = 6_000

    public init() {}

    public func extract(from rollout: String, originToken: String) -> String {
        let lines = rollout.split(separator: "\n", omittingEmptySubsequences: true).suffix(40)
        var fragments: [String] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary["type"] as? String != "session_meta" else { continue }
            collectStrings(from: dictionary["payload"], into: &fragments)
        }

        let joined = fragments
            .map { sanitize($0, originToken: originToken) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        return String(joined.suffix(Self.maximumCharacters))
    }

    private func collectStrings(from value: Any?, into output: inout [String]) {
        switch value {
        case let string as String:
            output.append(string)
        case let array as [Any]:
            array.forEach { collectStrings(from: $0, into: &output) }
        case let dictionary as [String: Any]:
            for key in dictionary.keys.sorted() {
                collectStrings(from: dictionary[key], into: &output)
            }
        default:
            break
        }
    }

    public func sanitize(_ input: String, originToken: String) -> String {
        var result = input.replacingOccurrences(of: originToken, with: "[ORIGIN]")
        let homePathPattern = "/" + "Users/" + #"[^/\s]+"#
        let patterns = [
            #"(?i)(?:api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*[^\s\"',}]+"#,
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{12,}"#,
            #"\b(?:sk|gh[pousr])-[A-Za-z0-9_-]{16,}\b"#,
            #"\bsk-[A-Za-z0-9_-]{16,}\b"#,
            homePathPattern,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: pattern == homePathPattern ? "/" + "Users/[USER]" : "[REDACTED]"
            )
        }
        return result
    }
}
