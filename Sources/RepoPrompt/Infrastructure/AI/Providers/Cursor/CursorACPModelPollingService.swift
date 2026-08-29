import Foundation

protocol CursorACPModelDiscoveryClient: Sendable {
    func discoverModels(
        workspacePath: String?,
        preferredModelRaw: String?
    ) async throws -> ACPDiscoveredSessionModels?
}

struct CursorACPControllerModelDiscoveryClient: CursorACPModelDiscoveryClient {
    typealias ProviderFactory = @Sendable (_ agent: AgentProviderKind, _ modelString: String?) async throws -> (any ACPAgentProvider)?
    typealias ControllerFactory = @Sendable (_ provider: any ACPAgentProvider, _ runRequest: ACPRunRequest) throws -> ACPAgentSessionController

    private let providerFactory: ProviderFactory
    private let controllerFactory: ControllerFactory

    init(
        providerFactory: @escaping ProviderFactory = { agent, modelString in
            if agent == .cursor {
                return CursorACPAgentProvider(
                    config: CursorAgentConfig(
                        enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
                        modelString: modelString,
                        includeRepoPromptMCPServer: false,
                        cleanupProjectMCPApproval: false
                    )
                )
            }
            return try await ACPAgentProviderFactory.makeProvider(for: agent, modelString: modelString)
        },
        controllerFactory: @escaping ControllerFactory = { provider, runRequest in
            try ACPAgentSessionController(provider: provider, runRequest: runRequest)
        }
    ) {
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func discoverModels(
        workspacePath: String?,
        preferredModelRaw: String?
    ) async throws -> ACPDiscoveredSessionModels? {
        let trimmedPreferredModel = preferredModelRaw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredModel: String? = if let trimmedPreferredModel, !trimmedPreferredModel.isEmpty {
            trimmedPreferredModel
        } else {
            nil
        }
        let request = ACPRunRequest(
            agentKind: .cursor,
            modelString: preferredModel,
            workspacePath: workspacePath,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
        guard let provider = try await providerFactory(.cursor, preferredModel) else { return nil }
        let support = try await provider.support(for: request)
        guard support == .supported else {
            throw AIProviderError.invalidConfiguration(
                detail: support.reason ?? "Cursor ACP is not available."
            )
        }

        let controller = try controllerFactory(provider, request)
        do {
            _ = try await controller.bootstrap()
            if let preferredModel {
                try await controller.setSessionModel(preferredModel)
            }
            let snapshot = await controller.currentDiscoveredSessionModels()
            await controller.shutdown()
            return snapshot
        } catch {
            await controller.shutdown()
            throw error
        }
    }
}

// SEARCH-HELPER: Cursor ACP model polling, dynamic discovery, subscribe, registry refresh
/// Centralized polling service for Cursor ACP dynamic model options.
///
/// Cursor can expose model metadata through ACP session bootstrap responses. This mirrors the
/// OpenCode model discovery path while preserving Cursor's static Auto fallback when no
/// dynamic model metadata is available yet.
actor CursorACPModelPollingService {
    static let shared = CursorACPModelPollingService(
        client: CursorACPControllerModelDiscoveryClient()
    )

    struct Snapshot: Equatable {
        let models: ACPDiscoveredSessionModels
        let fetchedAt: Date
        let isLiveDiscovery: Bool
    }

    private let client: any CursorACPModelDiscoveryClient
    private let intervalNanos: UInt64

    private var pollingTask: Task<Void, Never>?
    private var inFlightRefresh: Task<Bool, Never>?
    private var inFlightTargetedRefreshes: [TargetedRequestIdentity: Task<ACPDiscoveredSessionModels?, Never>] = [:]
    private var continuations: [UUID: Subscriber] = [:]
    #if DEBUG
        private var testRefreshNowInFlightJoinObservers: [UUID: AsyncStream<Void>.Continuation] = [:]
    #endif
    private var latest: Snapshot?
    private var workspaceModels: [WorkspaceIdentity: ACPDiscoveredSessionModels] = [:]
    private var preferredWorkspacePath: String?
    private var baselineGeneration: UInt64 = 0
    private var isShutdown = false

    private struct WorkspaceIdentity: Hashable {
        let normalizedPath: String?
    }

    private struct TargetedRequestIdentity: Hashable {
        let workspace: WorkspaceIdentity
        let normalizedModel: String
    }

    private struct Subscriber {
        let workspace: WorkspaceIdentity
        let continuation: AsyncStream<Snapshot>.Continuation
    }

    init(
        client: any CursorACPModelDiscoveryClient,
        intervalNanos: UInt64 = 300_000_000_000
    ) {
        self.client = client
        self.intervalNanos = intervalNanos
    }

    func latestSnapshot() async -> Snapshot? {
        if let latest {
            return latest
        }
        return await registrySnapshotAfterWarmingStore()
    }

    func latestSnapshot(workspacePath: String?) async -> Snapshot? {
        let workspace = workspaceIdentity(workspacePath)
        if let models = workspaceModels[workspace] {
            return Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: true)
        }
        return await latestSnapshot()
    }

    /// Resolves parameter metadata for one Cursor model within one workspace.
    ///
    /// Parameter definitions and current values are session-derived and can vary by
    /// workspace. Callers must not fall back to the provider-global registry, which
    /// intentionally contains only the model catalog. A cached workspace result is
    /// reused when it already contains the requested model; otherwise this performs
    /// the model-targeted discovery needed to populate that workspace-local authority.
    func modelParameterSnapshot(
        for selectedModelRaw: String,
        workspacePath: String?
    ) async -> ACPDiscoveredSessionModels? {
        let normalizedModel = ACPAIModelCatalog.normalizedCursorModelAlias(selectedModelRaw)
        guard !normalizedModel.isEmpty else { return nil }
        let workspace = workspaceIdentity(workspacePath)
        if let cached = workspaceModels[workspace],
           ACPModelParameterResolver.cursorParameterSet(
               selectedModelRaw: selectedModelRaw,
               snapshot: cached
           ) != nil
        {
            return cached
        }

        if latest == nil || workspaceModels[workspace] == nil {
            _ = await refreshNow(workspacePath: workspacePath)
        }
        if let cached = workspaceModels[workspace],
           ACPModelParameterResolver.cursorParameterSet(
               selectedModelRaw: selectedModelRaw,
               snapshot: cached
           ) != nil
        {
            return cached
        }
        return await refreshModelParameters(
            for: selectedModelRaw,
            workspacePath: workspacePath
        )
    }

    #if DEBUG
        func test_refreshNowInFlightJoinEvents() -> AsyncStream<Void> {
            let id = UUID()
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            testRefreshNowInFlightJoinObservers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTestRefreshNowInFlightJoinObserver(id) }
            }
            return stream
        }
    #endif

    func discoverOnce(workspacePath: String?) async throws -> Snapshot? {
        guard !isShutdown else { return nil }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        let generation = beginBaselineRefresh()
        guard let discovered = try await client.discoverModels(
            workspacePath: preferredWorkspacePath,
            preferredModelRaw: nil
        ) else {
            return nil
        }
        let workspace = workspaceIdentity(preferredWorkspacePath)
        applyBaselineRefreshResult(discovered, workspace: workspace, generation: generation)
        return await latestSnapshot(workspacePath: preferredWorkspacePath)
    }

    func subscribe(workspacePath: String?) async -> AsyncStream<Snapshot> {
        guard !isShutdown else {
            return AsyncStream { continuation in
                continuation.finish()
            }
        }

        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        let workspace = workspaceIdentity(preferredWorkspacePath)
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = Subscriber(workspace: workspace, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }

        if latest == nil, let cached = await registrySnapshotAfterWarmingStore() {
            guard !isShutdown else {
                continuation.finish()
                return stream
            }
            if latest == nil {
                latest = cached
            }
        }
        if let models = workspaceModels[workspace] {
            continuation.yield(Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: true))
        } else if let latest {
            continuation.yield(latest)
        }

        guard !isShutdown else { return stream }
        startPollingIfNeeded()
        return stream
    }

    @discardableResult
    func refreshNow(workspacePath: String?) async -> Bool {
        guard !isShutdown else { return false }
        preferredWorkspacePath = normalizedWorkspacePath(workspacePath)
        if let existing = inFlightRefresh {
            #if DEBUG
                publishTestRefreshNowInFlightJoin()
            #endif
            return await existing.value
        }
        return await performRefresh()
    }

    @discardableResult
    func refreshModelParameters(
        for selectedModelRaw: String,
        workspacePath: String?
    ) async -> ACPDiscoveredSessionModels? {
        guard !isShutdown else { return nil }
        let normalizedModel = ACPAIModelCatalog.normalizedCursorModelAlias(selectedModelRaw)
        guard !normalizedModel.isEmpty else { return nil }
        let normalizedWorkspacePath = normalizedWorkspacePath(workspacePath)
        preferredWorkspacePath = normalizedWorkspacePath
        let requestIdentity = TargetedRequestIdentity(
            workspace: workspaceIdentity(normalizedWorkspacePath),
            normalizedModel: normalizedModel
        )
        if let existing = inFlightTargetedRefreshes[requestIdentity] {
            return await existing.value
        }

        let capturedGeneration = baselineGeneration
        let task = Task<ACPDiscoveredSessionModels?, Never> {
            [weak self, selectedModelRaw, normalizedWorkspacePath, requestIdentity, capturedGeneration] in
            guard let self else { return nil }
            do {
                guard let discovered = try await client.discoverModels(
                    workspacePath: normalizedWorkspacePath,
                    preferredModelRaw: selectedModelRaw
                ), !Task.isCancelled else { return nil }
                return await applyTargetedRefreshResult(
                    discovered,
                    request: requestIdentity,
                    baselineGeneration: capturedGeneration
                )
            } catch {
                return nil
            }
        }
        inFlightTargetedRefreshes[requestIdentity] = task
        let result = await task.value
        inFlightTargetedRefreshes.removeValue(forKey: requestIdentity)
        return result
    }

    func shutdown(finishSubscribers: Bool = true) async {
        isShutdown = true
        pollingTask?.cancel()
        pollingTask = nil
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        for task in inFlightTargetedRefreshes.values {
            task.cancel()
        }
        inFlightTargetedRefreshes.removeAll()
        #if DEBUG
            let activeTestJoinObservers = testRefreshNowInFlightJoinObservers
            testRefreshNowInFlightJoinObservers.removeAll()
            for continuation in activeTestJoinObservers.values {
                continuation.finish()
            }
        #endif
        if finishSubscribers {
            let activeContinuations = continuations
            continuations.removeAll()
            for subscriber in activeContinuations.values {
                subscriber.continuation.finish()
            }
        }
    }

    private func startPollingIfNeeded() {
        guard !isShutdown else { return }
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                _ = await performRefresh()
                do {
                    try await Task.sleep(nanoseconds: intervalNanos)
                } catch {
                    break
                }
            }
        }
    }

    private func stopPollingIfIdle() {
        guard continuations.isEmpty else { return }
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func removeSubscriber(_ id: UUID) {
        continuations.removeValue(forKey: id)
        stopPollingIfIdle()
    }

    #if DEBUG
        private func publishTestRefreshNowInFlightJoin() {
            for continuation in testRefreshNowInFlightJoinObservers.values {
                continuation.yield(())
            }
        }

        private func removeTestRefreshNowInFlightJoinObserver(_ id: UUID) {
            testRefreshNowInFlightJoinObservers.removeValue(forKey: id)
        }
    #endif

    private func performRefresh() async -> Bool {
        guard !isShutdown else { return false }
        if let existing = inFlightRefresh {
            return await existing.value
        }

        let workspacePath = preferredWorkspacePath
        let generation = beginBaselineRefresh()
        let task = Task<Bool, Never> { [weak self, workspacePath, generation] in
            guard let self else { return false }
            do {
                let discovered = try await client.discoverModels(
                    workspacePath: workspacePath,
                    preferredModelRaw: nil
                )
                guard !Task.isCancelled else { return false }
                if let discovered {
                    await applyBaselineRefreshResult(
                        discovered,
                        workspace: workspaceIdentity(workspacePath),
                        generation: generation
                    )
                } else {
                    await publishLiveReadinessWithoutModels(generation: generation)
                }
                return true
            } catch {
                // Keep the last registry/cache snapshot when preflight or ACP discovery fails.
                return false
            }
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return await task.value
    }

    private func publishLiveReadinessWithoutModels(generation: UInt64) {
        guard !isShutdown, generation == baselineGeneration else { return }
        let models = latest?.models
            ?? AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)
            ?? ACPDiscoveredSessionModels(options: [], currentModelRaw: nil)
        let snapshot = Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: true)
        guard latest?.models != snapshot.models || latest?.isLiveDiscovery == false else { return }
        latest = snapshot
        for subscriber in continuations.values {
            let subscriberSnapshot = Snapshot(
                models: workspaceModels[subscriber.workspace] ?? models,
                fetchedAt: snapshot.fetchedAt,
                isLiveDiscovery: true
            )
            subscriber.continuation.yield(subscriberSnapshot)
        }
    }

    private func beginBaselineRefresh() -> UInt64 {
        baselineGeneration &+= 1
        return baselineGeneration
    }

    private func applyBaselineRefreshResult(
        _ discovered: ACPDiscoveredSessionModels,
        workspace: WorkspaceIdentity,
        generation: UInt64
    ) {
        guard !isShutdown, generation == baselineGeneration else { return }
        let priorWorkspaceModels = workspaceModels[workspace]
        let workspaceBaseline = mergeBaseline(discovered, retainingParametersFrom: priorWorkspaceModels)
        let providerBaseline = ACPDiscoveredSessionModels(
            options: discovered.options,
            currentModelRaw: discovered.currentModelRaw,
            currentEffortRaw: discovered.currentEffortRaw,
            modelParameterSets: []
        )
        _ = AgentACPModelRegistry.shared.updateDiscoveredModels(providerBaseline, for: .cursor)
        guard let normalized = AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor) else { return }
        let snapshot = Snapshot(models: normalized, fetchedAt: Date(), isLiveDiscovery: true)
        latest = snapshot

        for existingWorkspace in Array(workspaceModels.keys) where existingWorkspace != workspace {
            if let prior = workspaceModels[existingWorkspace] {
                workspaceModels[existingWorkspace] = reconcileWorkspaceModels(
                    prior,
                    with: normalized
                )
            }
        }
        workspaceModels[workspace] = reconcileWorkspaceModels(workspaceBaseline, with: normalized)
        for subscriber in continuations.values {
            let models = workspaceModels[subscriber.workspace] ?? normalized
            subscriber.continuation.yield(
                Snapshot(models: models, fetchedAt: snapshot.fetchedAt, isLiveDiscovery: true)
            )
        }
    }

    private func applyTargetedRefreshResult(
        _ discovered: ACPDiscoveredSessionModels,
        request: TargetedRequestIdentity,
        baselineGeneration capturedGeneration: UInt64
    ) -> ACPDiscoveredSessionModels? {
        guard !isShutdown, capturedGeneration == baselineGeneration else { return nil }
        guard let baseline = latest?.models ?? AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor),
              advertisedModelIdentities(in: baseline).contains(request.normalizedModel)
        else { return nil }

        // Parameter metadata is workspace-local. A workspace that joined another
        // workspace's provider-wide baseline refresh has no local parameter authority,
        // so seed it only from the parameterless provider baseline.
        let prior = workspaceModels[request.workspace] ?? baseline
        let merged = mergeTargeted(
            discovered,
            inspectedModelIdentity: request.normalizedModel,
            baseline: baseline,
            priorWorkspaceModels: prior
        )
        workspaceModels[request.workspace] = merged
        return merged
    }

    private func mergeBaseline(
        _ discovered: ACPDiscoveredSessionModels,
        retainingParametersFrom prior: ACPDiscoveredSessionModels?
    ) -> ACPDiscoveredSessionModels {
        let advertisedIdentities = advertisedModelIdentities(in: discovered)
        let inspectedIdentity = discovered.currentModelRaw.map(ACPAIModelCatalog.normalizedCursorModelAlias)
        let priorByIdentity = Dictionary(
            prior?.modelParameterSets.map {
                (ACPAIModelCatalog.normalizedCursorModelAlias($0.baseModelRaw), $0)
            } ?? [],
            uniquingKeysWith: { _, newest in newest }
        )
        var incomingByIdentity: [String: ACPModelParameterSet] = [:]
        var incomingIdentities: [String] = []
        for parameterSet in discovered.modelParameterSets {
            let identity = ACPAIModelCatalog.normalizedCursorModelAlias(parameterSet.baseModelRaw)
            guard advertisedIdentities.contains(identity) else { continue }
            if incomingByIdentity[identity] == nil {
                incomingIdentities.append(identity)
            }
            if identity != inspectedIdentity,
               let retained = priorByIdentity[identity]
            {
                incomingByIdentity[identity] = retained
            } else {
                incomingByIdentity[identity] = parameterSet
            }
        }
        let retainedSets = prior?.modelParameterSets.filter { parameterSet in
            let identity = ACPAIModelCatalog.normalizedCursorModelAlias(parameterSet.baseModelRaw)
            return advertisedIdentities.contains(identity)
                && identity != inspectedIdentity
                && incomingByIdentity[identity] == nil
        } ?? []
        return ACPDiscoveredSessionModels(
            options: discovered.options,
            currentModelRaw: discovered.currentModelRaw,
            currentEffortRaw: discovered.currentEffortRaw,
            modelParameterSets: retainedSets + incomingIdentities.compactMap { incomingByIdentity[$0] }
        )
    }

    private func mergeTargeted(
        _ discovered: ACPDiscoveredSessionModels,
        inspectedModelIdentity: String,
        baseline: ACPDiscoveredSessionModels,
        priorWorkspaceModels: ACPDiscoveredSessionModels
    ) -> ACPDiscoveredSessionModels {
        let incoming = discovered.modelParameterSets.last {
            ACPAIModelCatalog.normalizedCursorModelAlias($0.baseModelRaw) == inspectedModelIdentity
        }
        var parameterSets = priorWorkspaceModels.modelParameterSets.filter {
            ACPAIModelCatalog.normalizedCursorModelAlias($0.baseModelRaw) != inspectedModelIdentity
        }
        if let incoming {
            parameterSets.append(incoming)
        }
        let advertised = advertisedModelIdentities(in: baseline)
        parameterSets.removeAll {
            !advertised.contains(ACPAIModelCatalog.normalizedCursorModelAlias($0.baseModelRaw))
        }
        return ACPDiscoveredSessionModels(
            options: baseline.options,
            currentModelRaw: baseline.currentModelRaw,
            currentEffortRaw: baseline.currentEffortRaw,
            modelParameterSets: parameterSets
        )
    }

    private func reconcileWorkspaceModels(
        _ workspaceModels: ACPDiscoveredSessionModels,
        with baseline: ACPDiscoveredSessionModels
    ) -> ACPDiscoveredSessionModels {
        let advertised = advertisedModelIdentities(in: baseline)
        return ACPDiscoveredSessionModels(
            options: baseline.options,
            currentModelRaw: baseline.currentModelRaw,
            currentEffortRaw: baseline.currentEffortRaw,
            modelParameterSets: workspaceModels.modelParameterSets.filter {
                advertised.contains(ACPAIModelCatalog.normalizedCursorModelAlias($0.baseModelRaw))
            }
        )
    }

    private func advertisedModelIdentities(in models: ACPDiscoveredSessionModels) -> Set<String> {
        Set(models.options.flatMap { option in
            [
                ACPAIModelCatalog.normalizedCursorModelAlias(option.rawValue),
                ACPAIModelCatalog.normalizedCursorModelAlias(option.displayName)
            ]
        })
    }

    private func registrySnapshotAfterWarmingStore() async -> Snapshot? {
        guard let models = await AgentACPModelRegistry.shared.resolvedSnapshotAfterWarmingStandardStore(for: .cursor) else {
            return nil
        }
        return Snapshot(models: models, fetchedAt: Date(), isLiveDiscovery: false)
    }

    private func normalizedWorkspacePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private func workspaceIdentity(_ path: String?) -> WorkspaceIdentity {
        WorkspaceIdentity(normalizedPath: normalizedWorkspacePath(path))
    }
}
