import Foundation
@_spi(TestSupport) @testable import RepoPromptApp
import XCTest

@MainActor
final class CursorModelParameterSelectionTests: XCTestCase {
    func testChoiceResolutionPreservesExactWireValuesAndRejectsCaseCollisions() {
        let definition = ACPModelParameterDefinition(
            kind: .speed,
            configID: "Cursor.Fast-Mode",
            displayName: "Speed",
            choices: [
                .init(rawValue: "false", displayName: "Standard"),
                .init(rawValue: "TRUE", displayName: "Fast")
            ],
            currentValueRaw: "false"
        )

        XCTAssertEqual(definition.choice(matching: "TRUE")?.rawValue, "TRUE")
        XCTAssertEqual(definition.choice(matching: "true")?.rawValue, "TRUE")

        let colliding = ACPModelParameterDefinition(
            kind: .thinking,
            configID: "thought_level",
            displayName: "Effort",
            choices: [
                .init(rawValue: "High", displayName: "High"),
                .init(rawValue: "high", displayName: "High exact")
            ],
            currentValueRaw: "High"
        )
        XCTAssertNil(colliding.choice(matching: "HIGH"))
        XCTAssertEqual(colliding.choice(matching: "high")?.rawValue, "high")
    }

    func testPersistedSelectionNormalizationIsNamespacedAndLastWins() {
        let first = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "medium"
        )
        let replacement = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "high"
        )
        let otherModel = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "composer-2.5",
            kind: .thinking,
            configID: "thought_level",
            valueRaw: "low"
        )

        let normalized = ACPModelParameterSelection.normalized([first, otherModel, replacement])
        XCTAssertEqual(normalized.count, 2)
        XCTAssertEqual(normalized.first(where: { $0.baseModelRaw == "grok-4.6" })?.valueRaw, "high")
        XCTAssertEqual(normalized.first(where: { $0.baseModelRaw == "composer-2.5" })?.valueRaw, "low")
    }

    func testPersistedSelectionNormalizationUsesCursorAliasIdentityAndRetainsNewestWireSelection() {
        let first = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "Grok 4.6",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "medium"
        )
        let replacement = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "high"
        )
        let distinctKind = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .speed,
            configID: "Cursor.Thought-Level",
            valueRaw: "true"
        )

        XCTAssertEqual(
            ACPModelParameterSelection.normalized([first, replacement, distinctKind]),
            [replacement, distinctKind]
        )
    }

    func testCursorClassifierRecognizesNarrowGenericAndMissingCategoryParameters() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())
        let choices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "Cursor.Thought-Level",
            category: "model_parameter",
            displayName: "Effort",
            choices: []
        )), .thinking)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "thought_level",
            category: nil,
            displayName: "Anything",
            choices: []
        )), .thinking)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "model_config",
            displayName: "Anything",
            choices: choices
        )), .speed)
        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "Cursor.Fast-Mode",
            category: nil,
            displayName: "Anything",
            choices: choices
        )), .speed)
    }

    func testCursorClassifierRecognizesObservedFastSelectorShape() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())

        XCTAssertEqual(provider.modelParameterKind(for: .init(
            configID: "fast",
            category: "model_config",
            displayName: "Fast Mode",
            choices: [
                .init(rawValue: "false", displayName: "Off"),
                .init(rawValue: "true", displayName: "Fast")
            ]
        )), .speed)
    }

    func testCursorClassifierRejectsModelModeAndAmbiguousParameters() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())
        let speedChoices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        for category in ["model", "mode"] {
            XCTAssertNil(provider.modelParameterKind(for: .init(
                configID: "Cursor.Fast-Mode",
                category: category,
                displayName: "Speed",
                choices: speedChoices
            )))
        }
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: nil,
            displayName: "Anything",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "model_parameter",
            displayName: "Anything",
            choices: [.init(rawValue: "true", displayName: "Fast")]
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "unrecognized",
            category: "permission",
            displayName: "Speed",
            choices: speedChoices
        )))
    }

    func testCursorClassifierRejectsSemanticModelAndModeIDsBeforeParameterHeuristics() {
        let provider = CursorACPAgentProvider(config: CursorAgentConfig())
        let speedChoices = [
            ACPModelParameterChoice(rawValue: "false", displayName: "Standard"),
            ACPModelParameterChoice(rawValue: "true", displayName: "Fast")
        ]

        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "model",
            category: nil,
            displayName: "Effort",
            choices: []
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "mode",
            category: "model_parameter",
            displayName: "Speed",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "model",
            category: "model_config",
            displayName: "Anything",
            choices: speedChoices
        )))
        XCTAssertNil(provider.modelParameterKind(for: .init(
            configID: "mode",
            category: nil,
            displayName: "Cursor.Fast-Mode",
            choices: speedChoices
        )))
    }

    func testAgentSessionDecodesMissingParametersAndRoundTripsExactSelections() throws {
        let legacyPayload = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","savedAt":0,"autoEditEnabled":true}"#
        let legacy = try JSONDecoder().decode(AgentSession.self, from: Data(legacyPayload.utf8))
        XCTAssertTrue(legacy.acpModelParameterSelections.isEmpty)

        let selection = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "Grok 4.6",
            kind: .speed,
            configID: "Cursor.Fast-Mode",
            valueRaw: "FALSE"
        )
        let session = AgentSession(acpModelParameterSelections: [selection])
        let decoded = try JSONDecoder().decode(AgentSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(decoded.acpModelParameterSelections, [selection])
    }

    func testResolverUsesPersistedCursorValueAndHidesControlsForOtherProviders() {
        let persisted = ACPModelParameterSelection(
            providerID: .cursor,
            baseModelRaw: "grok-4.6",
            kind: .thinking,
            configID: "Cursor.Thought-Level",
            valueRaw: "medium"
        )

        let resolved = ACPModelParameterResolver.resolve(
            providerID: .cursor,
            selectedModelRaw: "Grok 4.6",
            persistedSelections: [persisted]
        )
        XCTAssertEqual(resolved.map(\.definition.kind), [.thinking, .speed])
        XCTAssertEqual(resolved.map(\.selectedChoice.rawValue), ["medium", "true"])
        XCTAssertTrue(ACPModelParameterResolver.resolve(
            providerID: .openCode,
            selectedModelRaw: "grok-4.6",
            persistedSelections: [persisted]
        ).isEmpty)
    }

    func testActiveCursorRunLocksParameterControlsAndRejectsDefensiveSelection() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        let viewModel = makeViewModel()
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        session.runState = .running
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
        viewModel.selectCursorModelParameter(configID: "Cursor.Thought-Level", valueRaw: "high")
        XCTAssertTrue(session.acpModelParameterSelections.isEmpty)

        session.runState = .idle
        viewModel.updateBindingsFromSession(session)
        XCTAssertFalse(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
        viewModel.selectCursorModelParameter(configID: "Cursor.Thought-Level", valueRaw: "high")
        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["high"])

        viewModel.test_setMCPControlledTabIDs([tabID])
        XCTAssertTrue(viewModel.makeComposerProps(tabID: tabID).areModelControlsDisabled)
        viewModel.selectCursorModelParameter(configID: "fast", valueRaw: "true")
        XCTAssertEqual(session.acpModelParameterSelections.map(\.valueRaw), ["high"])
    }

    func testCompactParameterControlExposesAccessibleNameAndSelection() {
        let control = AgentComposerModelParameterControlProps(
            kind: .thinking,
            baseModelRaw: "grok-4.6",
            configID: "thought_level",
            displayName: "Effort",
            selectedValueRaw: "high",
            selectedDisplayName: "High",
            choices: [
                .init(rawValue: "medium", displayName: "Medium"),
                .init(rawValue: "high", displayName: "High")
            ]
        )

        XCTAssertEqual(control.accessibilityLabel, "Effort")
        XCTAssertEqual(control.accessibilityValue, "High")
    }

    func testSelectingKnownCursorModelPublishesLocalControlsSynchronously() {
        let viewModel = makeViewModel(workspacePath: "/workspace-a")
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)

        let controls = viewModel.makeComposerProps(tabID: tabID).cursorModelParameterControls
        XCTAssertEqual(controls.map(\.displayName), ["Effort", "Speed"])
        XCTAssertEqual(controls.map(\.selectedDisplayName), ["High", "Fast"])
    }

    func testSwitchingKnownCursorModelsImmediatelyReplacesControls() {
        let viewModel = makeViewModel(workspacePath: "/workspace-a")
        let tabID = UUID()
        viewModel.test_setCurrentTabIDOverride(tabID)
        defer { viewModel.test_setCurrentTabIDOverride(nil) }

        let session = AgentModeViewModel.TabSession(tabID: tabID)
        session.hasLoadedPersistedState = true
        session.selectedAgent = .cursor
        session.selectedModelRaw = "grok-4.6"
        viewModel.test_installLiveSession(session)
        viewModel.applySessionToBindings(session)
        XCTAssertEqual(
            viewModel.makeComposerProps(tabID: tabID).cursorModelParameterControls.map(\.displayName),
            ["Effort", "Speed"]
        )

        session.selectedModelRaw = "composer-2.5"
        viewModel.applySessionToBindings(session)
        XCTAssertEqual(
            viewModel.makeComposerProps(tabID: tabID).cursorModelParameterControls.map(\.displayName),
            ["Speed"]
        )
    }

    func testUnknownCursorModelHasNoControls() {
        XCTAssertTrue(ACPModelParameterResolver.resolve(
            providerID: .cursor,
            selectedModelRaw: "future-cursor-model",
            persistedSelections: []
        ).isEmpty)
    }

    private func makeViewModel(workspacePath: String? = nil) -> AgentModeViewModel {
        AgentModeViewModel(
            testWorkspacePath: workspacePath,
            codexControllerFactory: { _, _, _, _, _, _ in
                LifecycleNoopCodexController(recorder: LifecycleRecorder())
            }
        )
    }
}
