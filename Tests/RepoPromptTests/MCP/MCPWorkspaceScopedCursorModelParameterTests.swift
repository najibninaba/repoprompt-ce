import Foundation
import MCP
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class MCPWorkspaceScopedCursorModelParameterTests: XCTestCase {
    func testPollingAuthorityKeepsWorkspaceDefinitionsOutOfGlobalRegistry() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let workspaceA = await fixture.polling.modelParameterSnapshot(
            for: "grok",
            workspacePath: fixture.rootA.path
        )
        let workspaceB = await fixture.polling.modelParameterSnapshot(
            for: "grok",
            workspacePath: fixture.rootB.path
        )

        XCTAssertEqual(parameterConfigIDs(workspaceA), ["workspace_a_effort"])
        XCTAssertEqual(parameterConfigIDs(workspaceB), ["workspace_b_speed"])
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)?.modelParameterSets,
            []
        )
    }

    func testAgentManageListCreateAndResumeUseActiveWorkspaceAuthority() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let windowA = try await makeWindow(name: "Cursor MCP A", root: fixture.rootA)
        defer { WindowStatesManager.shared.unregisterWindowState(windowA) }

        let serviceA = makeManageService(window: windowA, polling: fixture.polling)
        let listedA = try await serviceA.execute(args: ["op": .string("list_agents")])
        XCTAssertEqual(listedParameterConfigIDs(listedA, modelRaw: "grok"), ["workspace_a_effort"])

        let createdA = try await serviceA.execute(args: [
            "op": .string("create_session"),
            "model_id": .string(cursorGrokModelID),
            "model_parameters": request(configID: "workspace_a_effort", value: "a_high")
        ])
        XCTAssertEqual(effectiveParameterConfigIDs(createdA), ["workspace_a_effort"])
        let sessionA = try XCTUnwrap(createdA.objectValue?["session_id"]?.stringValue)

        let resumedA = try await serviceA.execute(args: [
            "op": .string("resume_session"),
            "session_id": .string(sessionA),
            "model_id": .string(cursorGrokModelID),
            "model_parameters": request(configID: "workspace_a_effort", value: "a_low")
        ])
        XCTAssertEqual(effectiveParameterConfigIDs(resumedA), ["workspace_a_effort"])

        let windowB = try await makeWindow(name: "Cursor MCP B", root: fixture.rootB)
        defer { WindowStatesManager.shared.unregisterWindowState(windowB) }
        let serviceB = makeManageService(window: windowB, polling: fixture.polling)
        let listedB = try await serviceB.execute(args: ["op": .string("list_agents")])
        XCTAssertEqual(listedParameterConfigIDs(listedB, modelRaw: "grok"), ["workspace_b_speed"])

        let createdB = try await serviceB.execute(args: [
            "op": .string("create_session"),
            "model_id": .string(cursorGrokModelID),
            "model_parameters": request(configID: "workspace_b_speed", value: "b_fast")
        ])
        XCTAssertEqual(effectiveParameterConfigIDs(createdB), ["workspace_b_speed"])
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)?.modelParameterSets,
            []
        )
    }

    func testAgentRunStartValidatesAgainstTargetWorkspaceAuthority() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let windowB = try await makeWindow(name: "Cursor MCP Run B", root: fixture.rootB)
        defer { WindowStatesManager.shared.unregisterWindowState(windowB) }
        var service = makeRunService(window: windowB)
        service.cursorModelParameterSnapshot = { workspacePath, modelRaw in
            await fixture.polling.modelParameterSnapshot(for: modelRaw, workspacePath: workspacePath)
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Use workspace-local Cursor parameters."),
                "model_id": .string(cursorGrokModelID),
                "model_parameters": request(configID: "workspace_a_effort", value: "a_high")
            ])
            XCTFail("Expected workspace B to reject workspace A parameter metadata")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("workspace_a_effort"),
                "Unexpected validation error: \(error)"
            )
        }
        XCTAssertEqual(
            AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)?.modelParameterSets,
            []
        )
    }

    func testAgentRunFailedStartRestoresExistingSessionCursorParameters() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Run Rollback", root: fixture.rootA)
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
        _ = try agentModeVM.mcpStageModelParameterSelections(
            tabID: tabID,
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok",
            selections: [selection(value: "a_low")]
        )

        var stagedValueAtFailure: String?
        var service = makeRunService(
            window: window,
            targetTabID: tabID,
            beforeStartFailure: { viewModel, targetTabID in
                stagedValueAtFailure = viewModel.session(for: targetTabID)
                    .acpModelParameterSelections.first?.valueRaw
            }
        )
        service.cursorModelParameterSnapshot = { workspacePath, modelRaw in
            await fixture.polling.modelParameterSnapshot(for: modelRaw, workspacePath: workspacePath)
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Fail after staging Cursor parameters."),
                "model_id": .string(cursorGrokModelID),
                "model_parameters": request(configID: "workspace_a_effort", value: "a_high")
            ])
            XCTFail("Expected the injected provider start failure")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains("Injected provider start failure"),
                "Unexpected start error: \(error)"
            )
        }

        let retainedSession = agentModeVM.session(for: tabID)
        XCTAssertEqual(stagedValueAtFailure, "a_high")
        XCTAssertEqual(retainedSession.activeAgentSessionID, sessionID)
        XCTAssertEqual(retainedSession.acpModelParameterSelections.first?.valueRaw, "a_low")
    }

    func testAgentRunFailedStartPreservesNewerCursorParameterSelection() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let window = try await makeWindow(name: "Cursor MCP Run Concurrent Selection", root: fixture.rootA)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }
        let agentModeVM = window.agentModeViewModel
        let tabID = try XCTUnwrap(window.workspaceManager.activeWorkspace?.activeComposeTabID)
        _ = try await agentModeVM.mcpResolveOrCreateSessionTarget(
            tabID: tabID,
            sessionID: nil,
            createIfNeeded: true,
            sessionName: nil
        )
        _ = try agentModeVM.mcpStageModelParameterSelections(
            tabID: tabID,
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "grok",
            selections: [selection(value: "a_low")]
        )

        var service = makeRunService(
            window: window,
            targetTabID: tabID,
            beforeStartFailure: { viewModel, targetTabID in
                _ = try viewModel.mcpStageModelParameterSelections(
                    tabID: targetTabID,
                    agentRaw: AgentProviderKind.cursor.rawValue,
                    modelRaw: "grok",
                    selections: [self.selection(value: "a_newer")]
                )
            }
        )
        service.cursorModelParameterSnapshot = { workspacePath, modelRaw in
            await fixture.polling.modelParameterSnapshot(for: modelRaw, workspacePath: workspacePath)
        }

        do {
            _ = try await service.execute(args: [
                "op": .string("start"),
                "message": .string("Preserve a newer parameter selection after failure."),
                "model_id": .string(cursorGrokModelID),
                "model_parameters": request(configID: "workspace_a_effort", value: "a_high")
            ])
            XCTFail("Expected the injected provider start failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("Injected provider start failure"))
        }

        XCTAssertEqual(
            agentModeVM.session(for: tabID).acpModelParameterSelections.first?.valueRaw,
            "a_newer"
        )
    }

    private var cursorGrokModelID: String {
        AgentModelSelectionID(agentRaw: AgentProviderKind.cursor.rawValue, modelRaw: "grok").rawValue
    }

    private func makeFixture() throws -> Fixture {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [
                    AgentModelOption(
                        rawValue: "grok",
                        displayName: "Grok",
                        description: nil,
                        isPlaceholderDefault: false,
                        isProviderDefault: true
                    )
                ],
                currentModelRaw: "grok"
            ),
            for: .cursor
        )
        let rootA = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-cursor-mcp-a-\(UUID().uuidString)", isDirectory: true)
        let rootB = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpce-cursor-mcp-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        let client = WorkspaceCursorModelDiscoveryClient(rootA: rootA.path, rootB: rootB.path)
        let polling = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        return Fixture(rootA: rootA, rootB: rootB, polling: polling)
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
            reason: "workspaceScopedCursorMCPTests"
        )
        let activeWorkspace = try XCTUnwrap(window.workspaceManager.activeWorkspace)
        window.promptManager.loadComposeTabsFromWorkspace(activeWorkspace, syncPromptText: true)
        return window
    }

    private func makeManageService(
        window: WindowState,
        polling: CursorACPModelPollingService
    ) -> AgentManageMCPToolService {
        AgentManageMCPToolService(
            toolName: MCPWindowToolName.agentManage,
            captureRequestMetadata: {
                MCPServerViewModel.RequestMetadata(
                    connectionID: UUID(),
                    clientName: "workspace-scoped-cursor-model-parameters",
                    windowID: window.windowID
                )
            },
            requireTargetWindow: { window },
            resolveSpawnSourceTabID: { _ in nil },
            resolveSpawnParentSessionID: { _, _ in nil },
            bindCurrentRequestToTab: { _, _ in },
            restrictDiscoveryToRoleLabels: { _ in false },
            cursorModelParameterSnapshot: { workspacePath, modelRaw in
                await polling.modelParameterSnapshot(for: modelRaw, workspacePath: workspacePath)
            }
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
                    clientName: "workspace-scoped-cursor-model-parameters",
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
                    reason: .sourceCaptureFailed("Synthetic MCP workspace-authority fixture")
                ))
            )
        }
        return service
    }

    private func request(configID: String, value: String) -> Value {
        .array([.object(["config_id": .string(configID), "value": .string(value)])])
    }

    private func selection(value: String) -> ACPModelParameterSelection {
        ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok",
            kind: .thinking,
            configID: "workspace_a_effort",
            valueRaw: value
        )
    }

    private func parameterConfigIDs(_ snapshot: ACPDiscoveredSessionModels?) -> [String] {
        snapshot?.modelParameterSets.flatMap(\.parameters).map(\.configID) ?? []
    }

    private func effectiveParameterConfigIDs(_ value: Value) -> [String] {
        value.objectValue?["agent"]?.objectValue?["model_parameters"]?.arrayValue?.compactMap {
            $0.objectValue?["config_id"]?.stringValue
        } ?? []
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

    private struct Fixture {
        let rootA: URL
        let rootB: URL
        let polling: CursorACPModelPollingService

        func cleanup() {
            Task { await polling.shutdown() }
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
    }
}

private actor WorkspaceCursorModelDiscoveryClient: CursorACPModelDiscoveryClient {
    let rootA: String
    let rootB: String

    init(rootA: String, rootB: String) {
        self.rootA = rootA
        self.rootB = rootB
    }

    func discoverModels(
        workspacePath: String?,
        preferredModelRaw: String?
    ) async throws -> ACPDiscoveredSessionModels? {
        let option = AgentModelOption(
            rawValue: "grok",
            displayName: "Grok",
            description: nil,
            isPlaceholderDefault: false,
            isProviderDefault: true
        )
        guard preferredModelRaw != nil else {
            return ACPDiscoveredSessionModels(options: [option], currentModelRaw: "grok")
        }
        let definition: ACPModelParameterDefinition
        if workspacePath == rootA {
            definition = .init(
                kind: .thinking,
                configID: "workspace_a_effort",
                displayName: "Effort A",
                choices: [
                    .init(rawValue: "a_low", displayName: "Low A"),
                    .init(rawValue: "a_high", displayName: "High A"),
                    .init(rawValue: "a_newer", displayName: "Newer A")
                ],
                currentValueRaw: "a_low"
            )
        } else if workspacePath == rootB {
            definition = .init(
                kind: .speed,
                configID: "workspace_b_speed",
                displayName: "Speed B",
                choices: [
                    .init(rawValue: "b_standard", displayName: "Standard B"),
                    .init(rawValue: "b_fast", displayName: "Fast B")
                ],
                currentValueRaw: "b_standard"
            )
        } else {
            return ACPDiscoveredSessionModels(options: [option], currentModelRaw: "grok")
        }
        return ACPDiscoveredSessionModels(
            options: [option],
            currentModelRaw: "grok",
            modelParameterSets: [.init(baseModelRaw: "grok", parameters: [definition])]
        )
    }
}
