import SwiftUI

struct RightSidebarView: View {
    let document: PDFDocument?
    let section: Section?
    @ObservedObject var historyStore: InteractionHistoryStore
    let onSelectNote: (Note) -> Void

    var body: some View {
        TabView {
            DigestPanelView(document: document, section: section, historyStore: historyStore)
                .tabItem {
                    Label("Study", systemImage: "text.book.closed")
                }

            NotesPanelView(historyStore: historyStore, onSelectNote: onSelectNote)
                .tabItem {
                    Label("Notes", systemImage: "note.text")
                }
        }
    }
}

private struct NotesPanelView: View {
    @ObservedObject var historyStore: InteractionHistoryStore
    let onSelectNote: (Note) -> Void

    var body: some View {
        Group {
            if historyStore.notes.isEmpty {
                ContentUnavailableView(
                    "No Notes Yet",
                    systemImage: "note.text",
                    description: Text("Right-click a highlighted passage in the PDF to add a note with a reference back to that spot."))
            } else {
                List(historyStore.notes) { note in
                    Group {
                        if hasReference(note) {
                            Button {
                                onSelectNote(note)
                            } label: {
                                noteRow(for: note)
                            }
                            .buttonStyle(.plain)
                        } else {
                            noteRow(for: note)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                .listStyle(.sidebar)
            }
        }
    }

    private func referenceTitle(for note: Note) -> String {
        if let sectionTitle = note.sectionTitle, !sectionTitle.isEmpty {
            return sectionTitle
        }

        if let pageIndex = note.pageIndex {
            return "Page \(pageIndex + 1)"
        }

        return "Referenced passage"
    }

    private func hasReference(_ note: Note) -> Bool {
        note.highlightID != nil || note.pageIndex != nil || note.sectionID != nil
    }

    @ViewBuilder
    private func noteRow(for note: Note) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if hasReference(note) {
                    Label(referenceTitle(for: note), systemImage: "arrow.turn.down.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                } else {
                    Text("Note")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                Spacer(minLength: 8)
                Text(note.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let selectedText = note.selectedText, !selectedText.isEmpty {
                Text(selectedText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Text(note.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            if hasReference(note) {
                Label("Open Reference", systemImage: "arrow.right.circle")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("Reference removed")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct NoteComposerSheet: View {
    let selectedText: String?
    let referenceTitle: String
    @Binding var noteText: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(referenceTitle)
                    .font(.headline)

                if let selectedText, !selectedText.isEmpty {
                    Text(selectedText)
                        .font(.body)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text("Note")
                    .font(.subheadline.weight(.medium))

                TextEditor(text: $noteText)
                    .frame(minHeight: 200)
                    .padding(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2)))

                Spacer()
            }
            .padding()
            .navigationTitle("Add Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}