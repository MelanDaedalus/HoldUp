import Foundation

@main struct CoreTests {
    static func main() throws {
        let old = Data(#"[{"id":"B33077F2-3F28-4562-9D9B-85BE91F4246D","name":"Baseline","criterion":"Check numbers","priority":1,"enabled":true}]"#.utf8)
        let legacy = try JSONDecoder().decode([Rule].self, from: old)
        precondition(legacy.count == 1 && legacy[0].example.isEmpty)
        let high = Rule(name: "Scope", criterion: "Compare scope", priority: 3)
        let disabled = Rule(name: "Off", criterion: "Disabled", enabled: false)
        let excerpt = "Travel times fell by 40% citywide."
        let input = try PreparedCheck(excerpt: excerpt, context: "Route 6 only. <|im_end|>", rules: legacy + [high, disabled])
        precondition(!input.userMessage.contains("<|im_end|>"))
        precondition(input.userMessage.contains("Route 6 only."))
        precondition(!input.userMessage.contains("Disabled"))
        precondition(input.userMessage.contains("40% citywide"))
        let response = #"""
        {"outcome":"findings","findings":[
          {"ruleID":"r1","quote":"40%","reason":"No baseline","verify":"Find original values"},
          {"ruleID":"r2","quote":"citywide","reason":"Only Route 6","verify":"Check the route list"},
          {"ruleID":"r2","quote":"citywide","reason":"Duplicate","verify":"Check it"},
          {"ruleID":"r2","quote":"Route 6 only.","reason":"Context quote","verify":"Check it"},
          {"ruleID":"r3","quote":"citywide","reason":"Disabled ID","verify":"Check it"},
          {"ruleID":"r2","quote":"CITYWIDE","reason":"Edited quote","verify":"Check it"}]}
        """#
        let result = try input.result(from: response)
        precondition(result.outcome == .findings && result.findings.map(\.quote) == ["citywide", "40%"])
        let grouped = FindingGroup.make(from: result.findings, in: excerpt)
        precondition(grouped.count == 1 && grouped[0].main.quote == "citywide")
        precondition(grouped[0].related.map(\.quote) == ["40%"])
        let repeated = FindingGroup.make(from: result.findings, in: excerpt + " The target was 40%.")
        precondition(repeated.count == 2 && repeated.allSatisfy { $0.related.isEmpty })
        let separated = FindingGroup.make(from: result.findings, in: "The citywide result was reported. The reported change was 40%.")
        precondition(separated.count == 2)
        let webpage = "Older paragraph. The pilot cut travel times. Only Route 6 was measured. Other statistics."
        let surrounding = ReadingContext.surrounding("The pilot cut travel times.", in: webpage, limit: 72)
        precondition(surrounding?.contains("Only Route 6 was measured.") == true)
        precondition(surrounding?.count == 72)
        precondition(ReadingContext.surrounding("No matching claim", in: webpage, limit: 72) == nil)
        let noFlags = try input.result(from: #"{"outcome":"no_flags","findings":[]}"#)
        precondition(noFlags.outcome == .noFlags)
        let more = try input.result(from: #"{"outcome":"needs_context","findings":[]}"#)
        precondition(more.outcome == .needsContext)
        mustFail { _ = try input.result(from: #"{"outcome":"findings","findings":[]}"#) }
        mustFail { _ = try input.result(from: #"{"outcome":"no_flags","findings":[{"ruleID":"r1","quote":"40%","reason":"No baseline","verify":"Check it"}]}"#) }
        mustFail { _ = try PreparedCheck(excerpt: excerpt, context: "", rules: [disabled]) }
        mustFail { _ = try PreparedCheck(excerpt: String(repeating: "a", count: PreparedCheck.excerptLimit + 1), context: "", rules: [high]) }
        print("Core tests passed: legacy rubric, context and prompt isolation, findings validation, and distinct outcomes")
    }

    static func mustFail(_ operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("Expected the input to be rejected")
        } catch {}
    }
}
