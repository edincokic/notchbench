//
//  NotesManager.swift
//  boringNotch
//
//  Stores quick notes. Saved automatically to Application Support/Notes/notes.json.
//

import Foundation

struct QuickNote: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var updated: Date
    var isPinned: Bool

    /// First non-empty line, used in the list.
    var title: String {
        let line = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return line.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "New note"
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

@MainActor
final class NotesManager: ObservableObject {
    static let shared = NotesManager()

    @Published private(set) var notes: [QuickNote] = []
    @Published var selectedID: UUID?

    private let saveQueue = DispatchQueue(label: "boringNotch.notes.save", qos: .utility)
    private var saveTask: Task<Void, Never>?

    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("notes.json")
    }()

    private init() {
        load()
        selectedID = sortedNotes.first?.id
    }

    /// Pinned first, then most recently edited.
    var sortedNotes: [QuickNote] {
        notes.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updated > $1.updated
        }
    }

    var selectedNote: QuickNote? {
        notes.first { $0.id == selectedID }
    }

    // MARK: - Editing

    @discardableResult
    func newNote() -> QuickNote {
        // Reuse an empty note instead of piling them up.
        if let empty = notes.first(where: \.isEmpty) {
            selectedID = empty.id
            return empty
        }
        let note = QuickNote(id: UUID(), text: "", updated: Date(), isPinned: false)
        notes.append(note)
        selectedID = note.id
        save()
        return note
    }

    func select(_ note: QuickNote) {
        guard note.id != selectedID else { return }
        removeEmptyNotes(except: note.id)
        selectedID = note.id
    }

    func updateText(_ text: String, for id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updated = Date()
        save()
    }

    func togglePin(_ note: QuickNote) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        notes[index].isPinned.toggle()
        save()
    }

    func delete(_ note: QuickNote) {
        notes.removeAll { $0.id == note.id }
        if selectedID == note.id {
            selectedID = sortedNotes.first?.id
        }
        save()
    }

    /// Called when the tab closes, so empty notes don't stick around.
    func cleanUp() {
        removeEmptyNotes(except: nil)
        if selectedID == nil || selectedNote == nil {
            selectedID = sortedNotes.first?.id
        }
    }

    private func removeEmptyNotes(except keep: UUID?) {
        let before = notes.count
        notes.removeAll { $0.isEmpty && $0.id != keep }
        if notes.count != before { save() }
    }

    // MARK: - Saving

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([QuickNote].self, from: data) else { return }
        notes = saved
    }

    /// Saves shortly after the last change, so typing doesn't write on every key.
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.writeNow()
        }
    }

    /// Writes right away. `waitUntilDone` is used when the app quits.
    func writeNow(waitUntilDone: Bool = false) {
        saveTask?.cancel()
        let snapshot = notes
        let url = fileURL
        let write = {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
        if waitUntilDone {
            saveQueue.sync(execute: write)
        } else {
            saveQueue.async(execute: write)
        }
    }
}
