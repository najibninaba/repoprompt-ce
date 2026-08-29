import Foundation
import MCP

extension AgentModeViewModel {
    func mcpStageModelParameterSelections(
        tabID: UUID,
        agentRaw: String?,
        modelRaw: String?,
        selections: [ACPModelParameterSelection]
    ) throws {
        guard !selections.isEmpty else { return }
        guard agentRaw == AgentProviderKind.cursor.rawValue,
              let modelRaw
        else {
            throw MCPError.invalidParams("Cursor model parameters require an explicit Cursor model selection.")
        }
        try mcpStoreModelParameterSelections(
            tabID: tabID,
            selectedAgent: .cursor,
            selectedModelRaw: modelRaw,
            selections: selections,
            schedulePersistence: false
        )
    }

    func mcpApplyModelParameterSelections(
        tabID: UUID,
        selections: [ACPModelParameterSelection]
    ) throws {
        guard !selections.isEmpty else { return }
        guard let session = session(for: tabID, createIfNeeded: false) else {
            throw MCPError.internalError("Failed to resolve the Agent session for model parameter configuration.")
        }
        try mcpStoreModelParameterSelections(
            tabID: tabID,
            selectedAgent: session.selectedAgent,
            selectedModelRaw: session.selectedModelRaw,
            selections: selections,
            schedulePersistence: true
        )
    }

    private func mcpStoreModelParameterSelections(
        tabID: UUID,
        selectedAgent: AgentProviderKind,
        selectedModelRaw: String,
        selections: [ACPModelParameterSelection],
        schedulePersistence: Bool
    ) throws {
        guard let session = session(for: tabID, createIfNeeded: false) else {
            throw MCPError.internalError("Failed to resolve the Agent session for model parameter configuration.")
        }
        guard selectedAgent == .cursor else {
            throw MCPError.invalidParams("Cursor model parameters cannot be applied to \(selectedAgent.displayName).")
        }
        let selectedModelIdentity = ACPAIModelCatalog.normalizedCursorModelAlias(selectedModelRaw)
        guard selections.allSatisfy({
            $0.providerID == .cursor
                && ACPAIModelCatalog.normalizedCursorModelAlias($0.baseModelRaw) == selectedModelIdentity
        }) else {
            throw MCPError.invalidParams("Cursor model parameters do not match the configured base model.")
        }

        session.acpModelParameterSelections = ACPModelParameterSelection.normalized(
            session.acpModelParameterSelections + selections
        )
        if schedulePersistence {
            scheduleSave(for: tabID)
        }
        if tabID == currentTabID {
            syncComposerUIState()
            syncRunInteractionUIState()
        }
    }
}
