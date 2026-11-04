//
//  NotesView.swift
//  boringNotch
//
//  The Notes tab: a list of notes on the left, the editor on the right.
//  Click into the editor to type; Esc or Done gives focus back to your app.
//

import AppKit
import SwiftUI

struct NotesView: View {
    @ObservedObject var manager = NotesManager.shared
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            sidebar
            editor
        }
        .onAppear { NotchKeyboardFocus.shared.allow() }
        .onDisappear {
            NotchKeyboardFocus.shared.disallow()
            manager.cleanUp()
        }
    }

    // MARK: - List

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    manager.newNote()
                    editorFocused = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            .padding(.horizontal, 6)

            if manager.notes.isEmpty {
                Text("No notes yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(manager.sortedNotes) { note in
                            NoteRow(note: note, isSelected: note.id == manager.selectedID)
                        }
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 170)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Editor

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: .topTrailing) {
            if let note = manager.selectedNote {
                TextEditor(text: Binding(
                    get: { manager.selectedNote?.text ?? "" },
                    set: { manager.updateText($0, for: note.id) }
                ))
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($editorFocused)
                .onExitCommand { finishTyping() }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .overlay(alignment: .topLeading) {
                    if note.text.isEmpty {
                        Text("Start typing…")
                            .font(.system(size: 12))
                            .foregroundStyle(.gray)
                            .padding(.horizontal, 11)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }

                if editorFocused {
                    Button("Done") { finishTyping() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                        .padding(6)
                        .help("Finish typing (Esc)")
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 24))
                        .foregroundStyle(.gray)
                    Button("New note") {
                        manager.newNote()
                        editorFocused = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
    }

    private func finishTyping() {
        editorFocused = false
        NotchKeyboardFocus.shared.finishEditing(restoreFocus: true)
    }
}

private struct NoteRow: View {
    let note: QuickNote
    let isSelected: Bool
    @ObservedObject var manager = NotesManager.shared
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            if note.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(note.updated.formatted(.relative(presentation: .named)))
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if isHovering {
                Button {
                    manager.delete(note)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(isSelected ? 0.14 : (isHovering ? 0.07 : 0)))
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { manager.select(note) }
        .contextMenu {
            Button(note.isPinned ? "Unpin" : "Pin") { manager.togglePin(note) }
            Button("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.text, forType: .string)
            }
            Divider()
            Button("Delete") { manager.delete(note) }
        }
    }
}
