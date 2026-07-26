public struct CodexAppServerProcessPolicy: Sendable {
    public init() {}

    public func processIDsToStop(
        processList: String,
        applicationPaths: [String]
    ) -> Set<Int32> {
        let executablePaths = Set(applicationPaths.map {
            $0 + "/Contents/Resources/codex"
        })
        return Set(processList.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2,
                  let processID = Int32(fields[0]) else { return nil }
            let command = String(fields[1])
            guard executablePaths.contains(where: {
                command == $0 || command.hasPrefix($0 + " ")
            }),
                  command.split(whereSeparator: \.isWhitespace).contains("app-server"),
                  command.contains("features.code_mode_host=true") else { return nil }
            return processID
        })
    }
}
