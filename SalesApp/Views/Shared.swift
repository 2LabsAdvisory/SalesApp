import Observation
import SwiftUI

/// One screen's data: what it shows, whether that is live or the last
/// photograph (FR16 §5.6), and what went wrong if neither.
@MainActor
@Observable
final class ScreenData<Value: Sendable> {
    private(set) var value: Value?
    private(set) var asOf: Date?
    private(set) var isLoading = false
    private(set) var error: String?

    var isLive: Bool { value != nil && asOf == nil }

    func load(_ fetch: () async throws -> Loaded<Value>) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await fetch()
            value = loaded.value
            asOf = loaded.asOf
            error = nil
        } catch APIError.offline {
            // Offline with nothing saved: say so, and keep whatever was shown.
            if value == nil { error = "No signal, and nothing saved from before. It will load when you’re connected." }
        } catch let failure as APIError {
            error = failure.message
        } catch {
            self.error = APIError.invalidResponse.message
        }
    }

    /// After a write, show the server's answer without a reload.
    func replace(_ value: Value) {
        self.value = value
        asOf = nil
    }
}

/// The two conditions under which a deal can be changed from the phone: a
/// connection now, and a screen showing live data rather than a photograph.
/// Note capture is not held to this — it has its own queue.
struct WritePermission {
    let allowed: Bool
    let reason: String?

    init(isOnline: Bool, isLive: Bool) {
        allowed = isOnline && isLive
        reason = allowed ? nil : "Changes need a connection. This is what you last saw."
    }
}

/// "No signal. Showing what you last saw — as of 2:14p."
struct AsOfNotice: View {
    let asOf: Date

    var body: some View {
        Notice(
            systemName: "wifi.slash",
            text: Text("**No signal.** Showing what you last saw — \(DealFormat.asOf(asOf).lowercased()). Changes wait until you’re connected."))
    }
}

/// A filter chip with a live count.
struct Chip: View {
    let label: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                if let count {
                    Text("\(count)")
                        .foregroundStyle(isSelected ? Color.amber600 : Color.ink3)
                }
            }
            .font(.scaled(13, .semibold))
            .foregroundStyle(isSelected ? Color.ink : Color.ink2)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isSelected ? Color.amberTint : Color.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(isSelected ? Color.amber : Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(count.map { "\(label), \($0)" } ?? label)
    }
}

/// The account button, in the header of the screens that carry it.
struct AccountButton: View {
    @State private var showsAccount = false

    var body: some View {
        Button {
            showsAccount = true
        } label: {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 22))
                .foregroundStyle(Color.ink2)
        }
        .accessibilityLabel("Account")
        .sheet(isPresented: $showsAccount) {
            AccountSheet().presentationDetents([.large])
        }
    }
}

/// The header of a tab: title, an optional line beneath, and a trailing item.
struct TabHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.display(19))
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.scaled(12.5))
                        .foregroundStyle(Color.ink2)
                }
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color.surface.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.border2).frame(height: 1) }
    }
}

/// A plain message where a list would be.
struct EmptyMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.scaled(14))
            .foregroundStyle(Color.ink2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
    }
}

/// The capture prompt: the Siri phrase is the thing a seller will otherwise
/// never learn (FR16 §4.1).
struct SiriPrompt: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Say").foregroundStyle(Color.ink2)
            Text("“Hey Siri, take a 2Labs note”")
                .font(.scaled(15, .semibold))
                .foregroundStyle(Color.ink)
            Text("after a meeting and it files itself.").foregroundStyle(Color.ink2)
        }
        .font(.scaled(13))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
