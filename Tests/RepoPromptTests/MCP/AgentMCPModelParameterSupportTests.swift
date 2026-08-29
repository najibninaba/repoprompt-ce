import Foundation
import MCP
@testable import RepoPromptApp
import XCTest

final class AgentMCPModelParameterSupportTests: XCTestCase {
    func testCursorDefinitionsPreserveExactWireIdentifiersAndChoices() {
        let definitions = AgentMCPModelParameterSupport.definitions(
            modelRaw: "Grok",
            snapshot: cursorSnapshot()
        )

        XCTAssertEqual(definitions.count, 2)
        XCTAssertEqual(definitions[0].configID, "thought_level")
        XCTAssertEqual(definitions[0].choices.map(\.rawValue), ["low", "high"])
        XCTAssertEqual(definitions[1].configID, "model_config")
        XCTAssertEqual(definitions[1].choices.map(\.rawValue), ["standard", "fast"])
    }

    func testResolveRejectsUnknownConfigBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("unknown"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok",
            snapshot: cursorSnapshot()
        )) { error in
            XCTAssertTrue(String(describing: error).contains("unknown"))
        }
    }

    func testResolveRejectsUnknownValueBeforeProducingSelections() throws {
        let requested: Value = .array([
            .object(["config_id": .string("thought_level"), "value": .string("maximum")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok",
            snapshot: cursorSnapshot()
        )) { error in
            XCTAssertTrue(String(describing: error).contains("maximum"))
        }
    }

    func testResolvePreservesExactProviderWireValueAndCanonicalBase() throws {
        let requested: Value = .array([
            .object(["config_id": .string("thought_level"), "value": .string("HIGH")]),
            .object(["config_id": .string("model_config"), "value": .string("fast")])
        ])

        let selections = try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "Grok [Default]",
            snapshot: cursorSnapshot()
        )

        XCTAssertEqual(selections.map(\.configID), ["thought_level", "model_config"])
        XCTAssertEqual(selections.map(\.valueRaw), ["high", "fast"])
        XCTAssertEqual(selections.map(\.baseModelRaw), ["grok", "grok"])
    }

    func testResolvePreservesWhitespaceBearingProviderConfigID() throws {
        let snapshot = ACPDiscoveredSessionModels(
            options: [
                AgentModelOption(
                    rawValue: "grok",
                    displayName: "Grok",
                    description: nil,
                    isPlaceholderDefault: false,
                    isProviderDefault: true
                )
            ],
            currentModelRaw: "grok",
            modelParameterSets: [
                .init(
                    baseModelRaw: "grok",
                    parameters: [
                        .init(
                            kind: .thinking,
                            configID: " thought_level ",
                            displayName: "Effort",
                            choices: [.init(rawValue: "high", displayName: "High")],
                            currentValueRaw: "high"
                        )
                    ]
                )
            ]
        )

        let selections = try AgentMCPModelParameterSupport.resolve(
            value: .array([
                .object(["config_id": .string(" thought_level "), "value": .string("high")])
            ]),
            agent: .cursor,
            modelRaw: "grok",
            snapshot: snapshot
        )

        XCTAssertEqual(selections.first?.configID, " thought_level ")
    }

    func testResolveRejectsDuplicateConfigIDs() throws {
        let requested: Value = .array([
            .object(["config_id": .string("thought_level"), "value": .string("low")]),
            .object(["config_id": .string("thought_level"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .cursor,
            modelRaw: "grok",
            snapshot: cursorSnapshot()
        ))
    }

    func testNonCursorProviderRejectsModelParameters() throws {
        let requested: Value = .array([
            .object(["config_id": .string("thought_level"), "value": .string("high")])
        ])

        XCTAssertThrowsError(try AgentMCPModelParameterSupport.resolve(
            value: requested,
            agent: .openCode,
            modelRaw: "grok",
            snapshot: cursorSnapshot()
        ))
    }

    func testAgentRunSnapshotPublishesEffectiveModelParameterSelections() throws {
        let snapshot = AgentRunMCPSnapshot(
            sessionID: UUID(),
            tabID: UUID(),
            sessionName: "Cursor run",
            agentRaw: AgentProviderKind.cursor.rawValue,
            agentDisplayName: "Cursor",
            modelRaw: "grok",
            reasoningEffortRaw: nil,
            modelParameterSelections: [
                .init(
                    providerID: ACPProviderID.cursor.rawValue,
                    baseModelRaw: "grok",
                    kind: ACPModelParameterKind.thinking.rawValue,
                    configID: "thought_level",
                    valueRaw: "high"
                )
            ],
            status: .running,
            statusText: nil,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )

        let parameter = try XCTUnwrap(
            snapshot.asObject()["agent"]?.objectValue?["model_parameters"]?.arrayValue?.first?.objectValue
        )
        XCTAssertEqual(parameter["provider_id"]?.stringValue, "cursor")
        XCTAssertEqual(parameter["base_model"]?.stringValue, "grok")
        XCTAssertEqual(parameter["kind"]?.stringValue, "thinking")
        XCTAssertEqual(parameter["config_id"]?.stringValue, "thought_level")
        XCTAssertEqual(parameter["value"]?.stringValue, "high")
    }

    func testEffectiveSelectionsExcludeOtherCursorBaseModels() {
        let selections = [
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "grok",
                kind: .thinking,
                configID: "thought_level",
                valueRaw: "high"
            ),
            ACPModelParameterSelection(
                providerID: .cursor,
                baseModelRaw: "composer-2",
                kind: .speed,
                configID: "model_config",
                valueRaw: "fast"
            )
        ]

        XCTAssertEqual(
            AgentMCPModelParameterSupport.effectiveSelections(
                selections,
                agentRaw: AgentProviderKind.cursor.rawValue,
                modelRaw: "Grok [Default]"
            ),
            [selections[0]]
        )
    }

    private func cursorSnapshot() -> ACPDiscoveredSessionModels {
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
            currentModelRaw: "grok",
            modelParameterSets: [
                ACPModelParameterSet(
                    baseModelRaw: "grok",
                    parameters: [
                        ACPModelParameterDefinition(
                            kind: .thinking,
                            configID: "thought_level",
                            displayName: "Effort",
                            choices: [
                                .init(rawValue: "low", displayName: "Low"),
                                .init(rawValue: "high", displayName: "High")
                            ],
                            currentValueRaw: "low"
                        ),
                        ACPModelParameterDefinition(
                            kind: .speed,
                            configID: "model_config",
                            displayName: "Speed",
                            choices: [
                                .init(rawValue: "standard", displayName: "Standard"),
                                .init(rawValue: "fast", displayName: "Fast")
                            ],
                            currentValueRaw: "standard"
                        )
                    ]
                )
            ]
        )
    }
}
