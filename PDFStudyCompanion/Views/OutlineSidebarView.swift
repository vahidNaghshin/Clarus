import SwiftUI

struct OutlineSidebarView: View {
    let document: PDFDocument?
    @Binding var selection: Section?
    @State private var expandedChapterIDs: Set<UUID> = []

    var body: some View {
        Group {
            if let document, !document.chapters.isEmpty {
                List {
                    ForEach(document.chapters) { chapter in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedChapterIDs.contains(chapter.id) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedChapterIDs.insert(chapter.id)
                                    } else {
                                        expandedChapterIDs.remove(chapter.id)
                                    }
                                })) {
                            ForEach(chapter.sections) { section in
                                Button {
                                    selection = section
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(section.title)
                                            .font(.subheadline)
                                            .fontWeight(selection?.id == section.id ? .semibold : .regular)
                                            .foregroundStyle(.primary)
                                            .multilineTextAlignment(.leading)
                                        Text(pageLabel(for: section.pageRange))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .background(selection?.id == section.id ? Color.accentColor.opacity(0.14) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(chapter.title)
                                    .font(.headline)
                                Text("\(chapter.sections.count) sections • \(pageLabel(for: chapter.pageRange))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                HIGEmptyStateView(
                    symbolName: "list.bullet.rectangle.portrait",
                    symbolSize: 40,
                    symbolWeight: .thin,
                    title: "No Contents",
                    titleSize: 15,
                    titleWeight: .semibold,
                    subtitle: "Open a PDF to see its chapter and section structure.",
                    subtitleSize: 12,
                    subtitleMaxWidth: 120,
                    verticalCenterRatio: 0.45,
                    buttonTitle: nil,
                    buttonAction: nil)
            }
        }
        .navigationTitle("Contents")
        .onAppear {
            expandAllChapters()
        }
        .onChange(of: document?.id) { _, _ in
            expandAllChapters()
        }
    }

    private func expandAllChapters() {
        expandedChapterIDs = Set(document?.chapters.map(\.id) ?? [])
    }

    private func pageLabel(for range: ClosedRange<Int>) -> String {
        let startPage = range.lowerBound + 1
        let endPage = range.upperBound + 1
        if startPage == endPage {
            return "Page \(startPage)"
        }
        return "Pages \(startPage)-\(endPage)"
    }
}
