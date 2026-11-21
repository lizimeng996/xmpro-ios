// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

@MainActor
struct LoginView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case sms = "短信登录"
        case credential = "导入凭据"

        var id: String { rawValue }
    }

    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.dismiss) private var dismiss
    @Environment(\.xmPalette) private var palette

    @State private var mode: Mode
    @State private var mobile = ""
    @State private var smsCode = ""
    @State private var challengeId: String?
    @State private var showGeetest = false
    @State private var credentialInput = ""
    @State private var makePrimary = true
    @State private var busy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    init(initialMode: Mode = .sms) {
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(palette.accent.gradient)
                    Text("连接你的喜马拉雅账号")
                        .font(.title3.weight(.bold))
                    Text("凭据仅加密保存在本机 Keychain，不会上传至第三方")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Picker("登录方式", selection: $mode) {
                    ForEach(Mode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }

            if mode == .sms {
                smsSections
            } else {
                credentialSections
            }

            Section {
                Toggle(isOn: $makePrimary) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("设为主账号并立即切换")
                        Text("开启后立刻使用此账号同步书单与听时")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
        }
        .xmPageBackground()
        .xmToast($statusMessage)
        .disabled(busy)
        .overlay {
            if busy {
                ProgressView("正在处理…")
                    .padding(20)
                    .xmLiquidGlassRect(cornerRadius: 16)
            }
        }
        .navigationTitle("登录账号")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: mode) { _, _ in
            errorMessage = nil
        }
        .sheet(isPresented: $showGeetest) {
            NavigationStack {
                GeetestView(
                    captchaID: ProtocolConfig.captchaID,
                    onDismiss: { showGeetest = false },
                    onSuccess: { geetest in
                        showGeetest = false
                        Task { await sendSms(geetest: geetest) }
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showGeetest = false }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var smsSections: some View {
        Section("手机号短信验证") {
            TextField("请输入手机号", text: $mobile)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)

            Button {
                errorMessage = nil
                statusMessage = nil
                let trimmed = mobile.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    errorMessage = "请先输入手机号"
                    return
                }
                showGeetest = true
            } label: {
                Text(challengeId == nil ? "安全验证并发送验证码" : "重新验证并发送")
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(palette.accent)
            .fontWeight(.semibold)
        }

        if challengeId != nil {
            Section("短信验证码") {
                TextField("请输入短信验证码", text: $smsCode)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)

                Button {
                    Task { await verifyAndLogin() }
                } label: {
                    Text("验证并登录")
                        .frame(maxWidth: .infinity)
                }
                .xmProminentButton()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .disabled(smsCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var credentialSections: some View {
        Section {
            TextEditor(text: $credentialInput)
                .frame(minHeight: 140)
                .font(.footnote.monospaced())
        } header: {
            Text("Cookie 或账号 JSON")
        } footer: {
            Text("粘贴喜马拉雅极速版 Cookie 字符串或此前导出的账号 JSON。")
        }

        Section {
            Button {
                Task { await importCredential() }
            } label: {
                Text("解析并导入账号")
                    .frame(maxWidth: .infinity)
            }
            .xmProminentButton()
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .disabled(credentialInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sendSms(geetest: [String: String]) async {
        busy = true
        errorMessage = nil
        statusMessage = nil
        defer { busy = false }

        do {
            let trimmed = mobile.trimmingCharacters(in: .whitespacesAndNewlines)
            let device = await dependencies.installDevice.deviceId()
            let id = try await dependencies.loginService.sendSms(
                mobile: trimmed,
                geetest: geetest,
                device: device
            )
            challengeId = id
            statusMessage = "验证码已发送，请查收短信"
        } catch let error as XmlyError {
            errorMessage = error.message
        } catch {
            errorMessage = "发送短信验证码失败，请重试"
        }
    }

    private func verifyAndLogin() async {
        guard let challengeId else { return }
        guard let accountStore = dependencies.accountStore else {
            errorMessage = "本地账号存储不可用"
            return
        }
        busy = true
        errorMessage = nil
        statusMessage = nil
        defer { busy = false }

        do {
            let code = smsCode.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await dependencies.loginService.verifySms(
                challengeId: challengeId,
                code: code
            )
            let summary = try await accountStore.importCredentials(
                result.credentials,
                nickname: result.nickname,
                avatarUrl: result.avatarUrl,
                mobile: result.mobile,
                makePrimary: makePrimary
            )
            if makePrimary, let coordinator = dependencies.accountCoordinator {
                try? await coordinator.switchAccount(identity: summary.identity)
            } else {
                await dependencies.refreshAccountServices()
            }
            if let ledger = dependencies.usageLedger,
               let client = try? await dependencies.makeCurrentClient() {
                _ = try? await ledger.refreshQuota(identity: summary.identity, client: client)
            }
            statusMessage = "登录成功"
            dismiss()
        } catch let error as XmlyError {
            errorMessage = error.message
        } catch {
            errorMessage = "验证登录失败，请检查验证码后重试"
        }
    }

    private func importCredential() async {
        guard let accountStore = dependencies.accountStore else {
            errorMessage = "本地账号存储不可用"
            return
        }
        busy = true
        errorMessage = nil
        statusMessage = nil
        defer { busy = false }

        do {
            let raw = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let credentials = try Credentials.parse(raw)
            let summary = try await accountStore.importCredentials(
                credentials,
                makePrimary: makePrimary
            )
            if makePrimary, let coordinator = dependencies.accountCoordinator {
                try? await coordinator.switchAccount(identity: summary.identity)
            } else {
                await dependencies.refreshAccountServices()
            }
            statusMessage = "账号导入成功"
            dismiss()
        } catch let error as XmlyError {
            errorMessage = error.message
        } catch {
            errorMessage = "凭据格式无效，请粘贴完整的 Cookie 或 JSON"
        }
    }
}
