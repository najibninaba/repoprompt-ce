import Foundation

enum ACPModelParameterKind: String, Codable, Hashable, CaseIterable {
    case thinking
    case speed

    var sortOrder: Int {
        switch self {
        case .thinking: 0
        case .speed: 1
        }
    }
}

struct ACPModelParameterChoice: Codable, Hashable {
    let rawValue: String
    let displayName: String
    let description: String?

    init(rawValue: String, displayName: String, description: String? = nil) {
        self.rawValue = rawValue
        self.displayName = displayName
        self.description = description
    }
}

struct ACPModelParameterDefinition: Codable, Hashable {
    let kind: ACPModelParameterKind
    let configID: String
    let displayName: String
    let choices: [ACPModelParameterChoice]
    let currentValueRaw: String

    func choice(matching requestedValue: String) -> ACPModelParameterChoice? {
        if let exact = choices.first(where: { $0.rawValue == requestedValue }) {
            return exact
        }
        let matches = choices.filter {
            $0.rawValue.caseInsensitiveCompare(requestedValue) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct ACPModelParameterSet: Codable, Hashable {
    let baseModelRaw: String
    let parameters: [ACPModelParameterDefinition]

    func definition(configID: String) -> ACPModelParameterDefinition? {
        parameters.first { $0.configID == configID }
    }
}

struct ACPModelParameterSelection: Codable, Hashable {
    let providerID: ACPProviderID
    let baseModelRaw: String
    let kind: ACPModelParameterKind
    let configID: String
    let valueRaw: String

    var identity: ACPModelParameterIdentity {
        ACPModelParameterIdentity(
            providerID: providerID,
            baseModelRaw: baseModelRaw,
            kind: kind,
            configID: configID
        )
    }

    static func normalized(_ selections: [Self]) -> [Self] {
        var valueByIdentity: [ACPModelParameterIdentity: Self] = [:]
        var orderedIdentities: [ACPModelParameterIdentity] = []
        for selection in selections {
            let identity = selection.identity
            if valueByIdentity[identity] == nil {
                orderedIdentities.append(identity)
            }
            valueByIdentity[identity] = selection
        }
        return orderedIdentities.compactMap { valueByIdentity[$0] }
    }

    static func selections(
        for providerID: ACPProviderID,
        activeBaseModelRaw: String,
        from selections: [Self]
    ) -> [Self] {
        let activeIdentity = ACPModelParameterIdentity.canonicalBaseModelRaw(
            activeBaseModelRaw,
            providerID: providerID
        )
        return normalized(selections).filter {
            $0.providerID == providerID
                && ACPModelParameterIdentity.canonicalBaseModelRaw(
                    $0.baseModelRaw,
                    providerID: providerID
                ) == activeIdentity
        }
    }
}

struct ACPModelParameterIdentity: Hashable {
    let providerID: ACPProviderID
    let canonicalBaseModelRaw: String
    let kind: ACPModelParameterKind
    let configID: String

    init(
        providerID: ACPProviderID,
        baseModelRaw: String,
        kind: ACPModelParameterKind,
        configID: String
    ) {
        self.providerID = providerID
        canonicalBaseModelRaw = Self.canonicalBaseModelRaw(baseModelRaw, providerID: providerID)
        self.kind = kind
        self.configID = configID
    }

    fileprivate static func canonicalBaseModelRaw(_ raw: String, providerID: ACPProviderID) -> String {
        if providerID == .cursor {
            return ACPAIModelCatalog.normalizedCursorModelAlias(raw)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct ACPResolvedModelParameter: Equatable {
    let baseModelRaw: String
    let definition: ACPModelParameterDefinition
    let selectedChoice: ACPModelParameterChoice
}

enum ACPModelParameterResolver {
    static func resolve(
        providerID: ACPProviderID,
        selectedModelRaw: String,
        snapshot: ACPDiscoveredSessionModels?,
        persistedSelections: [ACPModelParameterSelection]
    ) -> [ACPResolvedModelParameter] {
        guard providerID == .cursor,
              let snapshot,
              let parameterSet = cursorParameterSet(selectedModelRaw: selectedModelRaw, snapshot: snapshot)
        else { return [] }
        return parameterSet.parameters.sorted { $0.kind.sortOrder < $1.kind.sortOrder }.compactMap { definition in
            let definitionIdentity = ACPModelParameterIdentity(
                providerID: providerID,
                baseModelRaw: parameterSet.baseModelRaw,
                kind: definition.kind,
                configID: definition.configID
            )
            let saved = persistedSelections.last { selection in
                selection.identity == definitionIdentity
            }
            guard let selectedChoice = saved.flatMap({ definition.choice(matching: $0.valueRaw) })
                ?? definition.choice(matching: definition.currentValueRaw)
            else { return nil }
            return .init(
                baseModelRaw: parameterSet.baseModelRaw,
                definition: definition,
                selectedChoice: selectedChoice
            )
        }
    }

    static func cursorParameterSet(
        selectedModelRaw: String,
        snapshot: ACPDiscoveredSessionModels
    ) -> ACPModelParameterSet? {
        let selectedAlias = ACPAIModelCatalog.normalizedCursorModelAlias(selectedModelRaw)
        guard let option = snapshot.options.first(where: {
            ACPAIModelCatalog.normalizedCursorModelAlias($0.rawValue) == selectedAlias
                || ACPAIModelCatalog.normalizedCursorModelAlias($0.displayName) == selectedAlias
        }) else { return nil }
        return snapshot.modelParameterSets.first {
            ACPAIModelCatalog.normalizedCursorModelAlias($0.baseModelRaw)
                == ACPAIModelCatalog.normalizedCursorModelAlias(option.rawValue)
        }
    }
}
