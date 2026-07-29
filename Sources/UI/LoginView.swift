import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var accountsStore: AccountsStore
    @EnvironmentObject private var settings: SettingsStore

    @State private var token = ""
    @State private var hostname = "github.com"
    @State private var clientID = ""
    @State private var publicReposOnly = false
    @State private var deviceCode: DeviceFlow.CodeResponse?
    @State private var isBusy = false
    @State private var errorMessage: String?
    @State private var deviceFlowTask: Task<Void, Never>?

    /// Strips scheme/path so pasting "https://github.com/" still works.
    private var normalizedHostname: String {
        var host = hostname.trimmingCharacters(in: .whitespaces).lowercased()
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) {
            host = String(host.dropFirst(prefix.count))
        }
        return host.split(separator: "/").first.map(String.init) ?? host
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "bell.badge")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Sign in to GitHub")
                .font(.title2.bold())

            if let deviceCode {
                deviceFlowPending(deviceCode)
            } else {
                loginForm
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(24)
    }

    private var loginForm: some View {
        VStack(spacing: 12) {
            TextField("Hostname (github.com)", text: $hostname)
                .textFieldStyle(.roundedBorder)
            SecureField("Personal Access Token", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit { loginWithPAT() }
            Button("Sign in with Token") { loginWithPAT() }
                .keyboardShortcut(.defaultAction)
                .disabled(token.isEmpty || isBusy)

            Divider().padding(.vertical, 4)

            TextField("OAuth Client ID (for Device Flow)", text: $clientID)
                .textFieldStyle(.roundedBorder)
            Toggle("Public repositories only", isOn: $publicReposOnly)
                .toggleStyle(.checkbox)
                .font(.callout)
            Button("Sign in with Browser (Device Flow)") { startDeviceFlow() }
                .disabled(clientID.isEmpty || isBusy)
        }
        .frame(maxWidth: 300)
        .onAppear { clientID = settings.oauthClientID }
    }

    private func deviceFlowPending(_ code: DeviceFlow.CodeResponse) -> some View {
        VStack(spacing: 12) {
            Text("Enter this code on GitHub:")
            Text(code.userCode)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .textSelection(.enabled)
            Button("Open github.com/login/device") {
                NSWorkspace.shared.open(URL(string: code.verificationUri)!)
            }
            ProgressView()
                .controlSize(.small)
            Button("Cancel") {
                deviceFlowTask?.cancel()
                deviceCode = nil
                isBusy = false
            }
        }
    }

    private func loginWithPAT() {
        guard !token.isEmpty else { return }
        isBusy = true
        errorMessage = nil
        Task {
            do {
                try await accountsStore.addAccount(
                    token: token,
                    hostname: normalizedHostname,
                    method: .personalAccessToken
                )
                token = ""
            } catch {
                errorMessage = "Failed to validate provided token against \(normalizedHostname)"
            }
            isBusy = false
        }
    }

    private func startDeviceFlow() {
        isBusy = true
        errorMessage = nil
        settings.oauthClientID = clientID
        let host = normalizedHostname
        deviceFlowTask = Task {
            do {
                let code = try await DeviceFlow.requestCode(
                    clientID: clientID,
                    scopes: publicReposOnly ? DeviceFlow.alternateScopes : DeviceFlow.recommendedScopes,
                    hostname: host
                )
                deviceCode = code
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(URL(string: code.verificationUri)!)
                let accessToken = try await DeviceFlow.pollForToken(
                    clientID: clientID,
                    code: code,
                    hostname: host
                )
                try await accountsStore.addAccount(
                    token: accessToken,
                    hostname: host,
                    method: .oauthDeviceFlow
                )
            } catch is CancellationError {
                // user cancelled
            } catch {
                errorMessage = error.localizedDescription
            }
            deviceCode = nil
            isBusy = false
        }
    }
}
