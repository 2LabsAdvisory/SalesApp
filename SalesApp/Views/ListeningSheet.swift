import SwiftUI

/// Capture — listening (FR15 §6): the mic, pressed. A live level meter, a
/// timer, and — on screen, because it is the only place a seller would learn
/// it — the fact that transcription happens on the phone.
///
/// Stop saves the note through the same path Siri uses, so the two are
/// identical (FR15 §7).
struct ListeningSheet: View {
    /// Set when the note is taken from a deal, so it files against it.
    var opportunityId: String?
    @Environment(\.dismiss) private var dismiss
    @State private var capture = SpeechCapture()
    @State private var message: String?

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.border).frame(width: 36, height: 5).padding(.top, 8)

            if case .unavailable(let reason) = capture.phase {
                explanation(reason)
            } else if let message {
                explanation(message)
            } else {
                listening
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(Color.surface)
        .task { await capture.start() }
        .onDisappear { if capture.phase == .listening { capture.cancel() } }
        .interactiveDismissDisabled(capture.phase == .listening || capture.phase == .finishing)
    }

    private var listening: some View {
        VStack(spacing: 0) {
            Image(systemName: "mic.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(Color.amber, in: Circle())
                .background(Circle().fill(Color.amber.opacity(0.16)).padding(-12))
                .background(Circle().fill(Color.amber.opacity(0.08)).padding(-26))
                .padding(.top, 40)
                .padding(.bottom, 20)
                .accessibilityHidden(true)

            Text(title)
                .font(.scaled(18, .bold))
                .foregroundStyle(Color.ink)

            Text("Say what happened. Names, numbers, dates — it sorts them out after.")
                .font(.scaled(13.5))
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 250)
                .padding(.top, 6)

            LevelMeter(level: capture.level)
                .frame(height: 34)
                .padding(.top, 22)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("\(elapsed(at: context.date)) · transcribed on your phone")
                    .font(.mono(11.5, weight: .regular))
                    .foregroundStyle(Color.ink3)
            }
            .padding(.top, 20)
            .padding(.bottom, 26)

            Button("Stop") { Task { await stopAndSave() } }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(capture.phase != .listening)

            Button("Discard") {
                capture.cancel()
                dismiss()
            }
            .font(.scaled(13, .medium))
            .foregroundStyle(Color.ink2)
            .padding(.top, 12)
            .disabled(capture.phase != .listening)
        }
    }

    private var title: String {
        switch capture.phase {
        case .preparing: "Getting ready…"
        case .finishing: "Saving…"
        default: "Listening…"
        }
    }

    private func explanation(_ text: String) -> some View {
        VStack(spacing: 18) {
            Text(text)
                .font(.scaled(14))
                .foregroundStyle(Color.ink2)
                .multilineTextAlignment(.center)
                .padding(.top, 48)
            Button("Close") { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let start = capture.startedAt else { return "0:00" }
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func stopAndSave() async {
        let text = await capture.stop()
        do {
            switch try await AppServices.shared.capture.capture(text, source: .appRecorder, about: opportunityId) {
            case .nothingHeard:
                message = "Nothing was heard, so nothing was saved."
            case .saved, .savedAwaitingSignIn:
                dismiss()
            }
        } catch {
            message = "The note couldn't be saved on this phone. Please try again."
        }
    }
}

/// Bars that follow the voice. Decorative; VoiceOver hears the timer instead.
struct LevelMeter: View {
    let level: Float
    private let shape: [CGFloat] = [0.25, 0.5, 0.8, 1, 0.7, 0.35, 0.6, 0.95, 0.55, 0.28, 0.45, 0.75, 0.4]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(shape.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.amber.opacity(0.85))
                    .frame(width: 4, height: max(4, 34 * shape[index] * CGFloat(max(level, 0.08))))
            }
        }
        .animation(.easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}
