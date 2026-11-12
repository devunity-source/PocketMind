import SwiftUI
import PocketMindCore

struct TaskRow: View {
    let task: TaskItem
    let sourceTitle: String?
    let toggle: () -> Void

    private var dueLabel: String? {
        if let dueAt = task.dueAt { return "Due " + dueAt.formatted(.dateTime.month(.abbreviated).day()) }
        if let dueText = task.dueText { return "Due " + dueText }
        return nil
    }

    private var isOverdue: Bool {
        guard let dueAt = task.dueAt, !task.isDone else { return false }
        return dueAt < Calendar.current.startOfDay(for: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.m) {
            Button(action: toggle) {
                Image(systemName: task.isDone ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(task.isDone ? Theme.Palette.accent : Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Theme.Palette.textSecondary : Theme.Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                let details = [task.owner, sourceTitle, dueLabel].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(isOverdue ? Theme.Palette.danger : Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct TasksView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var pipeline: ProcessingPipeline

    enum Scope: String, CaseIterable { case open = "Open", completed = "Completed", all = "All" }

    @State private var scope: Scope = .open
    @State private var tasks: [TaskItem] = []
    @State private var titles: [String: String] = [:]
    @State private var openCount = 0
    @State private var showAdd = false
    @State private var newTitle = ""
    @State private var newHasDue = false
    @State private var newDue = Date()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { scope in
                        Text(scope == .open ? "Open (\(openCount))" : scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(Theme.Spacing.l)

                if tasks.isEmpty {
                    Spacer()
                    EmptyStateView(icon: "checklist", title: scope == .completed ? "Nothing completed yet" : "No tasks",
                                   message: "Action items found in your recordings appear here, linked to the moment they were said. You can also add your own.")
                    Spacer()
                } else {
                    List {
                        ForEach(tasks) { task in
                            row(task)
                                .listRowBackground(Theme.Palette.background)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        try? environment.store.deleteTask(id: task.id)
                                        environment.touch()
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .screenBackground()
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add task")
                }
            }
            .navigationDestination(for: RecordingRoute.self) { RecordingDetailView(route: $0) }
            .sheet(isPresented: $showAdd) { addSheet }
            .task(id: "\(environment.revision)-\(pipeline.revision)-\(scope.rawValue)") { reload() }
        }
    }

    @ViewBuilder
    private func row(_ task: TaskItem) -> some View {
        let taskRow = TaskRow(task: task, sourceTitle: task.recordingID.flatMap { titles[$0] }) {
            try? environment.store.setTaskDone(!task.isDone, id: task.id)
            environment.touch()
        }
        if let recordingID = task.recordingID {
            // Opens the recording at the moment the task was mentioned.
            NavigationLink(value: RecordingRoute(recordingID: recordingID, seekTo: task.sourceStart)) { taskRow }
        } else {
            taskRow
        }
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                TextField("What needs to be done?", text: $newTitle, axis: .vertical)
                Toggle("Due date", isOn: $newHasDue)
                if newHasDue {
                    DatePicker("Due", selection: $newDue, displayedComponents: .date)
                }
            }
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showAdd = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        try? environment.store.save(TaskItem(title: title, dueAt: newHasDue ? newDue : nil, origin: .manual))
                        newTitle = ""
                        newHasDue = false
                        showAdd = false
                        environment.touch()
                    }
                    .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func reload() {
        let store = environment.store
        let storeScope: Store.TaskScope = scope == .open ? .open : (scope == .completed ? .completed : .all)
        tasks = (try? store.tasks(storeScope)) ?? []
        openCount = ((try? store.tasks(.open)) ?? []).count
        var found: [String: String] = [:]
        for id in Set(tasks.compactMap(\.recordingID)) {
            found[id] = (try? store.recording(id: id))?.title
        }
        titles = found
    }
}
