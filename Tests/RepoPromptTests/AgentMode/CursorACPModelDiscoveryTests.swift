import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

final class CursorACPModelDiscoveryTests: XCTestCase {
    func testControllerDiscoveryReturnsLiveParameterizedCursorSnapshotWithoutRegistryPublication() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }

        let workspace = try makeTestDirectory(name: "CursorACPModelDiscoveryTests")
        let scriptURL = try makeServerScript(in: workspace)
        let provider = CursorDiscoveryFakeProvider(commandPath: scriptURL.path)
        let client = CursorACPControllerModelDiscoveryClient(
            providerFactory: { _, _ in provider },
            controllerFactory: { provider, request in
                try ACPAgentSessionController(provider: provider, runRequest: request)
            }
        )

        let discovered = try await client.discoverModels(workspacePath: workspace.path)
        let snapshot = try XCTUnwrap(discovered)

        XCTAssertEqual(snapshot.currentModelRaw, "grok-4.6")
        XCTAssertEqual(snapshot.options.map(\.rawValue), ["grok-4.6"])
        XCTAssertNil(AgentACPModelRegistry.shared.currentSnapshot(for: .cursor))
    }

    private func makeServerScript(in directory: URL) throws -> URL {
        let scriptURL = directory.appendingPathComponent("cursor_discovery_server.py")
        let script = #"""
        #!/usr/bin/env python3
        import json
        import sys

        config_options = [
            {
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": "grok-4.6",
                "options": [{"value": "grok-4.6", "name": "Cursor Grok 4.6"}],
            },
            {
                "id": "Cursor.Thought-Level",
                "name": "Effort",
                "category": "thought_level",
                "type": "select",
                "currentValue": "high",
                "options": [{"value": "low", "name": "Low"}, {"value": "high", "name": "High"}],
            },
        ]

        for line in sys.stdin:
            request = json.loads(line)
            request_id = request.get("id")
            if request_id is None:
                continue
            method = request.get("method")
            if method == "initialize":
                result = {"agentCapabilities": {}}
            elif method == "session/new":
                result = {"sessionId": "cursor-discovery", "configOptions": config_options}
            elif method == "session/set_config_option":
                result = {"configOptions": config_options}
            else:
                result = {}
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

private struct CursorDiscoveryFakeProvider: ACPAgentProvider {
    let commandPath: String

    let providerID: ACPProviderID = .cursor
    let supportsParameterizedModelPicker = true

    func support(for _: ACPRunRequest) async -> ACPSupportResult {
        .supported
    }

    func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
        ACPLaunchConfiguration(
            providerID: providerID,
            command: commandPath,
            arguments: [],
            environment: [:],
            workingDirectory: request.workspacePath,
            additionalPathHints: [],
            enableDebugLogging: false
        )
    }

    func makeSessionConfiguration(
        for request: ACPRunRequest,
        mcpServer _: RepoPromptMCPServerConfiguration
    ) throws -> ACPSessionConfiguration {
        ACPSessionConfiguration(
            mode: .new,
            workingDirectory: request.workspacePath ?? FileManager.default.temporaryDirectory.path,
            mcpServers: []
        )
    }

    func buildPromptBlocks(for message: AgentMessage, request _: ACPRunRequest) throws -> [[String: Any]] {
        [["type": "text", "text": message.userMessage]]
    }

    func normalizeSessionUpdate(
        _: [String: Any],
        sessionID _: String
    ) -> [NormalizedAgentRuntimeEvent] {
        []
    }

    func normalizeError(_ error: Error) -> Error {
        error
    }
}
