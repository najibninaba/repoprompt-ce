import XCTest
@_spi(TestSupport) @testable import RepoPromptApp

final class CursorLocalModelCatalogTests: XCTestCase {
    func testCatalogPublishesReleaseGatedCursorModelsInProductOrder() {
        XCTAssertEqual(
            CursorAIModelCatalog.options.prefix(4).map(\.rawValue),
            ["auto", "grok-4.6", "grok-4.5", "composer-2.5"]
        )
        XCTAssertTrue(CursorAIModelCatalog.contains(modelRaw: "grok-4.6"))
        XCTAssertTrue(CursorAIModelCatalog.contains(modelRaw: "Cursor Grok 4.6"))
        XCTAssertFalse(CursorAIModelCatalog.contains(modelRaw: "future-cursor-model"))
    }

    func testGrok46DefinesExactLocalEffortAndSpeedMetadata() throws {
        let parameterSet = try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: "grok-4.6"))

        XCTAssertEqual(parameterSet.baseModelRaw, "grok-4.6")
        XCTAssertEqual(parameterSet.parameters.map(\.kind), [.thinking, .speed])
        XCTAssertEqual(parameterSet.parameters.map(\.configID), ["Cursor.Thought-Level", "fast"])

        let effort = try XCTUnwrap(parameterSet.parameters.first { $0.kind == .thinking })
        XCTAssertEqual(effort.choices.map(\.rawValue), ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(effort.currentValueRaw, "high")

        let speed = try XCTUnwrap(parameterSet.parameters.first { $0.kind == .speed })
        XCTAssertEqual(speed.choices.map(\.rawValue), ["false", "true"])
        XCTAssertEqual(speed.choices.map(\.displayName), ["Standard", "Fast"])
        XCTAssertEqual(speed.currentValueRaw, "true")
    }

    func testComposer25DefinesSpeedWithoutEffort() throws {
        let parameterSet = try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: "composer-2.5"))

        XCTAssertEqual(parameterSet.parameters.map(\.kind), [.speed])
        XCTAssertEqual(parameterSet.parameters.first?.currentValueRaw, "false")
    }

    func testPersistedLegacyComposer2SelectionCanonicalizesWithoutDuplicatingPickerOption() {
        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)

        let normalized = AgentModelCatalog.normalizePersistedSelection(
            agentRaw: AgentProviderKind.cursor.rawValue,
            modelRaw: "composer-2",
            availability: availability
        )

        XCTAssertEqual(normalized.agent, .cursor)
        XCTAssertEqual(normalized.modelRaw, "composer-2.5")
        XCTAssertEqual(
            AgentModelCatalog.options(for: .cursor, availability: availability)
                .count(where: { $0.rawValue == "composer-2.5" }),

            1
        )
        XCTAssertFalse(
            AgentModelCatalog.options(for: .cursor, availability: availability)
                .contains { $0.rawValue == "composer-2" }
        )
    }

    func testGrok45DefinesExactLocalEffortAndSpeedDefaults() throws {
        let parameterSet = try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: "grok-4.5"))

        let effort = try XCTUnwrap(parameterSet.parameters.first { $0.kind == .thinking })
        XCTAssertEqual(effort.choices.map(\.rawValue), ["low", "medium", "high"])
        XCTAssertEqual(effort.currentValueRaw, "high")

        let speed = try XCTUnwrap(parameterSet.parameters.first { $0.kind == .speed })
        XCTAssertEqual(speed.choices.map(\.rawValue), ["false", "true"])
        XCTAssertEqual(speed.currentValueRaw, "false")
    }

    func testReleaseCatalogPinsEffortAndSpeedCapabilitiesForParameterizedCursorModels() throws {
        struct Expectation {
            let model: String
            let effortValues: [String]
            let hasSpeed: Bool
        }
        let expectations = [
            Expectation(model: "claude-fable-5", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: false),
            Expectation(model: "claude-opus-4-6", effortValues: ["high", "max"], hasSpeed: false),
            Expectation(model: "claude-opus-4-7", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "claude-opus-4-8", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "claude-opus-5", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "claude-sonnet-5", effortValues: ["low", "medium", "high", "xhigh", "max"], hasSpeed: false),
            Expectation(model: "gemini-3.6-flash", effortValues: ["minimal", "low", "medium", "high"], hasSpeed: false),
            Expectation(model: "gemini-3.7-flash", effortValues: ["low", "medium", "high"], hasSpeed: false),
            Expectation(model: "glm-5.2", effortValues: ["high", "max"], hasSpeed: false),
            Expectation(model: "gpt-5.1", effortValues: ["low", "medium", "high"], hasSpeed: false),
            Expectation(model: "gpt-5.2", effortValues: ["low", "medium", "high", "xhigh"], hasSpeed: true),
            Expectation(model: "gpt-5.3-codex", effortValues: ["low", "medium", "high", "xhigh"], hasSpeed: true),
            Expectation(model: "gpt-5.4", effortValues: ["low", "medium", "high", "xhigh"], hasSpeed: true),
            Expectation(model: "gpt-5.4-mini", effortValues: ["none", "low", "medium", "high", "xhigh"], hasSpeed: false),
            Expectation(model: "gpt-5.4-nano", effortValues: ["none", "low", "medium", "high", "xhigh"], hasSpeed: false),
            Expectation(model: "gpt-5.5", effortValues: ["none", "low", "medium", "high", "xhigh"], hasSpeed: true),
            Expectation(model: "gpt-5.6-luna", effortValues: ["none", "low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "gpt-5.6-sol", effortValues: ["none", "low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "gpt-5.6-terra", effortValues: ["none", "low", "medium", "high", "xhigh", "max"], hasSpeed: true),
            Expectation(model: "kimi-k3", effortValues: ["low", "high", "max"], hasSpeed: false)
        ]

        for expectation in expectations {
            let parameterSet = try XCTUnwrap(CursorAIModelCatalog.parameterSet(for: expectation.model))
            XCTAssertEqual(
                parameterSet.parameters.first(where: { $0.kind == .thinking })?.choices.map(\.rawValue),
                expectation.effortValues,
                expectation.model
            )
            XCTAssertEqual(
                parameterSet.parameters.contains(where: { $0.kind == .speed }),
                expectation.hasSpeed,
                expectation.model
            )
        }
    }

    func testEveryCatalogParameterDefaultIsAnAdvertisedChoice() {
        for option in CursorAIModelCatalog.options {
            guard let parameterSet = CursorAIModelCatalog.parameterSet(for: option.rawValue) else { continue }
            for definition in parameterSet.parameters {
                XCTAssertNotNil(
                    definition.choice(matching: definition.currentValueRaw),
                    "\(option.rawValue) \(definition.configID) has an invalid local default"
                )
            }
        }
    }

    func testAgentModelCatalogUsesReleaseGatedCursorOptionsAndRejectsDiscoveredUnknownModels() {
        AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
        defer { AgentACPModelRegistry.shared.test_reset(providerID: .cursor) }
        XCTAssertTrue(AgentACPModelRegistry.shared.updateDiscoveredModels(
            ACPDiscoveredSessionModels(
                options: [.init(
                    rawValue: "future-cursor-model",
                    displayName: "Future Cursor Model",
                    description: nil,
                    isDefault: false
                )],
                currentModelRaw: "future-cursor-model"
            ),
            for: .cursor
        ))

        let availability = AgentModelCatalog.AvailabilityContext(cursorAvailable: true)
        XCTAssertEqual(
            AgentModelCatalog.options(for: .cursor, availability: availability),
            CursorAIModelCatalog.options
        )
        XCTAssertTrue(AgentModelCatalog.isValid(
            rawModel: "Cursor Grok 4.6",
            for: .cursor,
            availability: availability
        ))
        XCTAssertFalse(AgentModelCatalog.isValid(
            rawModel: "future-cursor-model",
            for: .cursor,
            availability: availability
        ))
    }
}
