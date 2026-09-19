import SwiftUI

/// One note, readable. Reviewing it — filing it, accepting what it proposes —
/// happens on the desktop until FR17 brings review to the phone.
struct NoteDetailView: View {
    let note: Note
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Note") {
                Button("Done") { dismiss() }
                    .font(.scaled(15, .semibold))
                    .foregroundStyle(Color.amber600)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Card {
                        Text(note.body)
                            .font(.scaled(15))
                            .foregroundStyle(Color.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }

                    Card {
                        detail("Said", note.saidAt.formatted(date: .abbreviated, time: .shortened))
                        detail("Came from", note.source.label)
                        detail("What it did", note.outcome ?? "Nothing yet", isLast: linked == nil)
                        if let linked {
                            detail("About", linked, isLast: true)
                        }
                    }

                    Notice(
                        systemName: "desktopcomputer",
                        text: Text("To file this note or act on it, open Notes in Sales on your computer."),
                        tone: .info)
                }
                .padding(14)
            }
        }
        .background(Color.appBackground)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var linked: String? {
        let names = [note.opportunityName, note.customerName, note.contactName].compactMap { $0 }
        return names.isEmpty ? nil : names.joined(separator: " · ")
    }

    private func detail(_ label: String, _ value: String, isLast: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.scaled(13)).foregroundStyle(Color.ink2)
                Spacer(minLength: 16)
                Text(value).font(.scaled(13, .medium)).foregroundStyle(Color.ink)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if !isLast { Rectangle().fill(Color.border2).frame(height: 1) }
        }
    }
}
