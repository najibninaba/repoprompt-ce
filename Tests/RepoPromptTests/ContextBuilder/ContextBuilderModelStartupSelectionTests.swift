import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

@MainActor
final class ContextBuilderModelStartupSelectionTests: XCTestCase {
    func testValidPersistedSelectionSurvivesStoreReloadAndStartupResolution() throws {
        let fixture = try makeStoreFixture()
        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.codexExec.rawValue,
            modelRaw: AgentModel.gpt56SolLow.rawValue,
            markUserDefined: true
        )

        let reloadedStore = GlobalSettingsStore(defaults: fixture.defaults, fileStore: fixture.fileStore)
        let persisted = reloadedStore.persistedGlobalContextBuilderAgentSelection()
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: persisted.agentRaw,
            persistedModelRaw: persisted.modelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .codexExec)
        XCTAssertEqual(resolved.modelRaw, AgentModel.gpt56SolLow.rawValue)
    }

    func testUnavailablePersistedSelectionFallsBackToRecommendedAvailableProvider() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.claudeCode.rawValue,
            persistedModelRaw: AgentModel.claudeOpus.rawValue,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: true
            )
        ))

        XCTAssertEqual(resolved.agent, .codexExec)
        XCTAssertEqual(resolved.modelRaw, AgentModel.gpt56SolLow.rawValue)
    }

    func testUnconfiguredClaudeCodeCannotBecomeEffectiveStartupSelection() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertNotEqual(resolved.agent, .claudeCode)
        XCTAssertNotEqual(resolved.modelRaw, AgentModel.claudeOpus.rawValue)
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: resolved.modelRaw,
            for: resolved.agent,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))
    }

    func testFallbackUsesWizardRecommendationProviderFilter() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: "removed/model",
            availability: .init(
                claudeCodeAvailable: true,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            ),
            enabledRecommendationProviders: [.claudeCode]
        ))

        XCTAssertEqual(resolved.agent, .claudeCode)
        XCTAssertEqual(resolved.modelRaw, AgentModel.claudeSonnet.rawValue)
    }

    func testFilteredRecommendationProvidersDoNotReappearThroughGenericFallback() throws {
        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: nil,
            persistedModelRaw: nil,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            ),
            enabledRecommendationProviders: [.claudeCode]
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, AgentModel.defaultModel.rawValue)
    }

    func testStaticOpenCodeDefaultSurvivesAfterACPDiscovery() throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let preferredModelRaw = "openai/gpt-dynamic"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: preferredModelRaw,
                    displayName: "GPT Dynamic",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: preferredModelRaw
            ),
            for: providerID
        ))

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: AgentModel.defaultModel.rawValue,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, preferredModelRaw)
    }

    func testDynamicPersistedSelectionSurvivesAfterACPDiscovery() throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-dynamic"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: dynamicModelRaw,
                    displayName: "GPT Dynamic",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: dynamicModelRaw
            ),
            for: providerID
        ))

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: dynamicModelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, dynamicModelRaw)
    }

    func testPersistedDynamicSelectionSurvivesStandardCatalogWarmup() async throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-persisted"
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [AgentModelOption(
                    rawValue: dynamicModelRaw,
                    displayName: "GPT Persisted",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )],
                currentModelRaw: dynamicModelRaw
            ),
            for: providerID
        ))
        AgentACPModelRegistry.shared.test_clearMemoryPreservingStore(providerID: providerID)
        XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: providerID))

        await AgentACPModelRegistry.shared.test_warmStandardStore()

        let resolved = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: AgentProviderKind.openCode.rawValue,
            persistedModelRaw: dynamicModelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: false,
                openCodeAvailable: true,
                cursorAvailable: false
            )
        ))
        XCTAssertEqual(resolved.agent, .openCode)
        XCTAssertEqual(resolved.modelRaw, dynamicModelRaw)
    }

    func testOpenCodeStartupReadinessJoinsRunningPollAndEmitsLiveSnapshot() async throws {
        let providerID = ACPProviderID.openCode
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let dynamicModelRaw = "openai/gpt-live"
        let discovered = ACPDiscoveredSessionModels(
            options: [AgentModelOption(
                rawValue: dynamicModelRaw,
                displayName: "GPT Live",
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: true
            )],
            currentModelRaw: dynamicModelRaw
        )
        let gate = DiscoveryGate()
        let client = GatedOpenCodeDiscoveryClient(result: discovered, gate: gate)
        let service = OpenCodeACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }
        let discoveryStartedEvents = await gate.discoveryStartedEvents()
        let joinEvents = await service.test_refreshNowInFlightJoinEvents()
        let stream = await service.subscribe(workspacePath: nil)
        await awaitFirstEvent(discoveryStartedEvents, description: "OpenCode background discovery started")

        async let readiness = service.refreshNow(workspacePath: nil)
        await awaitFirstEvent(joinEvents, description: "OpenCode refreshNow joined the in-flight poll")
        await gate.release()

        let emittedSnapshot = await liveOpenCodeSnapshot(from: stream)
        let isReady = await readiness
        let discoveryCallCount = await gate.callCount()
        let snapshot = try XCTUnwrap(emittedSnapshot)

        XCTAssertTrue(isReady)
        XCTAssertTrue(snapshot.isLiveDiscovery)
        XCTAssertEqual(snapshot.models.currentModelRaw, dynamicModelRaw)
        XCTAssertEqual(discoveryCallCount, 1)
    }

    func testCursorStartupReadinessJoinsRunningPollWithoutDynamicMetadata() async {
        let providerID = ACPProviderID.cursor
        AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: providerID)
        }

        let gate = DiscoveryGate()
        let client = GatedCursorDiscoveryClient(result: nil, gate: gate)
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }
        let discoveryStartedEvents = await gate.discoveryStartedEvents()
        let joinEvents = await service.test_refreshNowInFlightJoinEvents()
        let stream = await service.subscribe(workspacePath: nil)
        await awaitFirstEvent(discoveryStartedEvents, description: "Cursor background discovery started")

        async let readiness = service.refreshNow(workspacePath: nil)
        await awaitFirstEvent(joinEvents, description: "Cursor refreshNow joined the in-flight poll")
        await gate.release()

        let liveSnapshot = await liveCursorSnapshot(from: stream)
        let isReady = await readiness
        let discoveryCallCount = await gate.callCount()

        XCTAssertTrue(isReady)
        XCTAssertEqual(liveSnapshot?.isLiveDiscovery, true)
        XCTAssertEqual(discoveryCallCount, 1)
    }

    func testCursorTargetedRefreshRequestsExactModelsAndMergesOutOfOrderWithoutChangingCurrentModel() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        }
        let prior = cursorSnapshot(
            currentModelRaw: "model-a",
            valuesByModel: ["model-a": "old-a", "model-b": "old-b"]
        )
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(prior, for: .cursor))
        let client = TargetedCursorDiscoveryClient(results: [
            "model-a": cursorSnapshot(currentModelRaw: "model-a", valuesByModel: ["model-a": "new-a"]),
            "model-b": cursorSnapshot(currentModelRaw: "model-b", valuesByModel: ["model-b": "new-b"])
        ])
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }
        let requests = await client.requests()

        async let refreshA = service.refreshModelParameters(for: "model-a", workspacePath: "/tmp/workspace")
        async let refreshB = service.refreshModelParameters(for: "model-b", workspacePath: "/tmp/workspace")
        let firstRequest = await nextCursorTargetedRequest(from: requests)
        let secondRequest = await nextCursorTargetedRequest(from: requests)
        XCTAssertEqual(
            Set([firstRequest?.preferredModelRaw, secondRequest?.preferredModelRaw].compactMap(\.self)),
            Set(["model-a", "model-b"])
        )
        XCTAssertEqual(firstRequest?.workspacePath, "/tmp/workspace")
        XCTAssertEqual(secondRequest?.workspacePath, "/tmp/workspace")

        await client.release("model-b")
        await Task.yield()
        await client.release("model-a")
        let refreshResults = await (refreshA, refreshB)
        XCTAssertNotNil(refreshResults.0)
        XCTAssertNotNil(refreshResults.1)

        let latestSnapshot = await service.latestSnapshot(workspacePath: "/tmp/workspace")
        let merged = try XCTUnwrap(latestSnapshot?.models)
        XCTAssertEqual(merged.currentModelRaw, "model-a")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: merged.modelParameterSets.compactMap { set in
                set.parameters.first.map { (set.baseModelRaw, $0.currentValueRaw) }
            }),
            ["model-a": "new-a", "model-b": "new-b"]
        )
    }

    func testCursorSameModelTargetedRefreshesAreIsolatedByWorkspace() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let baseline = cursorSnapshot(
            currentModelRaw: "model-a",
            valuesByModel: ["model-a": "baseline-a", "model-b": "baseline-b"]
        )
        let client = TargetedCursorDiscoveryClient(
            baselineResult: baseline,
            results: [:],
            workspaceResults: [
                "/tmp/workspace-a": [
                    "model-b": cursorSnapshot(currentModelRaw: "model-b", valuesByModel: ["model-b": "workspace-a"])
                ],
                "/tmp/workspace-b": [
                    "model-b": cursorSnapshot(currentModelRaw: "model-b", valuesByModel: ["model-b": "workspace-b"])
                ]
            ]
        )
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }
        _ = try await service.discoverOnce(workspacePath: "/tmp/workspace-a")
        let requests = await client.requests()

        async let workspaceA = service.refreshModelParameters(for: "model-b", workspacePath: "/tmp/workspace-a")
        async let workspaceB = service.refreshModelParameters(for: "model-b", workspacePath: "/tmp/workspace-b")
        let firstRequest = await nextCursorTargetedRequest(from: requests)
        let secondRequest = await nextCursorTargetedRequest(from: requests)
        XCTAssertEqual(
            Set([firstRequest?.workspacePath, secondRequest?.workspacePath].compactMap(\.self)),
            Set(["/tmp/workspace-a", "/tmp/workspace-b"])
        )

        await client.release("model-b")
        let snapshots = await (workspaceA, workspaceB)
        XCTAssertEqual(snapshots.0.map(cursorParameterValues), ["model-a": "baseline-a", "model-b": "workspace-a"])
        XCTAssertEqual(snapshots.1.map(cursorParameterValues), ["model-b": "workspace-b"])
        let streamA = await service.subscribe(workspacePath: "/tmp/workspace-a")
        let streamB = await service.subscribe(workspacePath: "/tmp/workspace-b")
        let publishedA = await cursorParameterValue(from: streamA, modelRaw: "model-b")
        let publishedB = await cursorParameterValue(from: streamB, modelRaw: "model-b")
        XCTAssertEqual(publishedA, "workspace-a")
        XCTAssertEqual(publishedB, "workspace-b")
        let latestWorkspaceA = await service.latestSnapshot(workspacePath: "/tmp/workspace-a")
        let latestWorkspaceB = await service.latestSnapshot(workspacePath: "/tmp/workspace-b")
        XCTAssertEqual(
            latestWorkspaceA.map { cursorParameterValues($0.models) },
            ["model-a": "baseline-a", "model-b": "workspace-a"]
        )
        XCTAssertEqual(
            latestWorkspaceB.map { cursorParameterValues($0.models) },
            ["model-b": "workspace-b"]
        )
        XCTAssertEqual(
            AgentACPModelRegistry.shared.test_snapshot(providerID: .cursor).map(cursorParameterValues),
            [:]
        )
    }

    func testCursorJoinedBaselineNeverLeaksParameterDefinitionsAcrossWorkspaces() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let client = TargetedCursorDiscoveryClient(
            baselineResult: cursorSnapshot(
                currentModelRaw: "model-a",
                valuesByModel: ["model-a": "workspace-a-a", "model-b": "workspace-a-b"]
            ),
            gateBaseline: true,
            results: [:],
            workspaceResults: [
                "/tmp/workspace-b": [
                    "model-b": cursorSnapshot(
                        currentModelRaw: "model-b",
                        valuesByModel: ["model-b": "workspace-b-b"]
                    )
                ]
            ]
        )
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }
        let requests = await client.requests()
        let joinEvents = await service.test_refreshNowInFlightJoinEvents()

        async let workspaceARefresh = service.refreshNow(workspacePath: "/tmp/workspace-a")
        let baselineRequest = await nextCursorTargetedRequest(from: requests)
        XCTAssertEqual(baselineRequest?.workspacePath, "/tmp/workspace-a")
        XCTAssertNil(baselineRequest?.preferredModelRaw)

        async let workspaceBRefresh = service.refreshNow(workspacePath: "/tmp/workspace-b")
        await awaitFirstEvent(joinEvents, description: "Workspace B joined workspace A's Cursor baseline refresh")
        await client.releaseBaseline()
        let baselineResults = await (workspaceARefresh, workspaceBRefresh)
        XCTAssertTrue(baselineResults.0)
        XCTAssertTrue(baselineResults.1)

        async let targetedWorkspaceB = service.refreshModelParameters(
            for: "model-b",
            workspacePath: "/tmp/workspace-b"
        )
        let targetedRequest = await nextCursorTargetedRequest(from: requests)
        XCTAssertEqual(targetedRequest?.workspacePath, "/tmp/workspace-b")
        XCTAssertEqual(targetedRequest?.preferredModelRaw, "model-b")
        await client.release("model-b")

        let targetedWorkspaceBResult = await targetedWorkspaceB
        let workspaceB = try XCTUnwrap(targetedWorkspaceBResult)
        XCTAssertEqual(cursorParameterValues(workspaceB), ["model-b": "workspace-b-b"])
        let cachedWorkspaceB = await service.latestSnapshot(workspacePath: "/tmp/workspace-b")
        XCTAssertEqual(
            cachedWorkspaceB.map { cursorParameterValues($0.models) },
            ["model-b": "workspace-b-b"]
        )
        XCTAssertEqual(
            AgentACPModelRegistry.shared.test_snapshot(providerID: .cursor).map(cursorParameterValues),
            [:]
        )
    }

    func testCursorOlderTargetedCompletionCannotRestoreModelRemovedByNewerBaseline() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let prior = cursorSnapshot(
            currentModelRaw: "model-a",
            valuesByModel: ["model-a": "old-a", "model-b": "old-b"]
        )
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(prior, for: .cursor))
        let client = TargetedCursorDiscoveryClient(
            baselineResult: cursorSnapshot(
                currentModelRaw: "model-a",
                advertisedModels: ["model-a"],
                valuesByModel: ["model-a": "new-a"]
            ),
            results: [
                "model-b": cursorSnapshot(currentModelRaw: "model-b", valuesByModel: ["model-b": "stale-b"])
            ]
        )
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }
        let requests = await client.requests()

        async let targeted = service.refreshModelParameters(for: "model-b", workspacePath: "/tmp/workspace")
        _ = await nextCursorTargetedRequest(from: requests)
        _ = try await service.discoverOnce(workspacePath: "/tmp/workspace")
        await client.release("model-b")

        let targetedResult = await targeted
        XCTAssertNil(targetedResult)
        let latestSnapshot = await service.latestSnapshot(workspacePath: "/tmp/workspace")
        let latest = try XCTUnwrap(latestSnapshot?.models)
        XCTAssertEqual(latest.options.map(\.rawValue), ["model-a"])
        XCTAssertEqual(cursorParameterValues(latest), ["model-a": "new-a"])
    }

    func testCursorBaselineRefreshRetainsCompletedTargetedParametersForAdvertisedModels() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        addTeardownBlock {
            AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            cursorSnapshot(
                currentModelRaw: "model-a",
                valuesByModel: ["model-a": "old-a", "model-b": "old-b"]
            ),
            for: .cursor
        ))
        let client = TargetedCursorDiscoveryClient(
            baselineResult: cursorSnapshot(
                currentModelRaw: "model-a",
                valuesByModel: ["model-a": "new-a"]
            ),
            results: [
                "model-b": cursorSnapshot(currentModelRaw: "model-b", valuesByModel: ["model-b": "new-b"])
            ]
        )
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }

        await client.release("model-b")
        let targetedRefreshSucceeded = await service.refreshModelParameters(for: "model-b", workspacePath: nil)
        XCTAssertNotNil(targetedRefreshSucceeded)
        _ = try await service.discoverOnce(workspacePath: nil)

        let latestSnapshot = await service.latestSnapshot(workspacePath: nil)
        let merged = try XCTUnwrap(latestSnapshot?.models)
        XCTAssertEqual(merged.currentModelRaw, "model-a")
        XCTAssertEqual(cursorParameterValues(merged), ["model-a": "new-a", "model-b": "new-b"])
    }

    func testCursorModelOnlyBaselineRemovesParametersForInspectedModel() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let client = SequencedCursorDiscoveryClient(baselineResults: [
            cursorSnapshot(
                currentModelRaw: "model-a",
                valuesByModel: ["model-a": "old-a", "model-b": "old-b"]
            ),
            cursorSnapshot(currentModelRaw: "model-a", valuesByModel: [:])
        ])
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }

        _ = try await service.discoverOnce(workspacePath: nil)
        _ = try await service.discoverOnce(workspacePath: nil)

        let latestSnapshot = await service.latestSnapshot(workspacePath: nil)
        let merged = try XCTUnwrap(latestSnapshot?.models)
        XCTAssertEqual(cursorParameterValues(merged), ["model-b": "old-b"])
    }

    func testCursorConcurrentBaselineThenTargetedCompletionRetainsBothParameterSets() async throws {
        try await assertCursorConcurrentMerge(baselineCompletesFirst: true)
    }

    func testCursorConcurrentTargetedThenBaselineCompletionRetainsBothParameterSets() async throws {
        try await assertCursorConcurrentMerge(baselineCompletesFirst: false)
    }

    func testCursorBaselineRefreshPrunesParametersForRemovedModels() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            cursorSnapshot(
                currentModelRaw: "model-a",
                valuesByModel: ["model-a": "old-a", "model-b": "old-b"]
            ),
            for: .cursor
        ))
        let client = TargetedCursorDiscoveryClient(
            baselineResult: cursorSnapshot(
                currentModelRaw: "model-a",
                advertisedModels: ["model-a"],
                valuesByModel: ["model-a": "new-a"]
            ),
            results: [:]
        )
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }

        _ = try await service.discoverOnce(workspacePath: nil)

        let latestSnapshot = await service.latestSnapshot(workspacePath: nil)
        let merged = try XCTUnwrap(latestSnapshot?.models)
        XCTAssertEqual(merged.options.map(\.rawValue), ["model-a"])
        XCTAssertEqual(cursorParameterValues(merged), ["model-a": "new-a"])
    }

    func testCursorTargetedRefreshWithoutBaselineAuthorityIsDiscarded() async {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let client = TargetedCursorDiscoveryClient(results: [
            "model-b": cursorSnapshot(currentModelRaw: "model-b", valuesByModel: ["model-b": "new-b"])
        ])
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }

        await client.release("model-b")
        let succeeded = await service.refreshModelParameters(for: "model-b", workspacePath: nil)

        XCTAssertNil(succeeded)
        XCTAssertNil(AgentACPModelRegistry.shared.test_snapshot(providerID: .cursor))
    }

    func testCursorTargetedRefreshWithoutParametersRemovesCachedInspectedModelSet() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            cursorSnapshot(
                currentModelRaw: "model-a",
                valuesByModel: ["model-a": "old-a", "model-b": "old-b"]
            ),
            for: .cursor
        ))
        let client = TargetedCursorDiscoveryClient(results: [
            "model-b": cursorSnapshot(currentModelRaw: "model-b", valuesByModel: [:])
        ])
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }

        await client.release("model-b")
        let succeeded = await service.refreshModelParameters(for: "model-b", workspacePath: nil)

        let merged = try XCTUnwrap(succeeded)
        XCTAssertEqual(merged.currentModelRaw, "model-a")
        XCTAssertEqual(cursorParameterValues(merged), ["model-a": "old-a"])
    }

    func testCursorTargetedRefreshReplacesInspectedModelWhenOneParameterKindIsRemoved() async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let base = cursorSnapshot(currentModelRaw: "model-a", valuesByModel: [:])
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: base.options,
                currentModelRaw: "model-a",
                modelParameterSets: [.init(baseModelRaw: "model-b", parameters: [
                    cursorParameter(kind: .thinking, configID: "thought_level", value: "old-effort"),
                    cursorParameter(kind: .speed, configID: "fast_mode", value: "false")
                ])]
            ),
            for: .cursor
        ))
        let targeted = ACPDiscoveredSessionModels(
            options: base.options,
            currentModelRaw: "model-b",
            modelParameterSets: [.init(baseModelRaw: "model-b", parameters: [
                cursorParameter(kind: .thinking, configID: "thought_level", value: "new-effort")
            ])]
        )
        let client = TargetedCursorDiscoveryClient(results: ["model-b": targeted])
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }

        await client.release("model-b")
        let succeeded = await service.refreshModelParameters(for: "model-b", workspacePath: nil)

        let merged = try XCTUnwrap(succeeded)
        let parameters = try XCTUnwrap(merged.modelParameterSets.first { $0.baseModelRaw == "model-b" }?.parameters)
        XCTAssertEqual(parameters.map(\.kind), [.thinking])
        XCTAssertEqual(parameters.map(\.currentValueRaw), ["new-effort"])
    }

    func testTransientFallbackResolutionDoesNotMutatePersistedSelection() throws {
        let fixture = try makeStoreFixture()
        fixture.store.setGlobalContextBuilderAgentSelection(
            agentRaw: AgentProviderKind.openCode.rawValue,
            modelRaw: "openai/gpt-dynamic",
            markUserDefined: true
        )
        let before = fixture.store.persistedGlobalContextBuilderAgentSelection()

        let fallback = try XCTUnwrap(AutoRecommendationEngine.resolveContextBuilderSelection(
            persistedAgentRaw: before.agentRaw,
            persistedModelRaw: before.modelRaw,
            availability: .init(
                claudeCodeAvailable: false,
                codexAvailable: true,
                openCodeAvailable: false,
                cursorAvailable: false
            )
        ))

        XCTAssertEqual(fallback.agent, .codexExec)
        XCTAssertEqual(fixture.store.persistedGlobalContextBuilderAgentSelection().agentRaw, before.agentRaw)
        XCTAssertEqual(fixture.store.persistedGlobalContextBuilderAgentSelection().modelRaw, before.modelRaw)
    }

    func testCachedCLIFlagIsNotReadyUntilCurrentProcessVerification() {
        let keys = ["ClaudeCodeConnected", "CodexCLIConnected", "OpenCodeCLIConnected", "CursorCLIConnected"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) })
        defer {
            for (key, value) in previous {
                if let value {
                    UserDefaults.standard.set(value, forKey: key)
                } else {
                    UserDefaults.standard.removeObject(forKey: key)
                }
            }
        }

        UserDefaults.standard.set(true, forKey: "ClaudeCodeConnected")
        UserDefaults.standard.set(false, forKey: "CodexCLIConnected")
        UserDefaults.standard.set(false, forKey: "OpenCodeCLIConnected")
        UserDefaults.standard.set(false, forKey: "CursorCLIConnected")

        let keyManager = KeyManager(secureService: SecureKeysService(secureStorage: TestSecureStorageBackend()))
        let viewModel = APISettingsViewModel(
            aiQueriesService: AIQueriesService(keyManager: keyManager),
            keyManager: keyManager,
            loadStoredDataOnInit: false
        )

        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .configured)
        XCTAssertFalse(viewModel.contextBuilderRestorationAvailabilityContext.claudeCodeAvailable)

        viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [])
        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .notConfigured)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ClaudeCodeConnected"))

        viewModel.test_completeContextBuilderProviderValidation(verifiedProviders: [.claudeCode])
        XCTAssertEqual(viewModel.recommendationProviderStatusSnapshot.claudeCodeCLI, .ready)
        XCTAssertTrue(viewModel.contextBuilderRestorationAvailabilityContext.claudeCodeAvailable)
    }

    private func awaitFirstEvent(
        _ stream: AsyncStream<Void>,
        description: String,
        timeout: TimeInterval = 1
    ) async {
        let observed = expectation(description: description)
        let observer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            if await iterator.next() != nil {
                observed.fulfill()
            }
        }
        await fulfillment(of: [observed], timeout: timeout)
        observer.cancel()
    }

    private func liveOpenCodeSnapshot(
        from stream: AsyncStream<OpenCodeACPModelPollingService.Snapshot>,
        timeout: TimeInterval = 1
    ) async -> OpenCodeACPModelPollingService.Snapshot? {
        var liveSnapshot: OpenCodeACPModelPollingService.Snapshot?
        let observed = expectation(description: "OpenCode emitted a live model snapshot")
        let observer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            while let snapshot = await iterator.next() {
                guard snapshot.isLiveDiscovery else { continue }
                liveSnapshot = snapshot
                observed.fulfill()
                return
            }
        }
        await fulfillment(of: [observed], timeout: timeout)
        observer.cancel()
        return liveSnapshot
    }

    private func liveCursorSnapshot(
        from stream: AsyncStream<CursorACPModelPollingService.Snapshot>,
        timeout: TimeInterval = 1
    ) async -> CursorACPModelPollingService.Snapshot? {
        var liveSnapshot: CursorACPModelPollingService.Snapshot?
        let observed = expectation(description: "Cursor emitted a live model snapshot")
        let observer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            while let snapshot = await iterator.next() {
                guard snapshot.isLiveDiscovery else { continue }
                liveSnapshot = snapshot
                observed.fulfill()
                return
            }
        }
        await fulfillment(of: [observed], timeout: timeout)
        observer.cancel()
        return liveSnapshot
    }

    private func nextCursorTargetedRequest(
        from stream: AsyncStream<TargetedCursorDiscoveryClient.Request>,
        timeout: TimeInterval = 1
    ) async -> TargetedCursorDiscoveryClient.Request? {
        var request: TargetedCursorDiscoveryClient.Request?
        let observed = expectation(description: "Cursor targeted discovery request")
        let observer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            if let next = await iterator.next() {
                request = next
                observed.fulfill()
            }
        }
        await fulfillment(of: [observed], timeout: timeout)
        observer.cancel()
        return request
    }

    private func cursorParameterValue(
        from stream: AsyncStream<CursorACPModelPollingService.Snapshot>,
        modelRaw: String,
        timeout: TimeInterval = 1
    ) async -> String? {
        var value: String?
        let observed = expectation(description: "Cursor emitted workspace model parameters")
        let observer = Task { @MainActor in
            var iterator = stream.makeAsyncIterator()
            while let snapshot = await iterator.next() {
                if let parameter = snapshot.models.modelParameterSets.first(where: { $0.baseModelRaw == modelRaw })?
                    .parameters.first
                {
                    value = parameter.currentValueRaw
                    observed.fulfill()
                    return
                }
            }
        }
        await fulfillment(of: [observed], timeout: timeout)
        observer.cancel()
        return value
    }

    private func cursorSnapshot(
        currentModelRaw: String?,
        advertisedModels: [String] = ["model-a", "model-b"],
        valuesByModel: [String: String]
    ) -> ACPDiscoveredSessionModels {
        let options = advertisedModels.map { model in
            AgentModelOption(
                rawValue: model,
                displayName: model,
                description: nil,
                isPlaceholderDefault: false,
                isProviderDefault: model == currentModelRaw
            )
        }
        return ACPDiscoveredSessionModels(
            options: options,
            currentModelRaw: currentModelRaw,
            modelParameterSets: valuesByModel.sorted { $0.key < $1.key }.map { model, value in
                .init(baseModelRaw: model, parameters: [.init(
                    kind: .thinking,
                    configID: "thought_level",
                    displayName: "Effort",
                    choices: [.init(rawValue: value, displayName: value)],
                    currentValueRaw: value
                )])
            }
        )
    }

    private func assertCursorConcurrentMerge(baselineCompletesFirst: Bool) async throws {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            cursorSnapshot(
                currentModelRaw: "model-a",
                valuesByModel: ["model-a": "old-a", "model-b": "old-b"]
            ),
            for: .cursor
        ))
        let client = TargetedCursorDiscoveryClient(
            baselineResult: cursorSnapshot(
                currentModelRaw: "model-a",
                valuesByModel: ["model-a": "new-a"]
            ),
            gateBaseline: true,
            results: [
                "model-b": cursorSnapshot(currentModelRaw: "model-b", valuesByModel: ["model-b": "new-b"])
            ]
        )
        let service = CursorACPModelPollingService(client: client, intervalNanos: 60_000_000_000)
        addTeardownBlock { await service.shutdown() }
        let requests = await client.requests()

        let baseline = Task { try await service.discoverOnce(workspacePath: nil) }
        let baselineRequest = await nextCursorTargetedRequest(from: requests)
        XCTAssertNil(baselineRequest?.preferredModelRaw)
        async let targeted = service.refreshModelParameters(for: "model-b", workspacePath: nil)
        let targetedRequest = await nextCursorTargetedRequest(from: requests)
        XCTAssertEqual(targetedRequest?.preferredModelRaw, "model-b")
        if baselineCompletesFirst {
            await client.releaseBaseline()
            _ = try await baseline.value
            await client.release("model-b")
            let targetedSucceeded = await targeted
            XCTAssertNotNil(targetedSucceeded)
        } else {
            await client.release("model-b")
            let targetedSucceeded = await targeted
            XCTAssertNotNil(targetedSucceeded)
            await client.releaseBaseline()
            _ = try await baseline.value
        }

        let latestSnapshot = await service.latestSnapshot(workspacePath: nil)
        let merged = try XCTUnwrap(latestSnapshot?.models)
        XCTAssertEqual(merged.currentModelRaw, "model-a")
        XCTAssertEqual(cursorParameterValues(merged), ["model-a": "new-a", "model-b": "new-b"])
    }

    private func cursorParameterValues(_ snapshot: ACPDiscoveredSessionModels) -> [String: String] {
        Dictionary(uniqueKeysWithValues: snapshot.modelParameterSets.compactMap { set in
            set.parameters.first.map { (set.baseModelRaw, $0.currentValueRaw) }
        })
    }

    private func cursorParameter(
        kind: ACPModelParameterKind,
        configID: String,
        value: String
    ) -> ACPModelParameterDefinition {
        .init(
            kind: kind,
            configID: configID,
            displayName: kind == .thinking ? "Effort" : "Speed",
            choices: [.init(rawValue: value, displayName: value)],
            currentValueRaw: value
        )
    }

    private func makeStoreFixture() throws -> (
        store: GlobalSettingsStore,
        defaults: UserDefaults,
        fileStore: GlobalSettingsFileStore
    ) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextBuilderModelStartupSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }

        let suiteName = "ContextBuilderModelStartupSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileStore = GlobalSettingsFileStore(
            fileURL: temp.appendingPathComponent("Settings/globalSettings.json")
        )
        return (GlobalSettingsStore(defaults: defaults, fileStore: fileStore), defaults, fileStore)
    }
}

private actor DiscoveryGate {
    private var calls = 0
    private var isReleased = false
    private var discoveryStartedObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func discoveryStartedEvents() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        discoveryStartedObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDiscoveryStartedObserver(id) }
        }
        if calls > 0 {
            continuation.yield(())
        }
        return stream
    }

    func waitForReleaseAfterRecordingDiscoveryStarted() async {
        calls += 1
        publishDiscoveryStarted()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func callCount() -> Int {
        calls
    }

    private func publishDiscoveryStarted() {
        for continuation in discoveryStartedObservers.values {
            continuation.yield(())
        }
    }

    private func removeDiscoveryStartedObserver(_ id: UUID) {
        discoveryStartedObservers.removeValue(forKey: id)
    }
}

private actor GatedOpenCodeDiscoveryClient: OpenCodeACPModelDiscoveryClient {
    private let result: ACPDiscoveredSessionModels?
    private let gate: DiscoveryGate

    init(result: ACPDiscoveredSessionModels?, gate: DiscoveryGate) {
        self.result = result
        self.gate = gate
    }

    func discoverModels(workspacePath _: String?) async throws -> ACPDiscoveredSessionModels? {
        await gate.waitForReleaseAfterRecordingDiscoveryStarted()
        return result
    }
}

private actor GatedCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    private let result: ACPDiscoveredSessionModels?
    private let gate: DiscoveryGate

    init(result: ACPDiscoveredSessionModels?, gate: DiscoveryGate) {
        self.result = result
        self.gate = gate
    }

    func discoverModels(
        workspacePath _: String?,
        preferredModelRaw _: String?
    ) async throws -> ACPDiscoveredSessionModels? {
        await gate.waitForReleaseAfterRecordingDiscoveryStarted()
        return result
    }
}

private actor SequencedCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    private var baselineResults: [ACPDiscoveredSessionModels]

    init(baselineResults: [ACPDiscoveredSessionModels]) {
        self.baselineResults = baselineResults
    }

    func discoverModels(
        workspacePath _: String?,
        preferredModelRaw: String?
    ) async throws -> ACPDiscoveredSessionModels? {
        guard preferredModelRaw == nil, !baselineResults.isEmpty else { return nil }
        return baselineResults.removeFirst()
    }
}

private actor TargetedCursorDiscoveryClient: CursorACPModelDiscoveryClient {
    struct Request {
        let workspacePath: String?
        let preferredModelRaw: String?
    }

    private let baselineResult: ACPDiscoveredSessionModels?
    private var isBaselineReleased: Bool
    private var baselineWaiters: [CheckedContinuation<Void, Never>] = []
    private let results: [String: ACPDiscoveredSessionModels]
    private let workspaceResults: [String: [String: ACPDiscoveredSessionModels]]
    private var releasedModels: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var requestObservers: [UUID: AsyncStream<Request>.Continuation] = [:]

    init(
        baselineResult: ACPDiscoveredSessionModels? = nil,
        gateBaseline: Bool = false,
        results: [String: ACPDiscoveredSessionModels],
        workspaceResults: [String: [String: ACPDiscoveredSessionModels]] = [:]
    ) {
        self.baselineResult = baselineResult
        isBaselineReleased = !gateBaseline
        self.results = results
        self.workspaceResults = workspaceResults
    }

    func requests() -> AsyncStream<Request> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Request>.makeStream(bufferingPolicy: .unbounded)
        requestObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeRequestObserver(id) }
        }
        return stream
    }

    func release(_ model: String) {
        releasedModels.insert(model)
        let modelWaiters = waiters.removeValue(forKey: model) ?? []
        for waiter in modelWaiters {
            waiter.resume()
        }
    }

    func releaseBaseline() {
        guard !isBaselineReleased else { return }
        isBaselineReleased = true
        let waiters = baselineWaiters
        baselineWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func removeRequestObserver(_ id: UUID) {
        requestObservers.removeValue(forKey: id)
    }

    func discoverModels(
        workspacePath: String?,
        preferredModelRaw: String?
    ) async throws -> ACPDiscoveredSessionModels? {
        let request = Request(workspacePath: workspacePath, preferredModelRaw: preferredModelRaw)
        for observer in requestObservers.values {
            observer.yield(request)
        }
        guard let preferredModelRaw else {
            if !isBaselineReleased {
                await withCheckedContinuation { continuation in
                    baselineWaiters.append(continuation)
                }
            }
            return baselineResult
        }
        if !releasedModels.contains(preferredModelRaw) {
            await withCheckedContinuation { continuation in
                waiters[preferredModelRaw, default: []].append(continuation)
            }
        }
        if let workspacePath,
           let result = workspaceResults[workspacePath]?[preferredModelRaw]
        {
            return result
        }
        return results[preferredModelRaw]
    }
}
