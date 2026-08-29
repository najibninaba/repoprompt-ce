@testable import RepoPromptApp
import XCTest

final class DiffGenerationUtilityRoutingTests: XCTestCase {
    func testReplaceAllHonorsSearchStartLineWithFullFileIndex() async throws {
        let fileContent = ["same", "skip", "same", "middle", "same"]
        let processed = fileContent.map {
            DiffGenerationUtility.processLine($0, precision: .high)
        }
        let lineIndexMap = DiffGenerationUtility.buildLineIndexMapHigh(content: processed)

        let chunks = try await DiffGenerationUtility.generateDiff(
            fileContent: fileContent,
            lineIndexMap: lineIndexMap,
            startSelector: nil,
            endSelector: nil,
            searchBlock: ["same"],
            newContent: ["replacement"],
            action: .modify,
            diffPrecision: .high,
            processedFileContent: processed,
            searchStartLine: 2,
            replaceAll: true
        )
        let result = try DiffChunkTextApplier.apply(
            chunks: chunks,
            to: fileContent.joined(separator: "\n")
        )

        XCTAssertEqual(chunks.map(\.startLine), [2, 4])
        XCTAssertEqual(result, "same\nskip\nreplacement\nmiddle\nreplacement")
    }

    func testFuzzyProbeIgnoresPreBoundaryKeysBeforeSpendingBudget() throws {
        let selectorText = "calculate total for selected invoice line items"
        let selector = DiffGenerationUtility.processLine(selectorText, precision: .high)
        let minimumMatchIndex = 401
        let maxFuzzyKeys = 400
        let fuzzyAliases = (0 ... maxFuzzyKeys).map {
            "calculate total for selected invoice line item candidate \(String($0, radix: 36))"
        }
        let processedAliases = fuzzyAliases.map {
            DiffGenerationUtility.processLine($0, precision: .high)
        }
        let aliasKeys = processedAliases.compactMap {
            DiffGenerationUtility.buildLineIndexMapHigh(content: [$0]).keys.first
        }
        XCTAssertEqual(aliasKeys.count, processedAliases.count)
        var lineIndex = Dictionary(uniqueKeysWithValues: aliasKeys.map { ($0, [0]) })
        let orderedKeys = Array(lineIndex.keys)
        let candidateKey = orderedKeys[maxFuzzyKeys]
        let candidateOffset = try XCTUnwrap(aliasKeys.firstIndex(of: candidateKey))
        let fuzzyCandidate = processedAliases[candidateOffset]
        lineIndex[candidateKey] = [minimumMatchIndex]
        XCTAssertEqual(Array(lineIndex.keys), orderedKeys, "Updating an existing value must preserve the probe fixture order")

        let unrelatedLine = DiffGenerationUtility.processLine("unrelated", precision: .high)
        let content = Array(repeating: unrelatedLine, count: minimumMatchIndex) + [fuzzyCandidate]

        let result = try DiffGenerationUtility.matchSelectorFast(
            selector: [selector],
            content: content,
            lineIndex: lineIndex,
            maxFuzzyKeys: maxFuzzyKeys,
            fuzzyThreshold: 0.80,
            minimumMatchIndex: minimumMatchIndex
        )

        XCTAssertEqual(result, minimumMatchIndex)
    }

    func testBatchReplaceAllKeepsFullFileIndexCoordinatesAfterFirstMatch() async throws {
        let original = [
            "header",
            "padding",
            "TARGET",
            "remove",
            "gap one",
            "gap two",
            "gap three",
            "TARGET",
            "remove",
            "footer"
        ].joined(separator: "\n")
        let request = ApplyEditsRequest(
            path: "file.swift",
            mode: .batch([
                ApplyEditsOperation(
                    search: "target\nremove",
                    replace: "replacement",
                    replaceAll: true
                )
            ]),
            verbose: false
        )

        let result = try await ApplyEditsEngine.default.apply(request: request, to: original)

        XCTAssertNil(result.note, "Case normalization should route through batch diff generation")
        XCTAssertEqual(
            result.updatedText,
            [
                "header",
                "padding",
                "replacement",
                "gap one",
                "gap two",
                "gap three",
                "replacement",
                "footer"
            ].joined(separator: "\n")
        )
    }

    func testReplaceAllBypassesDuplicateMatchAmbiguityAndAppliesCumulativeOffsets() async throws {
        let rows = [
            (
                label: "positive delta",
                fileContent: ["before", "same", "middle", "same", "after"],
                searchBlock: ["same"],
                replacement: ["replacement", "extra"],
                expected: ["before", "replacement", "extra", "middle", "replacement", "extra", "after"]
            ),
            (
                label: "negative delta",
                fileContent: ["before", "same", "remove", "middle", "same", "remove", "after"],
                searchBlock: ["same", "remove"],
                replacement: ["replacement"],
                expected: ["before", "replacement", "middle", "replacement", "after"]
            )
        ]

        for row in rows {
            do {
                _ = try await DiffGenerationUtility.generateDiff(
                    fileContent: row.fileContent,
                    lineIndexMap: nil,
                    startSelector: nil,
                    endSelector: nil,
                    searchBlock: row.searchBlock,
                    newContent: row.replacement,
                    action: .modify,
                    diffPrecision: .high,
                    mcpAmbiguityCheck: true,
                    replaceAll: false
                )
                XCTFail("Expected duplicate search blocks to be ambiguous without replaceAll: \(row.label)")
            } catch let error as DiffGenerationError {
                guard case .ambiguousMatch = error else {
                    return XCTFail("Expected ambiguity error for \(row.label), got \(error)")
                }
            }

            let chunks = try await DiffGenerationUtility.generateDiff(
                fileContent: row.fileContent,
                lineIndexMap: nil,
                startSelector: nil,
                endSelector: nil,
                searchBlock: row.searchBlock,
                newContent: row.replacement,
                action: .modify,
                diffPrecision: .high,
                mcpAmbiguityCheck: true,
                replaceAll: true
            )
            let result = try DiffChunkTextApplier.apply(
                chunks: chunks,
                to: row.fileContent.joined(separator: "\n")
            )

            XCTAssertEqual(result, row.expected.joined(separator: "\n"), row.label)
        }
    }
}
