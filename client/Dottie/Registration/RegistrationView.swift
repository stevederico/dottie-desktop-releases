import SwiftUI
import AppKit

struct RegistrationView: View {
    @Environment(\.colorScheme) private var colorScheme
    weak var window: NSWindow?
    let onComplete: () -> Void

    @State private var step: Step = .name
    @State private var name: String = ""
    @State private var email: String = ""
    @FocusState private var focus: Field?

    private enum Step { case name, email }
    private enum Field { case name, email }

    private var canSubmitName: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSubmitEmail: Bool {
        RegistrationManager.isValidEmail(email)
    }

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Group {
                switch step {
                case .name:
                    nameStep
                case .email:
                    emailStep
                }
            }
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .move(edge: .trailing)),
                removal: .opacity.combined(with: .move(edge: .leading))
            ))

            Spacer(minLength: 0)
        }
        // Real window titlebar area under fullSizeContentView.
        .padding(.top, 28)
        .padding([.horizontal, .bottom], 40)
        .frame(width: 500, height: 460)
        .background(
            VisualEffectBlur(
                material: colorScheme == .dark ? .hudWindow : .popover,
                cornerRadius: 16
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .defaultFocus($focus, .name)
        .onAppear {
            DispatchQueue.main.async { focus = .name }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = .name }
        }
    }

    /// Lighter than controlBackground (reads as a black pit on the blur card).
    private var inputFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : Color.black.opacity(0.06)
    }

    private let inputCorner: CGFloat = 18

    @ViewBuilder
    private var nameStep: some View {
        VStack(spacing: 18) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 80, height: 80)
                    .accessibilityLabel("Dottie")
            }

            Text("Hi, I'm Dottie.")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)

            input(text: $name, placeholder: "What's your name?", field: .name, capitalizeFirst: true) {
                advanceToEmail()
            }

            Button(action: advanceToEmail) {
                Text("Continue").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmitName)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var emailStep: some View {
        VStack(spacing: 18) {
            Text("Nice to meet you, \(firstName).")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)

            input(text: $email, placeholder: "What's your email?", field: .email) {
                finish()
            }

            Button(action: finish) {
                Text("Finish").frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmitEmail)
            .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private func input(
        text: Binding<String>,
        placeholder: String,
        field: Field,
        capitalizeFirst: Bool = false,
        onCommit: @escaping () -> Void
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.system(size: 18))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: inputCorner, style: .continuous)
                    .fill(inputFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: inputCorner, style: .continuous)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 1)
            )
            .frame(maxWidth: 360)
            .focused($focus, equals: field)
            .onSubmit(onCommit)
            .onChange(of: text.wrappedValue) { _, newValue in
                guard capitalizeFirst, let first = newValue.first, first.isLowercase else { return }
                text.wrappedValue = first.uppercased() + newValue.dropFirst()
            }
    }

    private var firstName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }

    private func advanceToEmail() {
        guard canSubmitName else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            step = .email
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            focus = .email
        }
    }

    private func finish() {
        guard canSubmitEmail else { return }
        RegistrationManager.shared.submit(name: name, email: email)
        onComplete()
        window?.close()
    }
}
