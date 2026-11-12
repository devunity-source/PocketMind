import SwiftUI
import UniformTypeIdentifiers
import PocketMindCore

struct LibraryView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var pipeline: ProcessingPipeline

    enum DatePreset: String, CaseIterable, Identifiable {
        case any = "Any time", today = "Today", week = "Last 7 days", month = "Last 30 days", year = "This year"
        var id: String { rawValue }

        var interval: DateInterval? {
            let calendar = Calendar.current
            let now = Date()
            let startOfToday = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
            switch self {
            case .any: return nil
            case .today: return DateInterval(start: startOfToday, end: end)
            case .week: return DateInterval(start: calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday, end: end)
            case .month: return DateInterval(start: calendar.date(byAdding: .day, value: -30, to: startOfToday) ?? startOfToday, end: end)
            case .year: return calendar.dateInterval(of: .year, for: now)
            }
        }
    }

    @State private var filter = LibraryFilter()
    @State private var datePreset: DatePreset = .any
    @State private var recordings: [Recording] = []
    @State private var previews: [String: String] = [:]
    @State private var folders: [Folder] = []
    @State private var tags: [String] = []
    @State private var languages: [String] = []
    @State private var showImporter = false
    @State private var showFolders = false
    @State private var showTrash = false

    private var hasActiveFilter: Bool {
        filter.favoritesOnly || filter.folderID != nil || filter.tag != nil || filter.language != nil || datePreset != .any
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                kindChips
                if recordings.isEmpty {
                    Spacer()
                    EmptyStateView(
                        icon: filter.searchText.isEmpty && !hasActiveFilter ? "waveform" : "magnifyingglass",
                        title: filter.searchText.isEmpty && !hasActiveFilter ? "No recordings" : "No matches",
                        message: filter.searchText.isEmpty && !hasActiveFilter
                            ? "Recordings you make or import appear here."
                            : "Try different words or remove a filter. Search covers titles, tags and transcript text.")
                    Spacer()
                } else {
                    List {
                        ForEach(recordings) { recording in
                            NavigationLink(value: RecordingRoute(recordingID: recording.id)) {
                                RecordingRow(recording: recording, job: pipeline.job(for: recording.id), preview: previews[recording.id])
                            }
                            .listRowBackground(Theme.Palette.background)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { environment.moveToTrash(recording) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button { toggleFavorite(recording) } label: {
                                    Label(recording.isFavorite ? "Unfavorite" : "Favorite",
                                          systemImage: recording.isFavorite ? "star.slash" : "star")
                                }
                                .tint(Theme.Palette.warning)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .screenBackground()
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $filter.searchText, prompt: "Search titles and transcripts")
            .toolbar { toolbar }
            .navigationDestination(for: RecordingRoute.self) { RecordingDetailView(route: $0) }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                guard case .success(let urls) = result else { return }
                Task { for url in urls { await environment.importAudioFile(at: url) } }
            }
            .sheet(isPresented: $showFolders) { FoldersView() }
            .sheet(isPresented: $showTrash) { TrashView() }
            .task(id: "\(environment.revision)-\(pipeline.revision)") { reload() }
            .onChange(of: filter) { _, _ in reload() }
            .onChange(of: datePreset) { _, preset in filter.dateRange = preset.interval }
        }
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                Button { filter.kind = nil } label: { Chip(text: "All", selected: filter.kind == nil) }
                ForEach(RecordingKind.allCases, id: \.self) { kind in
                    Button { filter.kind = kind } label: { Chip(text: kind.label, selected: filter.kind == kind) }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Button { showImporter = true } label: { Label("Import audio file", systemImage: "square.and.arrow.down") }
                Button { showFolders = true } label: { Label("Folders", systemImage: "folder") }
                Button { showTrash = true } label: { Label("Recently deleted", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Toggle(isOn: $filter.favoritesOnly) { Label("Favorites only", systemImage: "star") }
                Picker("Date", selection: $datePreset) {
                    ForEach(DatePreset.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                Picker("Folder", selection: $filter.folderID) {
                    Text("All folders").tag(String?.none)
                    ForEach(folders) { Text($0.name).tag(String?.some($0.id)) }
                }
                .pickerStyle(.menu)
                Picker("Tag", selection: $filter.tag) {
                    Text("All tags").tag(String?.none)
                    ForEach(tags, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
                Picker("Language", selection: $filter.language) {
                    Text("All languages").tag(String?.none)
                    ForEach(languages, id: \.self) { Text(SupportedLanguage.name(for: $0)).tag(String?.some($0)) }
                }
                .pickerStyle(.menu)
                if hasActiveFilter {
                    Button("Clear filters", role: .destructive) {
                        let search = filter.searchText
                        let kind = filter.kind
                        filter = LibraryFilter()
                        filter.searchText = search
                        filter.kind = kind
                        datePreset = .any
                    }
                }
            } label: {
                Image(systemName: hasActiveFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Filters")
        }
    }

    private func toggleFavorite(_ recording: Recording) {
        var updated = recording
        updated.isFavorite.toggle()
        try? environment.store.save(updated)
        environment.touch()
    }

    private func reload() {
        let store = environment.store
        recordings = (try? store.recordings(matching: filter)) ?? []
        folders = (try? store.folders()) ?? []
        tags = (try? store.allTags()) ?? []
        languages = (try? store.allLanguages()) ?? []

        var texts: [String: String] = [:]
        // While searching, show where the words were found instead of the generic preview.
        let keywords = SearchQuery.keywords(in: filter.searchText, dropStopwords: false)
        if let fts = SearchQuery.ftsExpression(for: keywords, matchAll: true),
           let hits = try? store.searchChunks(ftsQuery: fts, limit: 60) {
            for hit in hits where texts[hit.chunk.recordingID] == nil {
                texts[hit.chunk.recordingID] = "\(Format.duration(hit.chunk.start))  \(hit.snippet)"
            }
        }
        for recording in recordings.prefix(120) where texts[recording.id] == nil {
            texts[recording.id] = try? store.previewText(recordingID: recording.id)
        }
        previews = texts
    }
}

struct FoldersView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [Folder] = []
    @State private var newName = ""
    @State private var renaming: Folder?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("New folder") {
                    HStack {
                        TextField("Folder name", text: $newName)
                        Button("Add") {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            guard !name.isEmpty else { return }
                            try? environment.store.save(Folder(name: name))
                            newName = ""
                            reload()
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Folders") {
                    if folders.isEmpty {
                        Text("No folders yet").foregroundStyle(Theme.Palette.textSecondary)
                    }
                    ForEach(folders) { folder in
                        Button(folder.name) {
                            renameText = folder.name
                            renaming = folder
                        }
                        .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    .onDelete { offsets in
                        for index in offsets { try? environment.store.deleteFolder(id: folders[index].id) }
                        reload()
                    }
                }
                Section {
                    Text("Deleting a folder keeps its recordings. Assign a recording to a folder from its ••• menu.")
                        .font(.footnote).foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            .navigationTitle("Folders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if var folder = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        folder.name = renameText.trimmingCharacters(in: .whitespaces)
                        try? environment.store.save(folder)
                        reload()
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .task { reload() }
        }
    }

    private func reload() {
        folders = (try? environment.store.folders()) ?? []
        environment.touch()
    }
}

struct TrashView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var recordings: [Recording] = []
    @State private var confirmEmpty = false

    var body: some View {
        NavigationStack {
            List {
                if recordings.isEmpty {
                    Text("Nothing here").foregroundStyle(Theme.Palette.textSecondary)
                } else {
                    Section {
                        ForEach(recordings) { recording in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(recording.title)
                                Text("\(Format.dateTime(recording.createdAt)) · \(Format.shortDuration(recording.duration))")
                                    .font(.caption).foregroundStyle(Theme.Palette.textSecondary)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    environment.deletePermanently([recording])
                                    reload()
                                } label: { Label("Delete now", systemImage: "trash.slash") }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    environment.restore(recording)
                                    reload()
                                } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                                .tint(Theme.Palette.success)
                            }
                        }
                    } footer: {
                        Text("Deleted recordings are kept for \(settings.trashDays) days, then removed permanently together with their transcript, summary, tasks and encrypted audio. Swipe right to restore, left to delete now.")
                    }
                }
            }
            .navigationTitle("Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Empty", role: .destructive) { confirmEmpty = true }.disabled(recordings.isEmpty)
                }
            }
            .confirmationDialog("Permanently delete \(recordings.count) recording\(recordings.count == 1 ? "" : "s")?",
                                isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Delete permanently", role: .destructive) {
                    environment.deletePermanently(recordings)
                    reload()
                }
            } message: {
                Text("This cannot be undone.")
            }
            .task { reload() }
        }
    }

    private func reload() {
        var filter = LibraryFilter()
        filter.trashed = true
        recordings = (try? environment.store.recordings(matching: filter)) ?? []
    }
}
