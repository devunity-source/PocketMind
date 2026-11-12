import Foundation
import XCTest
@testable import PocketMindCore

final class IntelligenceTests: XCTestCase {

    // MARK: Query understanding

    func testDatePhrasesBecomeRanges() {
        let now = Fixtures.date(2026, 1, 28) // a Wednesday
        let calendar = Fixtures.utc

        let yesterday = QueryParser.parse("What did I discuss yesterday?", now: now, calendar: calendar)
        XCTAssertEqual(yesterday.dateRange?.start, Fixtures.date(2026, 1, 27, hour: 0))
        XCTAssertEqual(yesterday.dateRange?.end, Fixtures.date(2026, 1, 28, hour: 0))
        XCTAssertEqual(yesterday.intent, .overview)
        XCTAssertTrue(yesterday.keywords.isEmpty, "no topic words remain: \(yesterday.keywords)")

        let lastWeek = QueryParser.parse("Summarize my meetings from last week.", now: now, calendar: calendar)
        XCTAssertEqual(lastWeek.dateRange?.start, Fixtures.date(2026, 1, 19, hour: 0), "week starts Monday in this calendar")
        XCTAssertEqual(lastWeek.dateRange?.end, Fixtures.date(2026, 1, 26, hour: 0))
        XCTAssertEqual(lastWeek.intent, .overview)

        let thisMonth = QueryParser.parse("What deadlines were discussed this month?", now: now, calendar: calendar)
        XCTAssertEqual(thisMonth.dateRange?.start, Fixtures.date(2026, 1, 1, hour: 0))
        XCTAssertEqual(thisMonth.dateRange?.end, Fixtures.date(2026, 2, 1, hour: 0))
        XCTAssertEqual(thisMonth.intent, .deadlines)

        let lastDays = QueryParser.parse("anything about budgets in the last 3 days", now: now, calendar: calendar)
        XCTAssertEqual(lastDays.dateRange?.start, Fixtures.date(2026, 1, 25, hour: 0))
        XCTAssertEqual(lastDays.keywords, ["anything", "budgets"])
    }

    func testIntentsAndKeywords() {
        let tasks = QueryParser.parse("What tasks did I promise to complete?")
        XCTAssertEqual(tasks.intent, .tasks)
        XCTAssertNil(tasks.dateRange)

        let topic = QueryParser.parse("What did we decide about Kubernetes?")
        XCTAssertEqual(topic.intent, .general)
        XCTAssertEqual(topic.keywords, ["kubernetes"])

        let find = QueryParser.parse("Find conversations where I mentioned Terraform.")
        XCTAssertEqual(find.keywords, ["terraform"])
    }

    func testChunkerKeepsTimestampsAndOverlaps() {
        let segments = (0..<40).map {
            TranscriptSegment(id: Int64($0), recordingID: "r", index: $0, start: Double($0) * 4, end: Double($0) * 4 + 4,
                              text: "This is sentence number \($0) of the meeting transcript.")
        }
        let chunks = Chunker.chunks(from: segments, targetCharacters: 300, overlapSegments: 1)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertEqual(chunks.first?.start, 0)
        XCTAssertEqual(chunks.last?.end, 160)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertLessThan(next.start, previous.end, "consecutive chunks share one segment")
            XCTAssertLessThanOrEqual(previous.text.count, 400)
        }
        for index in 0..<40 {
            XCTAssertTrue(chunks.contains { $0.text.contains("number \(index) of") }, "segment \(index) must not be lost")
        }
        XCTAssertTrue(Chunker.chunks(from: []).isEmpty)
    }

    // MARK: Structured output

    func testParsesCleanAndWrappedJSON() throws {
        let clean = try XCTUnwrap(SummaryParser.parse(Fixtures.summaryJSON))
        XCTAssertEqual(clean.title, "Infrastructure Sync")
        XCTAssertEqual(clean.decisions.count, 2)
        XCTAssertEqual(clean.actionItems.map(\.owner), [nil, "Alex"])
        XCTAssertEqual(clean.actionItems.first?.due, "Friday")
        XCTAssertEqual(clean.deadlines, [DeadlineNote(what: "Terraform changes", when: "Friday")])

        let wrapped = "Sure! Here is the JSON:\n```json\n\(Fixtures.summaryJSON)\n```\nLet me know if you need more."
        XCTAssertEqual(SummaryParser.parse(wrapped)?.decisions, clean.decisions)
        XCTAssertNil(SummaryParser.parse("I cannot do that."))
    }

    func testParsesLooselyTypedOutput() throws {
        let loose = """
        {"title": "Sync", "summary": "Short.", "key_points": ["A", "a", 42],
         "decisions": [], "action_items": ["Send the report", {"title": "Book room", "assignee": "Sam", "deadline": "none"}],
         "deadlines": [{"what": "Report", "when": "N/A"}]}
        """
        let summary = try XCTUnwrap(SummaryParser.parse(loose))
        XCTAssertEqual(summary.keyPoints, ["A", "42"], "duplicates differing only by case are merged")
        XCTAssertEqual(summary.actionItems.map(\.task), ["Send the report", "Book room"])
        XCTAssertEqual(summary.actionItems[1].owner, "Sam")
        XCTAssertNil(summary.actionItems[1].due, "placeholder values are treated as missing")
        XCTAssertTrue(summary.deadlines.isEmpty)
        XCTAssertTrue(summary.facts.isEmpty)
    }

    func testRepairsOutputCutOffMidway() throws {
        let truncated = """
        {"title": "Sync", "summary": "We talked about the cluster.", "key_points": ["Cluster is old"], "decisions": ["Upgrade the staging clus
        """
        let summary = try XCTUnwrap(SummaryParser.parse(truncated))
        XCTAssertEqual(summary.overview, "We talked about the cluster.")
        XCTAssertEqual(summary.decisions, ["Upgrade the staging clus"])

        let danglingKey = #"{"title": "Sync", "summary": "Fine.", "key_points": ["A"], "decisions":"#
        XCTAssertEqual(SummaryParser.parse(danglingKey)?.keyPoints, ["A"])
        let danglingComma = #"{"title": "Sync", "summary": "Fine.", "key_points": ["A", "#
        XCTAssertEqual(SummaryParser.parse(danglingComma)?.keyPoints, ["A"])
    }

    // MARK: Grounding

    func testGroundingRemovesItemsTheTranscriptDoesNotSupport() {
        let transcript = Fixtures.infrastructureLines.joined(separator: " ")
        var summary = MeetingSummary(
            title: "Infra", overview: "Discussed the Kubernetes staging cluster.",
            decisions: ["Upgrade the staging cluster next week.", "Migrate the billing database to Oracle in March."],
            actionItems: [
                ActionItemDraft(task: "Prepare the Terraform changes", owner: "Dmitri", due: "Friday"),
                ActionItemDraft(task: "Hire three new backend engineers", owner: nil, due: nil),
            ],
            deadlines: [DeadlineNote(what: "Terraform changes", when: "Friday"),
                        DeadlineNote(what: "Terraform changes", when: "31 December")],
            facts: ["The staging cluster is two versions behind production.", "The company revenue grew by forty percent."])
        summary = Grounding.filter(summary, transcript: transcript)

        XCTAssertEqual(summary.decisions, ["Upgrade the staging cluster next week."])
        XCTAssertEqual(summary.actionItems.map(\.task), ["Prepare the Terraform changes"])
        XCTAssertNil(summary.actionItems.first?.owner, "an owner never named in the recording is dropped")
        XCTAssertEqual(summary.actionItems.first?.due, "Friday")
        XCTAssertEqual(summary.deadlines, [DeadlineNote(what: "Terraform changes", when: "Friday")])
        XCTAssertEqual(summary.facts, ["The staging cluster is two versions behind production."])
    }

    // MARK: Due dates

    func testDueDateParsing() {
        let reference = Fixtures.date(2026, 1, 27) // Tuesday
        let calendar = Fixtures.utc
        func parse(_ text: String) -> Date? { DueDateParser.parse(text, relativeTo: reference, calendar: calendar) }

        XCTAssertEqual(parse("tomorrow"), Fixtures.date(2026, 1, 28, hour: 0))
        XCTAssertEqual(parse("by Friday"), Fixtures.date(2026, 1, 30, hour: 0))
        XCTAssertEqual(parse("next Tuesday"), Fixtures.date(2026, 2, 3, hour: 0), "the same weekday means a week later")
        XCTAssertEqual(parse("Feb 3"), Fixtures.date(2026, 2, 3, hour: 0))
        XCTAssertEqual(parse("due February 3rd, 2027"), Fixtures.date(2027, 2, 3, hour: 0))
        XCTAssertEqual(parse("3 March"), Fixtures.date(2026, 3, 3, hour: 0))
        XCTAssertEqual(parse("2026-02-10"), Fixtures.date(2026, 2, 10, hour: 0))
        XCTAssertEqual(parse("in two weeks"), Fixtures.date(2026, 2, 10, hour: 0))
        XCTAssertEqual(parse("in 3 days"), Fixtures.date(2026, 1, 30, hour: 0))
        XCTAssertEqual(parse("end of the week"), Fixtures.date(2026, 1, 30, hour: 0))
        XCTAssertEqual(parse("end of month"), Fixtures.date(2026, 1, 31, hour: 0))
        XCTAssertNil(parse("soon"))
        XCTAssertNil(parse("when the vendor replies"))

        let december = Fixtures.date(2026, 12, 20)
        XCTAssertEqual(DueDateParser.parse("Feb 3", relativeTo: december, calendar: calendar), Fixtures.date(2027, 2, 3, hour: 0))
    }

    // MARK: Summaries

    private func segments(_ lines: [String]) -> [TranscriptSegment] {
        lines.enumerated().map { index, line in
            TranscriptSegment(id: Int64(index + 1), recordingID: "r", index: index, start: Double(index) * 5,
                              end: Double(index) * 5 + 5, text: line)
        }
    }

    func testExtractiveSummaryOnlyQuotesTheTranscript() async throws {
        let lines = Fixtures.infrastructureLines
        let summary = try await Summarizer(llm: nil).summarize(segments: segments(lines), title: "Infra", template: .meeting)

        XCTAssertEqual(summary.engine, "extractive")
        XCTAssertFalse(summary.isFromLanguageModel)
        XCTAssertFalse(summary.overview.isEmpty)
        XCTAssertTrue(summary.decisions.contains("We decided to upgrade the staging cluster next week."))
        XCTAssertTrue(summary.actionItems.contains { $0.task == "I will prepare the Terraform changes by Friday." })
        XCTAssertEqual(summary.actionItems.first { $0.task.contains("Terraform") }?.due, "by friday")
        for sentence in summary.keyPoints + summary.decisions + summary.actionItems.map(\.task) {
            XCTAssertTrue(lines.contains(sentence), "extractive output must be a verbatim sentence: \(sentence)")
        }
    }

    func testEmptyTranscriptProducesEmptySummaryWithoutCallingTheModel() async throws {
        let model = FakeLanguageModel { _ in Fixtures.summaryJSON }
        let summary = try await Summarizer(llm: model).summarize(segments: [], title: "Silence", template: .meeting)
        XCTAssertTrue(model.calls.isEmpty)
        XCTAssertTrue(summary.decisions.isEmpty && summary.actionItems.isEmpty && summary.overview.isEmpty)
    }

    func testLanguageModelSummaryIsStructuredAndGrounded() async throws {
        let invented = Fixtures.summaryJSON.replacingOccurrences(
            of: #""decisions": ["#, with: #""decisions": ["Replace Kubernetes with a mainframe by Christmas.", "#)
        let model = FakeLanguageModel { _ in invented }
        let summary = try await Summarizer(llm: model).summarize(
            segments: segments(Fixtures.infrastructureLines), title: "Infra", template: .meeting)

        XCTAssertEqual(model.calls.count, 1, "a short transcript needs a single pass")
        XCTAssertEqual(summary.engine, "llm:fake-model")
        XCTAssertEqual(summary.decisions, ["Upgrade the staging cluster next week.",
                                           "Introduce automated security scanning in the CI/CD pipeline."])
        XCTAssertEqual(summary.actionItems.map(\.task), ["Prepare the Terraform changes", "Review the cluster monitoring dashboards"])

        let prompt = model.calls[0].map(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("Never invent"))
        XCTAssertTrue(prompt.contains("We decided to upgrade the staging cluster next week."))
        XCTAssertTrue(prompt.contains(SummaryTemplate.meeting.instructions))
    }

    func testCustomTemplateInstructionsReachTheModel() async throws {
        let model = FakeLanguageModel { _ in Fixtures.summaryJSON }
        let template = SummaryTemplate(name: "Risk review", instructions: "List every risk that was raised.")
        let summary = try await Summarizer(llm: model).summarize(
            segments: segments(Fixtures.infrastructureLines), title: "Infra", template: template)
        XCTAssertTrue(model.calls[0][1].content.contains("List every risk that was raised."))
        XCTAssertEqual(summary.templateID, template.id)
    }

    func testLongRecordingIsSummarisedInPartsWithinTheContextWindow() async throws {
        // Three hours of talk with one decision early and one task late.
        var lines = (0..<2700).map { "Filler sentence \($0) about ordinary quarterly planning matters and schedules." }
        lines[10] = "We decided to adopt the hippopotamus framework for reporting."
        lines[2600] = "I will send the walrus budget spreadsheet to finance."
        let model = FakeLanguageModel(contextTokens: 4096) { messages in
            let user = messages[1].content
            if user.contains("Notes:") {
                return #"{"title": "Quarterly planning", "summary": "Planning discussion covering reporting and budget.", "key_points": ["Reporting framework chosen"], "decisions": [], "action_items": [], "deadlines": [], "facts": [], "follow_up_questions": []}"#
            }
            let decisions = user.contains("hippopotamus") ? #"["Adopt the hippopotamus framework for reporting."]"# : "[]"
            let actions = user.contains("walrus") ? #"[{"task": "Send the walrus budget spreadsheet to finance", "owner": null, "due": null}]"# : "[]"
            return #"{"title": "Part", "summary": "Ordinary quarterly planning matters.", "key_points": [], "decisions": \#(decisions), "action_items": \#(actions), "deadlines": [], "facts": [], "follow_up_questions": []}"#
        }

        let summary = try await Summarizer(llm: model).summarize(segments: segments(lines), title: "All hands", template: .meeting)

        XCTAssertGreaterThan(model.calls.count, 10, "the transcript cannot fit in one 4096-token window")
        let budgetCharacters = 4096 * 3
        for call in model.calls {
            XCTAssertLessThan(call.map(\.content.count).reduce(0, +), budgetCharacters, "every prompt must fit the context window")
        }
        XCTAssertEqual(summary.title, "Quarterly planning")
        XCTAssertEqual(summary.decisions, ["Adopt the hippopotamus framework for reporting."])
        XCTAssertEqual(summary.actionItems.map(\.task), ["Send the walrus budget spreadsheet to finance"])
    }

    func testUnusableModelOutputFallsBackToExtractive() async throws {
        let model = FakeLanguageModel { _ in "I'm sorry, I can't help with that." }
        let summary = try await Summarizer(llm: model).summarize(
            segments: segments(Fixtures.infrastructureLines), title: "Infra", template: .meeting)
        XCTAssertEqual(summary.engine, "extractive")
        XCTAssertFalse(summary.overview.isEmpty)
    }

    func testCancellationStopsSummarisation() async {
        let model = FakeLanguageModel { _ in Fixtures.summaryJSON }
        do {
            _ = try await Summarizer(llm: model).summarize(
                segments: segments(Fixtures.infrastructureLines), title: "Infra", template: .meeting, isCancelled: { true })
            XCTFail("expected cancellation")
        } catch {
            guard case EngineError.cancelled = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertTrue(model.calls.isEmpty)
    }

    func testTasksGetDueDatesAndSourcePositions() throws {
        let recording = Recording(title: "Infra", createdAt: Fixtures.date(2026, 1, 27), fileName: "a.pmenc")
        let summary = try XCTUnwrap(SummaryParser.parse(Fixtures.summaryJSON))
        let tasks = TaskExtractor.tasks(from: summary, recording: recording,
                                        segments: segments(Fixtures.infrastructureLines), calendar: Fixtures.utc)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].dueAt, Fixtures.date(2026, 1, 30, hour: 0), "Friday after Tuesday 27 January")
        XCTAssertEqual(tasks[0].dueText, "Friday")
        XCTAssertEqual(tasks[0].sourceStart, 25, "points at the sentence 'I will prepare the Terraform changes'")
        XCTAssertEqual(tasks[1].owner, "Alex")
        XCTAssertNil(tasks[1].dueAt)
        XCTAssertEqual(tasks[1].sourceStart, 30)
    }

    // MARK: Memory (RAG)

    private func seededStore() throws -> (Store, infra: Recording, k8s: Recording, planning: Recording) {
        let store = try Fixtures.memoryStore()
        let infra = try Fixtures.addRecording(to: store, title: "Infrastructure Sync", date: Fixtures.date(2026, 1, 27, hour: 9),
                                              lines: Fixtures.infrastructureLines)
        let k8s = try Fixtures.addRecording(to: store, title: "Kubernetes Review", date: Fixtures.date(2026, 1, 20, hour: 11), lines: [
            "We reviewed the Kubernetes node pools.", "Autoscaling limits were raised to twelve nodes.",
            "The ingress controller will be replaced in February.",
        ])
        let planning = try Fixtures.addRecording(to: store, title: "Product Planning", date: Fixtures.date(2026, 1, 26, hour: 15), lines: [
            "We reviewed the roadmap for the mobile app.", "Pricing stays the same this quarter.",
        ])
        let summary = try XCTUnwrap(SummaryParser.parse(Fixtures.summaryJSON))
        try store.save(summary, recordingID: infra.id)
        try store.replaceExtractedTasks(recordingID: infra.id, with: TaskExtractor.tasks(
            from: summary, recording: infra, segments: try store.segments(recordingID: infra.id), calendar: Fixtures.utc))
        try store.save(MeetingSummary(title: "Product Planning", overview: "Reviewed the mobile roadmap; pricing unchanged."),
                       recordingID: planning.id)
        return (store, infra, k8s, planning)
    }

    func testAnswerCitesRecordingAndTimestamp() async throws {
        let (store, infra, k8s, _) = try seededStore()
        let model = FakeLanguageModel { _ in "You decided to upgrade the staging cluster next week [S1]." }
        let service = MemoryService(store: store, llm: model, calendar: Fixtures.utc)

        let answer = try await service.answer(question: "What did we decide about Kubernetes?", now: Fixtures.date(2026, 1, 28))

        XCTAssertTrue(answer.foundEvidence)
        XCTAssertEqual(answer.engine, "llm:fake-model")
        XCTAssertEqual(Set(answer.sources.map(\.recordingID)), [infra.id, k8s.id])
        XCTAssertEqual(answer.sources.filter(\.isCited).map(\.label), ["S1"])

        let prompt = model.calls[0][1].content
        XCTAssertTrue(prompt.contains("[S1]") && prompt.contains("[S2]"))
        XCTAssertTrue(prompt.contains("Infrastructure Sync — Tue 27 Jan 2026 — at 00:"), prompt)
        XCTAssertTrue(prompt.contains("Kubernetes Review"))
        XCTAssertFalse(prompt.contains("roadmap"), "unrelated recordings must not be put in the context")
        XCTAssertTrue(model.calls[0][0].content.contains("ONLY the numbered sources"))
    }

    func testNoEvidenceMeansNoModelCallAndAnHonestAnswer() async throws {
        let (store, _, _, _) = try seededStore()
        let model = FakeLanguageModel { _ in "The answer is definitely 42." }
        let service = MemoryService(store: store, llm: model, calendar: Fixtures.utc)

        let answer = try await service.answer(question: "What did we say about submarine cables?", now: Fixtures.date(2026, 1, 28))

        XCTAssertFalse(answer.foundEvidence)
        XCTAssertTrue(answer.sources.isEmpty)
        XCTAssertTrue(answer.text.contains("couldn't find"))
        XCTAssertTrue(model.calls.isEmpty, "with nothing retrieved the model must not be asked to guess")
    }

    func testDateOnlyQuestionUsesThatDaysRecordings() async throws {
        let (store, infra, _, _) = try seededStore()
        let model = FakeLanguageModel { _ in "Yesterday you discussed the staging cluster upgrade [S1]." }
        let service = MemoryService(store: store, llm: model, calendar: Fixtures.utc)

        let answer = try await service.answer(question: "What did I discuss yesterday?", now: Fixtures.date(2026, 1, 28))
        XCTAssertEqual(answer.sources.map(\.recordingID), [infra.id])
        XCTAssertTrue(model.calls[0][1].content.contains("recordings from yesterday"))

        let lastWeek = try await service.answer(question: "Summarize my meetings from last week.", now: Fixtures.date(2026, 1, 28))
        XCTAssertEqual(lastWeek.sources.map(\.recordingTitle), ["Kubernetes Review"])

        let nothing = try await service.answer(question: "What did I discuss today?", now: Fixtures.date(2026, 1, 28))
        XCTAssertFalse(nothing.foundEvidence)
        XCTAssertTrue(nothing.text.contains("from today"))
    }

    func testTaskAndDeadlineQuestionsUseExtractedTasks() async throws {
        let (store, infra, _, _) = try seededStore()
        let service = MemoryService(store: store, llm: nil, calendar: Fixtures.utc)

        let tasks = try await service.answer(question: "What tasks did I promise to complete?", now: Fixtures.date(2026, 1, 28))
        XCTAssertEqual(tasks.engine, "search")
        XCTAssertTrue(tasks.text.contains("Prepare the Terraform changes"))
        XCTAssertTrue(tasks.text.contains("Review the cluster monitoring dashboards"))
        XCTAssertTrue(tasks.sources.allSatisfy { $0.recordingID == infra.id })
        XCTAssertEqual(tasks.sources.first { $0.snippet.contains("Terraform") }?.start, 25)

        let deadlines = try await service.answer(question: "What deadlines were discussed this month?", now: Fixtures.date(2026, 1, 28))
        XCTAssertTrue(deadlines.text.contains("Prepare the Terraform changes"))
        XCTAssertFalse(deadlines.text.contains("monitoring dashboards"), "tasks without a deadline are not deadlines")

        let none = try await service.answer(question: "What deadlines were discussed last month?", now: Fixtures.date(2026, 1, 28))
        XCTAssertFalse(none.foundEvidence)
    }

    func testWithoutAModelTheAnswerListsMatchingPassages() async throws {
        let (store, infra, _, _) = try seededStore()
        let service = MemoryService(store: store, llm: nil, calendar: Fixtures.utc)
        let answer = try await service.answer(question: "Find conversations where I mentioned Terraform.", now: Fixtures.date(2026, 1, 28))
        XCTAssertEqual(answer.engine, "search")
        XCTAssertEqual(answer.sources.map(\.recordingID), [infra.id])
        XCTAssertTrue(answer.text.lowercased().contains("terraform"))
        XCTAssertTrue(answer.text.contains("[S1]"))
    }

    func testRetrievedContextIsTrimmedToTheContextWindow() async throws {
        let store = try Fixtures.memoryStore()
        for index in 0..<12 {
            try Fixtures.addRecording(to: store, title: "Sync \(index)", date: Fixtures.date(2026, 1, 1 + index), lines:
                (0..<12).map { "Line \($0): the observability budget was debated again at great length today." })
        }
        let model = FakeLanguageModel(contextTokens: 1024) { _ in "It was debated [S1]." }
        let service = MemoryService(store: store, llm: model, calendar: Fixtures.utc)
        let answer = try await service.answer(question: "What about the observability budget?", now: Fixtures.date(2026, 2, 1))

        XCTAssertLessThan(model.calls[0].map(\.content.count).reduce(0, +), 1024 * 3)
        XCTAssertFalse(answer.sources.isEmpty)
        XCTAssertLessThan(answer.sources.count, 6, "sources that did not fit are not presented as evidence")
    }

    func testCitationParsing() {
        XCTAssertEqual(MemoryService.citedLabels(in: "A [S1]. B [S3][S12]. C [s2] [S] [S100]"), ["S1", "S3", "S12"])
    }
}
