import SwiftUI

/// The Notes tab (FR15 §6): what is waiting to send, what needs a look, and
/// the rest — each row saying what the note did.
struct NotesView: View {
    @Environment(AppModel.self) private var app
    @State private var model = NotesModel()
    @State private var isListening = false
    @State private var failedNote: QueuedNote?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabHeader(title: "Notes") { AccountButton() }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        content
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 96)
                }
                .refreshable { await model.reload() }
            }
            .background(Color.appBackground)
            .overlay(alignment: .bottomTrailing) { micButton }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Note.self) { NoteDetailView(note: $0) }
        }
        .task { await model.start() }
        .sheet(isPresented: $isListening) {
            ListeningSheet()
                .presentationDetents([.medium])
                .presentationCornerRadius(20)
                .presentationBackground(Color.surface)
        }
        .alert(
            "This note wasn't sent",
            isPresented: Binding(get: { failedNote != nil }, set: { if !$0 { failedNote = nil } }),
            presenting: failedNote
        ) { note in
            Button("Try again") { Task { await model.retry(note) } }
            Button("Keep it here", role: .cancel) {}
        } message: { note in
            if case .failed(let reason) = note.state { Text(reason) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !app.isOnline, !model.queued.isEmpty {
            Notice(
                systemName: "wifi.slash",
                text: Text("**No signal.** \(waitingSentence) They’re saved on your phone — nothing is lost."))
            .padding(.bottom, 14)
        }

        if !model.queued.isEmpty {
            SectionLabel("Waiting to send")
            Card {
                ForEach(Array(model.queued.enumerated()), id: \.element.id) { index, note in
                    queuedRow(note, isLast: index == model.queued.count - 1)
                }
            }
            if !app.isOnline {
                Text("They’ll go up on their own when you have signal. You can keep capturing.")
                    .font(.scaled(12.5))
                    .foregroundStyle(Color.ink2)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
            }
            Spacer().frame(height: 18)
        }

        if !model.needingAttention.isEmpty {
            SectionLabel("Needs a look")
            noteCard(model.needingAttention)
            Spacer().frame(height: 18)
        }

        if !model.earlier.isEmpty {
            SectionLabel("Earlier")
            noteCard(model.earlier)
        }

        if model.canLoadMore {
            Button("Show 25 more") { Task { await model.loadMore() } }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 12)
        }

        if let error = model.loadError {
            Text(error)
                .font(.scaled(12.5))
                .foregroundStyle(Color.failure)
                .padding(.top, 12)
        }

        if model.queued.isEmpty, model.notes.isEmpty, !model.isLoading {
            emptyState
        }
    }

    private var waitingSentence: String {
        let count = model.queued.count
        return count == 1 ? "One note is waiting to send." : "\(count) notes are waiting to send."
    }

    private func queuedRow(_ note: QueuedNote, isLast: Bool) -> some View {
        let failed: Bool = if case .failed = note.state { true } else { false }
        return ListRow(
            icon: RowIcon(systemName: failed ? "exclamationmark.circle" : "clock", tone: failed ? .failure : .amber),
            title: NoteFormat.excerpt(note.body),
            subtitle: NoteFormat.subtitle(for: note),
            showsDivider: !isLast)
        .onTapGesture { if failed { failedNote = note } }
        .accessibilityAddTraits(failed ? .isButton : [])
    }

    private func noteCard(_ notes: [Note]) -> some View {
        Card {
            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                NavigationLink(value: note) {
                    ListRow(
                        icon: Self.icon(for: note),
                        title: NoteFormat.excerpt(note.body, limit: 70)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "“”")),
                        subtitle: NoteFormat.subtitle(for: note),
                        showsDivider: index < notes.count - 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    static func icon(for note: Note) -> RowIcon {
        let symbol = switch note.source {
        case .siri, .appRecorder: "mic"
        case .typed: "text.alignleft"
        case .emailForward: "envelope"
        }
        let tone: RowIcon.Tone = switch note.status {
        case .needsLook: .violet
        case .needsAnswer: .amber
        case .applied: .green
        case .logged, .unfiled: .neutral
        }
        return RowIcon(systemName: symbol, tone: tone)
    }

    private var emptyState: some View {
        SiriPrompt().padding(.top, 36)
    }

    private var micButton: some View {
        Button {
            isListening = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.amber, in: Circle())
        }
        .padding(16)
        .accessibilityLabel("Take a note")
    }
}
