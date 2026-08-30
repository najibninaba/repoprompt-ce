import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class MCPWorkspaceScopedCursorModelParameterTests: XCTestCase {
    func testFixtureRootsUseUniqueUUIDPaths() throws {
        let first = try makeFixture()
        defer { first.cleanup() }
        let second = try makeFixture()
        defer { second.cleanup() }

        XCTAssertNotEqual(first.root, second.root)
    }

    func testAgentManageListCreateAndResumeUseReleaseCatalogMetadata() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let service = makeManageService(window: window)
        let listed = try await service.execute(args: ["op": .string("list_agents")])
        XCTAssertEqual(
            listedParameterConfigIDs(listed, modelRaw: "grok-4.6"),
            ["Cursor.Thought-Level", "fast"]
        )

        let modelID = cursorModelID
        let created = try await service.execute(args: [
            "op": .string("create_session"),
            "model_id": .string(modelID),
            "model_parameters": request([
                ("Cursor.Thought-Level", "high"),
                ("fast", "true")
            ])
        ])
        XCTAssertEqual(effectiveParameterConfigIDs(created), ["Cursor.Thought-Level", "fast"])
        let sessionID = try XCTUnwrap(created.objectValue?["session_id"]?.stringValue)

        let resumed = try await service.execute(args: [
            "op": .string("resume_session"),
            "session_id": .string(sessionID),
            "model_id": .string(modelID),
            "model_parameters": request([
                ("Cursor.Thought-Level", "low"),
                ("fast", "false")
            ])
        ])
        XCTAssertEqual(effectiveParameterConfigIDs(resumed), ["Cursor.Thought-Level", "fast"])
    }

    func testAgentRunStartRejectsUnknownReleaseCatalogParameter() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Run", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let service = makeRunService(window: window)

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Reject stale metadata."),
                "model_id": .string(cursorModelID),
                "model_parameters": request([("workspace_effort", "high")])
            ])
            XCTFail("Expected stale parameter metadata to be rejected")
        } catch {
            XCTAssertTrue(String(describing: error).contains("workspace_effort"))
        }
    }

    func testAgentRunFailedStartRestoresExistingSessionCursorParameters() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Run Rollback", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let agentModeVM = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        let target = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: tabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: nil
        )
        let sessionID = try XCTUnwrap(target.sessionID)
        _ = try await agentModeVM.mcpStageModelParameterSelections(
            tabID: tabID,
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok-4.6",
            selections: [selection(value: "low")]
        )

        var stagedValueAtFailure: String?
        let service = makeRunService(
            window: window,
            targetTabID: tabID,
            beforeStartFailure: { viewModel, targetTabID in
                stagedValueAtFailure = viewModel.session(for: targetTabID)
                    .acpModelParameterSelections.first?.valueRaw
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Fail after staging Cursor parameters."),
                "model_id": .string(cursorModelID),
                "model_parameters": request([("Cursor.Thought-Level", "high")])
            ])
            XCTFail("Expected the injected provider start failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Injected provider start failure"))
        }

        let retainedSession = agentModeVM.session(for: tabID)
        XCTAssertEqual(stagedValueAtFailure, "high")
        XCTAssertEqual(retainedSession.activeAgentSessionID, sessionID)
        XCTAssertEqual(retainedSession.acpModelParameterSelections.first?.valueRaw, "low")
    }

    func testAgentRunFailedStartPreservesNewerCursorParameterSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Run Concurrent Selection", root: fixture.root)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let agentModeVM = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        _ = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: tabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: nil
        )
        _ = try await agentModeVM.mcpStageModelParameterSelections(
            tabID: tabID,
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok-4.6",
            selections: [selection(value: "low")]
        )

        let service = makeRunService(
            window: window,
            targetTabID: tabID,
            beforeStartFailure: { viewModel, targetTabID in
                _ = try viewModel.mcpStageModelParameterSelections(
                    tabID: targetTabID,
                    agentRaw: AgentProviderKind.cursor.rawValue,
                    modelRaw: "grok-4.6",
                    selections: [self.selection(value: "medium")]
                )
            }
        )

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Preserve a newer parameter selection after failure."),
                "model_id": .string(cursorModelID),
                "model_parameters": request([("Cursor.Thought-Level", "high")])
            ])
            XCTFail("Expected the injected provider start failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Injected provider start failure"))
        }

        XCTAssertEqual(
            agentModeVM.session(for: tabID).acpModelParameterSelections.first?.valueRaw,
            "medium"
        )
    }

    private var cursorModelID: String {
        AgentModelSelectionID(agentRaw: AgentProviderKind.cursor.rawValue, modelRaw: "grok-4.6").rawValue
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-cursor-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(root: root)
    }

    private func makeWindow(name: String, root: URL) async throws -> WindowState {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        window.apiSettingsViewModel.isCursorConnected = true
        let workspace = window.workspaceManager.createWorkspace(
            name: name,
            repoPaths: [root.path],
            ephemeral: true
        )
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "releaseGatedCursorMCPTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeManageService(window: WindowState) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "release-gated-cursor-model-parameters",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false }
        )
    }

    private func makeRunService(
        window: WindowState,
        targetTabID: UUID? = nil,
        beforeStartFailure: ((AgentModeViewModel, UUID) throws -> Void)? = nil
    ) -> AgentRunMCPToolService {
        var service = AgentRunMCPToolService(
            toolName: MCPWindowToolName.agentRun,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "release-gated-cursor-model-parameters",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveRequestedTabID: { _ in targetTabID },
            resolveSpawnParentSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            withHeartbeat: { _, _, _, _, operation in try await operation() },
            startRun: { target, _, _, agentModeVM, _, _, _, _, _, _, _ in
                try beforeStartFailure?(agentModeVM, target.tabID)
                throw MCPError.internalError("Injected provider start failure.")
            }
        )
        service.resolveOracleReviewLaunchSource = { _, targetWindow in
            let workspace = try XCTUnwrap(targetWindow.workspaceManager.activeWorkspace)
            let tabID = try XCTUnwrap(workspace.activeComposeTabID)
            let snapshot = AgentRunOracleReviewLaunchSnapshot(
                route: .explicitWindowActiveCompose,
                windowID: targetWindow.windowID,
                workspaceID: workspace.id,
                tabID: tabID,
                selectionRevision: 0,
                promptText: "",
                selection: StoredSelection(),
                sourceAgentSessionID: nil,
                routedRunID: nil
            )
            return ResolvedAgentRunOracleReviewLaunchSource(
                snapshot: snapshot,
                source: .unavailable(.init(
                    delegationID: UUID(),
                    sourceTabID: tabID,
                    workspaceID: workspace.id,
                    sourceAgentSessionID: nil,
                    sourceAgentRunID: nil,
                    reason: .sourceCaptureFailed("Synthetic MCP release-catalog fixture")
                ))
            )
        }
        return service
    }

    private func request(_ pairs: [(String, String)]) -> Value {
        .array(pairs.map { configID, value in
            .object(["config_id": .string(configID), "value": .string(value)])
        })
    }

    private func selection(value: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: value
        )
    }

    private func listedParameterConfigIDs(_ value: Value, modelRaw: String) -> [String] {
        let cursor = value.objectValue?["agents"]?.arrayValue?.first {
            $0.objectValue?["name"]?.stringValue == AgentProviderKind.cursor.displayName
        }
        let model = cursor?.objectValue?["models"]?.arrayValue?.first {
            $0.objectValue?["model_id"]?.stringValue == AgentModelSelectionID(
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: modelRaw
            ).rawValue
        }
        return model?.objectValue?["model_parameters"]?.arrayValue?.compactMap {
            $0.objectValue?["config_id"]?.stringValue
        } ?? []
    }

    private func effectiveParameterConfigIDs(_ value: Value) -> [String] {
        value.objectValue?["agent"]?.objectValue?["model_parameters"]?.arrayValue?.compactMap {
            $0.objectValue?["config_id"]?.stringValue
        } ?? []
    }

    private struct Fixture {
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
