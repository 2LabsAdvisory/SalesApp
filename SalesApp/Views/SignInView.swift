import SwiftUI

/// Sign in (FR15 §6): the two methods, no password, and the line that says
/// the organization decides who gets in.
///
/// Both doors run through the same server rules as the web app (FR12). An
/// identity with no invite is refused with the server's own words, and no
/// account is created.
struct SignInView: View {
    @Environment(AppModel.self) private var app

    private enum Step: Equatable {
        case email
        case code(sentTo: String)
    }

    @State private var step: Step = .email
    @State private var email = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var microsoft = MicrosoftSignIn()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()

            HStack(spacing: 9) {
                BrandMark()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sales").font(.display(19, weight: .heavy)).foregroundStyle(Color.ink)
                    Text("by 2Labs").font(.scaled(11)).foregroundStyle(Color.ink2)
                }
            }
            .padding(.bottom, 34)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sales by 2Labs")

            Text("Sign in")
                .font(.display(22, weight: .heavy))
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)

            switch step {
            case .email: emailStep
            case .code(let sentTo): codeStep(sentTo)
            }

            if let error {
                Text(error)
                    .font(.scaled(13))
                    .foregroundStyle(Color.failure)
                    .padding(.top, 14)
                    .accessibilityAddTraits(.updatesFrequently)
            }

            Text("Your organization decides who gets in. If you’re not recognised, ask your admin for an invite.")
                .font(.scaled(12))
                .foregroundStyle(Color.ink3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)

            Spacer()
        }
        .padding(.horizontal, 28)
        .background(Color.surface.ignoresSafeArea())
        .disabled(isWorking)
    }

    // MARK: Steps

    private var emailStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("No password. Use your work Microsoft account, or we’ll email you a code.")
                .font(.scaled(14))
                .foregroundStyle(Color.ink2)
                .padding(.top, 8)
                .padding(.bottom, 22)

            Button {
                Task { await signInWithMicrosoft() }
            } label: {
                HStack(spacing: 8) {
                    MicrosoftLogo()
                    Text("Continue with Microsoft")
                }
            }
            .buttonStyle(SecondaryButtonStyle())

            HStack(spacing: 12) {
                Rectangle().fill(Color.border).frame(height: 1)
                Text("or").font(.scaled(12)).foregroundStyle(Color.ink3)
                Rectangle().fill(Color.border).frame(height: 1)
            }
            .padding(.vertical, 14)

            field("you@yourcompany.com", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit { Task { await sendCode() } }
                .padding(.bottom, 10)

            Button("Email me a code") { Task { await sendCode() } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!email.contains("@"))
        }
    }

    private func codeStep(_ sentTo: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("If \(sentTo) has an account, a 7-digit code is on its way. It works once, for a few minutes.")
                .font(.scaled(14))
                .foregroundStyle(Color.ink2)
                .padding(.top, 8)
                .padding(.bottom, 22)

            field("7-digit code", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused($focused)
                .onAppear { focused = true }
                .padding(.bottom, 10)

            Button("Sign in") { Task { await verify(sentTo) } }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 7)

            Button("Use a different email") {
                step = .email
                code = ""
                error = nil
            }
            .font(.scaled(13, .medium))
            .foregroundStyle(Color.ink2)
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(.scaled(14.5))
            .padding(13)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.border, lineWidth: 1))
    }

    // MARK: Actions

    private func signInWithMicrosoft() async {
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let bundle = try await microsoft.signIn(api: app.services.api, device: app.thisDevice)
            try await app.completeSignIn(with: bundle)
        } catch MicrosoftSignIn.Failure.cancelled {
            // They closed it. Nothing to say.
        } catch MicrosoftSignIn.Failure.refused(let message) {
            error = message
        } catch let failure as APIError {
            error = failure.message
        } catch {
            self.error = "Microsoft sign-in didn’t work. You can sign in with an email code instead."
        }
    }

    private func sendCode() async {
        let address = email.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { return }
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await app.services.api.requestCode(email: address)
            step = .code(sentTo: address)
        } catch let failure as APIError {
            error = failure.message
        } catch {
            self.error = APIError.invalidResponse.message
        }
    }

    private func verify(_ address: String) async {
        error = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let bundle = try await app.services.api.verifyCode(
                email: address, code: code.trimmingCharacters(in: .whitespaces), device: app.thisDevice)
            try await app.completeSignIn(with: bundle)
        } catch let failure as APIError {
            error = failure.message
        } catch {
            self.error = APIError.invalidResponse.message
        }
    }
}

private struct MicrosoftLogo: View {
    var body: some View {
        Grid(horizontalSpacing: 1.5, verticalSpacing: 1.5) {
            GridRow {
                Rectangle().fill(Color(hex: 0xF25022))
                Rectangle().fill(Color(hex: 0x7FBA00))
            }
            GridRow {
                Rectangle().fill(Color(hex: 0x00A4EF))
                Rectangle().fill(Color(hex: 0xFFB900))
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
