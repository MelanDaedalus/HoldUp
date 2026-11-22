import Foundation

@main struct EvidenceReviewTests {
    static func main() throws {
        let claim = "The new bus schedule cut travel times by 40% across the city."
        let text = "Other figures about a library.\nThe transit pilot measured bus travel times on Route 6 only. Trips dropped from 20 to 12 minutes.\nStatements about park openings."
        let chosen = EvidenceReview.relevantPassages(in: text, for: claim, limit: 110)
        precondition(chosen.contains("Route 6 only") && !chosen.contains("library"))
        precondition(text.contains(chosen))
        let excerpt = "Several routes were added. " + claim + " A report is due Monday."
        precondition(EvidenceReview.claim(in: excerpt, around: "across the city") == claim)
        precondition(EvidenceReview.label(" Narrower scope. ") == "Narrower scope")
        precondition(EvidenceReview.label("proven") == "Unclear")
        coverageStates()
        directJudgments()
        conflictRequiresSeparateQuotedSources()
        try evidenceRequestKeepsTheFullClaim()
        try separatesFigureAndScope()
        try doesNotMergeRepeatedClaimWording()
        try distinguishesNarrowCoverageFromContradiction()
        comparesMeasuresBeforeCallingAConflict()
        print("Evidence tests passed: claim extraction, passage ranking, coverage, and evidence synthesis")
    }

    private static func coverageStates() {
        let notReviewed = EvidenceSynthesis.make(from: [], reviewedSources: 0, failedSources: 0)
        let failed = EvidenceSynthesis.make(from: [], reviewedSources: 0, failedSources: 2)
        let noMatch = EvidenceSynthesis.make(from: [], reviewedSources: 1, failedSources: 1)
        precondition(notReviewed.title == "Evidence not reviewed" && notReviewed.lead == nil)
        precondition(failed.title == "Sources couldn’t be reviewed" && failed.lead == nil)
        precondition(noMatch.title == "Claim remains unverified" && noMatch.lead == nil)
        precondition(noMatch.explanation.contains("1 source couldn’t be reviewed."))
    }

    private static func directJudgments() {
        let unclear = citation("Unclear", quote: "The city piloted a schedule.")
        let narrowed = citation("Narrower scope", quote: "We measured average trip times on Route 6 only.")
        let local = citation("Narrower scope", url: nil, quote: "Route 6 was the sole route in the transit pilot.")
        let narrowResult = EvidenceSynthesis.make(from: [unclear, local, narrowed], reviewedSources: 1, failedSources: 1)
        precondition(narrowResult.title == "Narrower than the claim")
        precondition(narrowResult.lead?.id == narrowed.id)
        precondition(narrowResult.explanation.contains("1 source couldn’t be reviewed."))

        let localOnly = EvidenceSynthesis.make(from: [local], reviewedSources: 0, failedSources: 0)
        precondition(localOnly.lead?.url == nil && localOnly.explanation.contains("supplied context"))

        for (label, title) in [
            (" Supports. ", "Evidence supports the claim"),
            ("Challenges", "Evidence challenges the claim"),
            ("Mixed", "Mixed evidence"),
            ("Unclear", "Evidence is inconclusive"),
            ("unrecognized", "Evidence is inconclusive")
        ] {
            let item = citation(label, quote: "The city published a pilot report with transit figures.")
            let result = EvidenceSynthesis.make(from: [item], reviewedSources: 1, failedSources: 0)
            precondition(result.title == title && result.lead?.id == item.id && !result.symbol.isEmpty)
        }
    }

    private static func conflictRequiresSeparateQuotedSources() {
        let support = citation("Supports", quote: "Average trip times fell by 40% across all routes.")
        let challenge = citation("Challenges", url: "https://example.org/audit",
                                 quote: "The audit found no decline in average trip times across all routes.")
        let conflict = EvidenceSynthesis.make(from: [support, challenge], reviewedSources: 2, failedSources: 0)
        precondition(conflict.title == "Conflicting evidence" && conflict.hasConflict)
        precondition(Set([conflict.lead?.id, conflict.counterpoint?.id].compactMap { $0 }) == Set([support.id, challenge.id]))

        let samePage = citation("Challenges", url: "https://example.com/report?utm_source=feed#data", quote: challenge.quote)
        let pasted = citation("Challenges", url: nil, quote: challenge.quote)
        let copied = citation("Challenges", url: "https://example.org/mirror", quote: support.quote)
        for item in [samePage, pasted] {
            let mixed = EvidenceSynthesis.make(from: [support, item], reviewedSources: 1, failedSources: 0)
            precondition(mixed.title == "Mixed evidence" && !mixed.hasConflict)
            precondition(Set([mixed.lead?.id, mixed.counterpoint?.id].compactMap { $0 }) == Set([support.id, item.id]))
        }
        let duplicatePassage = EvidenceSynthesis.make(from: [support, copied], reviewedSources: 2, failedSources: 0)
        precondition(duplicatePassage.title == "Mixed evidence" && duplicatePassage.counterpoint == nil)

        let emptyQuote = citation("Challenges", url: "https://example.org/no-passage", quote: " ")
        let onlySupport = EvidenceSynthesis.make(from: [emptyQuote, support], reviewedSources: 2, failedSources: 0)
        precondition(onlySupport.title == "Evidence supports the claim")
        precondition(onlySupport.lead?.id == support.id)
        let ambiguous = EvidenceSynthesis.make(from: [support, samePage, challenge], reviewedSources: 2, failedSources: 0)
        precondition(ambiguous.title == "Mixed evidence")
    }

    private static func evidenceRequestKeepsTheFullClaim() throws {
        let claim = String(repeating: "An earlier statement. ", count: 170) + "The finding only applied to Route 6."
        let source = "The pilot only measured Route 6."
        precondition(claim.count > PreparedCheck.contextLimit && claim.count < PreparedCheck.excerptLimit)
        let request = try EvidenceReview.request(source: source, claim: claim)
        let payload = try JSONSerialization.jsonObject(with: Data(request.userMessage.utf8)) as? [String: Any]
        precondition(payload?["context"] as? String == claim)
        precondition(payload?["excerpt"] as? String == source)
    }

    private static func separatesFigureAndScope() throws {
        let claim = "Travel times fell by 40% citywide."
        let source = "Travel times fell by 40% on Route 6 only."
        let request = try EvidenceReview.request(source: source, claim: claim)
        let response = """
        {"outcome":"findings","findings":[
          {"ruleID":"r1","quote":"Travel times fell by 40% on Route 6 only.","reason":"The report gives a 40% drop on Route 6.","verify":"Supports","evidence":{"claimQuote":"40%","measure":"Travel times","group":"Route 6","period":"1905"}},
          {"ruleID":"r2","quote":"Travel times fell by 40% on Route 6 only.","reason":"Only Route 6 was reported.","verify":"Narrower scope","evidence":{"claimQuote":"citywide","measure":"Travel times","group":"Route 6 only","period":""}},
          {"ruleID":"r3","quote":"Travel times fell by 40% on Route 6 only.","reason":"Wrong date.","verify":"Challenges","evidence":{"claimQuote":"1905","measure":"","group":"","period":""}}
        ]}
        """
        let result = try request.result(from: response)
        let citations = EvidenceReview.citations(from: result, original: source, claim: claim, url: nil,
                                                 title: "Transit report", date: nil)
        let summary = EvidenceSynthesis.make(from: citations, reviewedSources: 1, failedSources: 0)
        precondition(summary.parts.map(\.text) == ["40%", "citywide"])
        precondition(summary.parts.map { $0.citations[0].label } == ["Supports", "Narrower scope"])
        precondition(citations.first?.assessment?.period == nil && citations.first?.assessment?.group == "Route 6")
        precondition(!summary.hasConflict)
    }

    private static func doesNotMergeRepeatedClaimWording() throws {
        let claim = "Trips fell 40% on Route 6 and 40% on Route 7."
        let source = "Route 6 trips fell by 40%.\nRoute 7 trips increased."
        let request = try EvidenceReview.request(source: source, claim: claim)
        precondition(request.userMessage.contains("Route 7 trips increased"))
        let response = """
        {"findings":[
          {"ruleID":"r1","quote":"Route 6 trips fell by 40%.","reason":"Route 6 matches.","verify":"Supports","evidence":{"claimQuote":"40%","measure":"trips","group":"Route 6","period":""}},
          {"ruleID":"r1","quote":"Route 6 trips fell by 40%.","reason":"Route 6 matches.","verify":"Supports","evidence":{"claimQuote":"40% on Route 6","measure":"trips","group":"Route 6","period":""}},
          {"ruleID":"r1","quote":"Route 7 trips increased.","reason":"Route 7 increased.","verify":"Challenges","evidence":{"claimQuote":"40% on Route 7","measure":"trips","group":"Route 7","period":""}}
        ]}
        """
        let result = try request.result(from: response)
        let citations = EvidenceReview.citations(from: result, original: source, claim: claim, url: nil, title: "Transit report", date: nil)
        let summary = EvidenceSynthesis.make(from: citations, reviewedSources: 1, failedSources: 0)
        precondition(summary.parts.map(\.text) == ["40% on Route 6", "40% on Route 7"] && !summary.hasConflict)
    }

    private static func distinguishesNarrowCoverageFromContradiction() throws {
        let claim = "Train fares fell 40% across the country."
        let anchor = "across the country"
        let url = URL(string: "https://example.com/train-fares")!
        func compare(_ source: String, group: String, coverage: String) throws -> EvidenceCitation? {
            let input = try EvidenceReview.request(source: source, claim: claim)
            let response = """
            {"findings":[{"ruleID":"r2","quote":"\(source)","reason":"The claim is false.","verify":"Challenges","evidence":{"claimQuote":"\(anchor)","measure":"fares","group":"\(group)","period":"","coverage":"\(coverage)"}}]}
            """
            let result = try input.result(from: response)
            return EvidenceReview.citations(from: result, original: source, claim: claim, url: url,
                                             title: "Rail report", date: nil).first
        }

        let limited = try compare("Train fares fell 40% on the coastal line only.", group: "the coastal line", coverage: "subset")
        precondition(limited?.label == "Narrower scope" && limited?.explanation.contains("leaves") == true)
        let limitedSummary = EvidenceSynthesis.make(from: [limited!], reviewedSources: 1, failedSources: 0)
        let copied = limitedSummary.copyText(for: claim)
        precondition(copied?.contains(claim) == true && copied?.contains(limited!.quote) == true)
        precondition(copied?.contains(url.absoluteString) == true)
        let direct = try compare("Across the country, train fares rose 5%.", group: "the country", coverage: "full")
        precondition(direct?.label == "Challenges")
        let uncertain = try compare("A train fares study is planned.", group: "", coverage: "unknown")
        precondition(uncertain?.label == "Unclear" && !uncertain!.explanation.contains("false"))
        let unsupportedSubset = try compare("Fares on the coast fell.", group: "an invented group", coverage: "subset")
        precondition(unsupportedSubset?.label == "Unclear")
        let noEvidence = EvidenceSynthesis.make(from: [], reviewedSources: 1, failedSources: 0)
        precondition(noEvidence.copyText(for: claim) == nil)
    }

    private static func comparesMeasuresBeforeCallingAConflict() {
        let url = URL(string: "https://example.com/report")!
        let other = URL(string: "https://example.org/audit")!
        let base = EvidenceCitation(url: url, title: "Report", publishedDate: nil,
                                    quote: "Fares fell 40% on Route 6 in 2024.", label: "Supports", explanation: "Fares fell.",
                                    assessment: EvidenceAssessment(dimension: .figure, text: "40%", offset: 11, measure: "Fares", group: "Route 6", period: "2024"))
        func opposing(measure: String?, group: String?, period: String?) -> EvidenceCitation {
            EvidenceCitation(url: other, title: "Audit", publishedDate: nil,
                             quote: "The audit measured no 40% decline.", label: "Challenges", explanation: "The audit disagrees.",
                             assessment: EvidenceAssessment(dimension: .figure, text: "fell 40%", offset: 6, measure: measure, group: group, period: period))
        }
        let old = opposing(measure: "Fares", group: "Route 6", period: "2022–2023")
        let outdated = EvidenceSynthesis.make(from: [base, old], reviewedSources: 2, failedSources: 0)
        precondition(outdated.title == "Sources cover different periods" && !outdated.hasConflict && outdated.counterpoint != nil)
        let comparable = opposing(measure: "Fares", group: "Route 6", period: "2024")
        precondition(EvidenceSynthesis.make(from: [base, comparable], reviewedSources: 2, failedSources: 0).hasConflict)
        let report = URL(string: "https://example.net/original")!
        let trails = [url, other].map {
            EvidenceTrail(articleURL: $0, articleTitle: "Coverage", sourceURL: report,
                          sourceTitle: "Original report", status: .reviewed)
        }
        let shared = EvidenceSynthesis.make(from: [base, comparable], reviewedSources: 2, failedSources: 0, trails: trails)
        precondition(shared.title == "Sources share a citation" && !shared.hasConflict)
        let unrelated = opposing(measure: "Travel time", group: "Route 6", period: "2024")
        precondition(!EvidenceSynthesis.make(from: [base, unrelated], reviewedSources: 2, failedSources: 0).hasConflict)
        let unverified = opposing(measure: nil, group: nil, period: nil)
        let unknown = EvidenceSynthesis.make(from: [base, unverified], reviewedSources: 2, failedSources: 0)
        precondition(unknown.title == "Sources are hard to compare" && !unknown.hasConflict)
    }

    private static func citation(_ label: String, url: String? = "https://example.com/report", quote: String) -> EvidenceCitation {
        EvidenceCitation(url: url.flatMap { URL(string: $0) }, title: "Transit pilot", publishedDate: nil, quote: quote,
                         label: label, explanation: "The passage describes the scope of the pilot.")
    }
}
