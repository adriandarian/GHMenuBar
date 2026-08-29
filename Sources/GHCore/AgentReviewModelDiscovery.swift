import Foundation

public struct AgentReviewModelOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String?

    public init(id: String, displayName: String, detail: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
    }
}

public enum AgentReviewModelDiscoveryError: Error, LocalizedError, Equatable {
    case commandFailed(tool: String, details: String)
    case invalidResponse(tool: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let tool, let details):
            return details.isEmpty
                ? "Could not load models from \(tool)."
                : "Could not load models from \(tool): \(details)"
        case .invalidResponse(let tool):
            return "\(tool) did not return a recognizable model list. You can still enter a model ID manually."
        }
    }
}

public struct AgentReviewModelDiscovery: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = DefaultProcessRunner()) {
        self.runner = runner
    }

    public func models(for tool: AgentReviewTool) async throws -> [AgentReviewModelOption] {
        switch tool {
        case .copilot:
            let output = try await commandOutput(
                executable: "copilot",
                arguments: ["help", "config"],
                tool: tool
            )
            let models = Self.parseCopilotModels(output)
            guard !models.isEmpty else {
                throw AgentReviewModelDiscoveryError.invalidResponse(tool: tool.displayName)
            }
            return [AgentReviewModelOption(id: "auto", displayName: "Auto")] + models.filter { $0.id != "auto" }
        case .claudeCode:
            let output = try await commandOutput(
                executable: "claude",
                arguments: ["--help"],
                tool: tool
            )
            let models = Self.parseClaudeModels(output)
            guard !models.isEmpty else {
                throw AgentReviewModelDiscoveryError.invalidResponse(tool: tool.displayName)
            }
            return models
        case .codexCLI:
            return try await Self.loadCodexModels()
        }
    }

    private func commandOutput(
        executable: String,
        arguments: [String],
        tool: AgentReviewTool
    ) async throws -> String {
        let result: ProcessResult
        do {
            result = try await runner.run(executable: executable, arguments: arguments)
        } catch {
            throw AgentReviewModelDiscoveryError.commandFailed(
                tool: tool.displayName,
                details: error.localizedDescription
            )
        }

        guard result.exitCode == 0 else {
            let details = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "status \(result.exitCode)"
            throw AgentReviewModelDiscoveryError.commandFailed(tool: tool.displayName, details: details)
        }
        return result.stdout
    }

    static func parseCopilotModels(_ output: String) -> [AgentReviewModelOption] {
        var isInModelSection = false
        var modelIDs: [String] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("`model`:") {
                isInModelSection = true
                continue
            }
            guard isInModelSection else { continue }
            if trimmedLine.hasPrefix("`") {
                break
            }
            guard trimmedLine.hasPrefix("- \"") && trimmedLine.hasSuffix("\"") else {
                continue
            }
            let modelID = String(trimmedLine.dropFirst(3).dropLast())
            if !modelID.isEmpty && !modelIDs.contains(modelID) {
                modelIDs.append(modelID)
            }
        }

        return modelIDs.map {
            AgentReviewModelOption(id: $0, displayName: Self.displayName(for: $0))
        }
    }

    static func parseClaudeModels(_ output: String) -> [AgentReviewModelOption] {
        let lines = output.components(separatedBy: .newlines)
        guard let modelLineIndex = lines.firstIndex(where: { $0.contains("--model <model>") }) else {
            return []
        }

        var descriptionLines: [String] = []
        for line in lines[modelLineIndex...] {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if !descriptionLines.isEmpty,
               (trimmedLine.hasPrefix("--") || trimmedLine.hasPrefix("-")) {
                break
            }
            descriptionLines.append(line)
        }

        let description = descriptionLines.joined(separator: " ")
        let expression = try? NSRegularExpression(
            pattern: "(?<![A-Za-z])'([A-Za-z0-9._-]+)'",
            options: []
        )
        let range = NSRange(description.startIndex..., in: description)
        let matches = expression?.matches(in: description, options: [], range: range) ?? []
        let modelIDs = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: description) else { return nil }
            let value = String(description[range])
            let validCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
            guard !value.isEmpty,
                  value.unicodeScalars.allSatisfy(validCharacters.contains)
            else {
                return nil
            }
            return value
        }.reduce(into: [String]()) { values, value in
            guard !values.contains(value) else { return }
            values.append(value)
        }

        return modelIDs.map {
            AgentReviewModelOption(id: $0, displayName: Self.displayName(for: $0))
        }
    }

    private static func loadCodexModels() async throws -> [AgentReviewModelOption] {
        try await Task.detached {
            let process = Process()
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            var environment = ProcessInfo.processInfo.environment
            let searchPath = DefaultProcessRunner.searchPath(existingPath: environment["PATH"])
            let executablePath = DefaultProcessRunner.executablePath(
                executable: "codex",
                searchPath: searchPath
            )

            process.executableURL = URL(fileURLWithPath: executablePath ?? "/usr/bin/env")
            process.arguments = executablePath == nil
                ? ["codex", "app-server", "--stdio"]
                : ["app-server", "--stdio"]
            environment["PATH"] = searchPath
            process.environment = environment
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr

            do {
                try process.run()
            } catch {
                throw AgentReviewModelDiscoveryError.commandFailed(
                    tool: AgentReviewTool.codexCLI.displayName,
                    details: error.localizedDescription
                )
            }

            let stdoutTask = Task.detached {
                stdout.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderr.fileHandleForReading.readDataToEndOfFile()
            }
            let requests = """
            {"id":1,"method":"initialize","params":{"clientInfo":{"name":"ghmenubar","version":"0.1"}}}
            {"id":2,"method":"model/list","params":{"includeHidden":false,"limit":100}}

            """
            stdin.fileHandleForWriting.write(Data(requests.utf8))
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()

            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value
            let output = String(data: stdoutData, encoding: .utf8) ?? ""
            let errorOutput = String(data: stderrData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw AgentReviewModelDiscoveryError.commandFailed(
                    tool: AgentReviewTool.codexCLI.displayName,
                    details: errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }

            let models = Self.parseCodexModels(output)
            guard !models.isEmpty else {
                throw AgentReviewModelDiscoveryError.invalidResponse(
                    tool: AgentReviewTool.codexCLI.displayName
                )
            }
            return models
        }.value
    }

    static func parseCodexModels(_ output: String) -> [AgentReviewModelOption] {
        for line in output.components(separatedBy: .newlines) {
            guard let data = line.data(using: .utf8),
                  let response = try? JSONDecoder().decode(CodexModelListEnvelope.self, from: data),
                  response.id == 2,
                  let models = response.result?.data
            else {
                continue
            }

            return models.map {
                AgentReviewModelOption(
                    id: $0.model,
                    displayName: $0.displayName,
                    detail: $0.description
                )
            }
        }
        return []
    }

    private static func displayName(for modelID: String) -> String {
        modelID
            .split(separator: "-")
            .map { component in
                let value = String(component)
                if value.allSatisfy(\.isNumber) { return value }
                switch value.lowercased() {
                case "gpt": return "GPT"
                case "mai": return "MAI"
                default: return value.prefix(1).uppercased() + value.dropFirst()
                }
            }
            .joined(separator: " ")
    }
}

private struct CodexModelListEnvelope: Decodable {
    let id: Int?
    let result: CodexModelListResult?
}

private struct CodexModelListResult: Decodable {
    let data: [CodexModel]
}

private struct CodexModel: Decodable {
    let model: String
    let displayName: String
    let description: String
}
