import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
struct WorkshopSteamLoginView: View {
    private enum Method: String, CaseIterable {
        case qr, password
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var steam = SteamServiceManager.shared
    @State private var method: Method = .qr
    @State private var username = ""
    @State private var password = ""
    @State private var code = ""
    @State private var preferCode = false
    @State private var loginError: String?
    @State private var submittedCode = false
    @State private var startingPasswordLogin = false

    private var isAuthenticating: Bool {
        switch steam.loginState {
        case .loggingIn, .waitingForQR, .waitingForMobileConfirmation, .waitingForCode:
            return true
        default:
            return startingPasswordLogin
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Label(t("登录 Steam"), systemImage: "lock.shield")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)

                    Text(t("登录后即可同步 Wallpaper Engine 订阅并下载壁纸。Mivori 使用 macOS 钥匙串保存会话。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(t("登录方式"), selection: $method) {
                        Text(t("手机扫码")).tag(Method.qr)
                        Text(t("账号密码")).tag(Method.password)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("mivori.steam.method")
                    .disabled(isAuthenticating)

                    if method == .qr {
                        qrForm
                    } else {
                        passwordForm
                    }

                    if let message = statusError {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(23)
            }
            .frame(maxHeight: 456)

            Divider()
            HStack {
                Spacer()
                if isAuthenticating {
                    Button(t("取消登录")) { cancel() }
                        .accessibilityIdentifier("mivori.steam.cancel")
                }
                Button(steam.isLoggedIn ? t("完成") : t("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 455)
        .accessibilityIdentifier("mivori.steam.loginSheet")
        .onChange(of: method) { _, _ in
            loginError = nil
            code = ""
            password = ""
        }
        .onChange(of: steam.loginState) { _, _ in submittedCode = false }
        .onChange(of: steam.isLoggedIn) { _, connected in
            if connected, case .success = steam.loginState { dismiss() }
        }
        .onDisappear {
            if isAuthenticating, !steam.isLoggedIn { cancel() }
            password = ""
            code = ""
        }
    }

    @ViewBuilder
    private var qrForm: some View {
        switch steam.loginState {
        case .waitingForQR(let challenge):
            VStack(spacing: 12) {
                if let image = Self.qrImage(for: challenge) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 174, height: 174)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(t("Steam 登录二维码"))
                        .accessibilityIdentifier("mivori.steam.qr")
                } else {
                    Text(t("暂时无法显示二维码，请刷新后重试。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text(t("用 Steam 手机应用扫描二维码，再确认登录。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(t("刷新二维码")) { steam.loginWithQR() }
            }
            .frame(maxWidth: .infinity)
        case .loggingIn:
            progress(t("正在连接 Steam…"))
        default:
            Button {
                loginError = nil
                steam.loginWithQR()
            } label: {
                Label(t("生成 Steam 登录二维码"), systemImage: "qrcode")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("mivori.steam.beginQR")
            .disabled(isAuthenticating || steam.isLoggedIn)
        }
    }

    @ViewBuilder
    private var passwordForm: some View {
        switch steam.loginState {
        case .waitingForCode(let prompt):
            Text(prompt.title).font(.callout.weight(.semibold))
            TextField(t("Steam Guard 验证码"), text: $code)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(prompt.isEmail ? "mivori.steam.emailCode" : "mivori.steam.mobileCode")
                .disabled(submittedCode)
            Button(t("提交验证码")) {
                loginError = nil
                submittedCode = true
                steam.submitGuardCode(code)
                code = ""
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submittedCode)
            if submittedCode { progress(t("正在验证 Steam Guard 代码…")) }
        case .waitingForMobileConfirmation:
            progress(t("请在 Steam 手机应用中确认登录"))
            Text(t("如需手输验证码，请取消后选择「使用验证码登录」。"))
                .font(.callout)
                .foregroundStyle(.secondary)
        case .loggingIn:
            progress(t("正在验证账号并连接 Steam…"))
        default:
            TextField(t("Steam 账号名称"), text: $username)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mivori.steam.username")
            SecureField(t("Steam 密码"), text: $password)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mivori.steam.password")
            Toggle(t("使用验证码登录"), isOn: $preferCode)
                .accessibilityIdentifier("mivori.steam.preferCode")
            Button(t("登录")) { submitPassword() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || password.isEmpty || isAuthenticating || steam.isLoggedIn)
        }
    }

    private var statusError: String? {
        if let loginError { return loginError }
        if case .failed(let message) = steam.loginState { return message }
        return nil
    }

    private func progress(_ title: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(title).font(.callout)
        }
    }

    private func submitPassword() {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = password
        let preferCode = preferCode
        password = ""
        loginError = nil
        startingPasswordLogin = true
        Task {
            defer { startingPasswordLogin = false }
            do {
                try await steam.login(username: user, password: secret, preferGuardCode: preferCode)
                dismiss()
            } catch SteamServiceError.cancelled {
                return
            } catch {
                loginError = error.localizedDescription
            }
        }
    }

    private func cancel() {
        steam.cancelLogin()
        password = ""
        code = ""
        submittedCode = false
        loginError = nil
    }

    private static func qrImage(for challenge: String) -> NSImage? {
        guard let url = URL(string: challenge), url.scheme == "https", url.host?.lowercased() == "s.team" else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(challenge.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage else { return nil }
        let bitmap = NSCIImageRep(ciImage: image)
        let result = NSImage(size: bitmap.size)
        result.addRepresentation(bitmap)
        return result
    }
}
