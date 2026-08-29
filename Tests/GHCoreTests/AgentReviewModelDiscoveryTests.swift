import XCTest
@testable import GHCore

final class AgentReviewModelDiscoveryTests: XCTestCase {
    func testParsesCopilotModelsFromInstalledCLIHelpShape() {
        let output = """
          `model`: AI model to use for Copilot CLI.
            - "claude-sonnet-5"
            - "gpt-5.6-sol"
            - "gpt-5.6-sol"

          `contextTier`: context window tier.
        """

        XCTAssertEqual(
            AgentReviewModelDiscovery.parseCopilotModels(output).map(\.id),
            ["claude-sonnet-5", "gpt-5.6-sol"]
        )
    }

    func testParsesClaudeAliasesAndFullModelExample() {
        let output = """
          --model <model>  Model for the current session. Provide an alias for the latest model
                           (e.g. 'fable', 'opus', or 'sonnet') or a model's full name
                           (e.g. 'claude-fable-5').
          -n, --name       Set a display name.
        """

        XCTAssertEqual(
            AgentReviewModelDiscovery.parseClaudeModels(output).map(\.id),
            ["fable", "opus", "sonnet", "claude-fable-5"]
        )
    }

    func testParsesCodexModelListResponseAmongOtherProtocolMessages() {
        let output = """
        {"id":1,"result":{"userAgent":"Codex"}}
        {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
        {"id":2,"result":{"data":[{"model":"gpt-5.6-sol","displayName":"GPT-5.6-Sol","description":"Frontier"},{"model":"gpt-5.6-terra","displayName":"GPT-5.6-Terra","description":"Balanced"}],"nextCursor":null}}
        """

        XCTAssertEqual(
            AgentReviewModelDiscovery.parseCodexModels(output),
            [
                AgentReviewModelOption(id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", detail: "Frontier"),
                AgentReviewModelOption(id: "gpt-5.6-terra", displayName: "GPT-5.6-Terra", detail: "Balanced")
            ]
        )
    }

    func testCopilotDiscoveryUsesCLIHelpAndReturnsParsedOptions() async throws {
        let runner = ModelDiscoveryProcessRunner(result: ProcessResult(
            stdout: """
              `model`: AI model to use for Copilot CLI.
                - "claude-sonnet-5"
              `contextTier`: context window tier.
            """,
            stderr: "",
            exitCode: 0
        ))

        let models = try await AgentReviewModelDiscovery(runner: runner).models(for: .copilot)

        XCTAssertEqual(models.map(\.id), ["auto", "claude-sonnet-5"])
    }
}

private struct ModelDiscoveryProcessRunner: ProcessRunning {
    let result: ProcessResult

    func run(executable: String, arguments: [String]) async throws -> ProcessResult {
        result
    }
}
