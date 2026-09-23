import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var log: LogStore
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var presentingShare = false
    @ObservedObject private var pairing = PairingController.shared

    var body: some View {
        // 用 ZStack 让背景作为「兄弟层」铺满全屏（含安全区），内容层照常尊重安全区，
        // 避免把背景当 .background 时安全区延伸失效、灵动岛/Home 条区域露出系统黑底。
        ZStack(alignment: .top) {
            AppBackground()
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    header.cascadeItem(0)
                    certCard.cascadeItem(1)
                    inputCard.cascadeItem(2)
                    pairingCard
                    if model.busy || model.stageIndex >= 0 {
                        progressCard.transition(.cardAppear)
                    }
                    actionButton.cascadeItem(4)
                    if let _ = model.shareItem {
                        Button {
                            presentingShare = true
                        } label: {
                            Label("分享已签名 IPA", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(PrimaryButtonStyle(gradient: Theme.gradient(.green)))
                        .transition(.cardAppear)
                    }
                    logCard.cascadeItem(5)
                }
                .padding(20)
                // iPhone 全宽；iPad 限宽成居中列（参照 SideInstaller 全宽自适应，
                // 这里给 iPad 一个可读最大列宽，避免超宽拉伸）。
                .frame(maxWidth: hSize == .regular ? CGFloat(900) : .infinity,
                       maxHeight: .infinity, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarHidden(true)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .animation(.smooth(duration: 0.35), value: model.busy)
        .animation(.smooth(duration: 0.35), value: model.stageIndex)
        .animation(.smooth(duration: 0.35), value: model.outcome)
        .animation(.smooth(duration: 0.35), value: model.shareItem != nil)
        .sheet(isPresented: $presentingShare) {
            if let url = model.shareItem {
                ShareSheet(activityItems: [url])
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        BrandHeader(icon: "syringe.fill",
                    title: "SideInjector",
                    subtitle: UILook.isLiquidGlass ? "Liquid Glass · iOS 26+" : "毛玻璃 · iOS 17+",
                    animateIcon: model.busy) {
            EmptyView()
        }
    }

    // MARK: - 开发证书

    private var certCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("开发证书", systemImage: "folder.fill.badge.gear")
                FileRow(title: "P12 证书", url: $model.certP12)
                Divider()
                SecureField("P12 密码", text: $model.certPass)
                    .submitLabel(.done)
                    .textContentType(.password)
                    .fieldBackground()
                    .toolbar {
                        ToolbarItem(placement: .keyboard) {
                            Button("完成") { hideKeyboard() }
                        }
                    }
                Divider()
                FileRow(title: "描述文件 (mobileprovision)", url: $model.profile)
                Divider()
                FileRow(title: "配对文件 (iOS 18–26 需要)", url: $model.pairingFile)
            }
        }
    }

    // MARK: - 输入

    private var inputCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("输入", systemImage: "doc.badge.plus")
                FileRow(title: "IPA 文件", url: $model.ipa)
                Divider()
                FileRow(title: "要注入的 dylib", url: $model.dylib)
                Divider()
                TextField("注入后文件名", text: $model.dylibName)
                    .textFieldStyle(.plain)
                    .fieldBackground()
                Divider()
                TextField("Bundle ID（留空不改）", text: $model.bundleId)
                    .textFieldStyle(.plain)
                    .fieldBackground()
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                Divider()
                TextField("显示名称（留空不改）", text: $model.displayName)
                    .textFieldStyle(.plain)
                    .fieldBackground()
            }
        }
    }

    // MARK: - 设备配对

    private var pairingCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("设备配对（iOS 27+，无需 Mac）", systemImage: "link.badge.plus")
                // 进入配对卡片时即主动请求「本地网络」授权，确保开关尽早出现在 设置 中
                HStack(spacing: 10) {
                    Image(systemName: pairing.pairedDeviceName != nil ? "checkmark.circle.fill" : "link.circle")
                        .foregroundStyle(pairing.pairedDeviceName != nil ? .green : Theme.accent)
                    Text(pairing.status)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if pairing.isPairing {
                        Button("取消") { pairing.stopPairing() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("开始配对") { pairing.startPairing() }
                            .buttonStyle(.bordered)
                    }
                }
                if let pin = pairing.pin {
                    VStack(spacing: 6) {
                        Text("在设备上输入此配对码")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(pin)
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .tracking(6)
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.cardAppear)
                }
            }
        }
        .onAppear { PairingController.shared.requestLocalNetworkPermission() }
    }

    // MARK: - 进度

    private var progressCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(model.outcome == .done ? "已完成"
                         : (model.outcome == .paused ? "已暂停" : "进行中"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if model.outcome == .done {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    } else if model.outcome == .paused {
                        Image(systemName: "pause.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
                // 与 SideInstaller 一致：仅在安装过程中显示线性进度条，
                // 端点（0 / 1）不显示，因此不会有 0% 或 100% 的残留态。
                if model.progress > 0, model.progress < 1 {
                    ProgressView(value: model.progress)
                        .tint(Theme.accent2)
                }
                if model.outcome == .paused, let reason = model.pauseReason {
                    CalloutCard(tint: .orange) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(reason)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                model.resume()
                            } label: {
                                Label("继续", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(model.stages.enumerated()), id: \.offset) { idx, title in
                        stepRow(idx: idx, title: title)
                        if idx < model.stages.count - 1 {
                            Divider().padding(.leading, 26)
                        }
                    }
                }
            }
        }
        .transition(.cardAppear)
        .animation(.smooth(duration: 0.35), value: model.stageIndex)
        .animation(.smooth(duration: 0.35), value: model.outcome)
    }

    private func stepRow(idx: Int, title: String) -> some View {
        let done = idx < model.stageIndex || (model.outcome == .done)
        let working = idx == model.stageIndex && model.outcome == .running
        let pausedHere = idx == model.stageIndex && model.outcome == .paused
        let failedHere = idx == model.stageIndex && model.outcome == .failed

        let stateText = done ? "完成"
            : (failedHere ? "失败"
            : (working ? "进行中" : (pausedHere ? "已暂停" : "等待")))
        let stateColor: Color = done ? .green
            : (failedHere ? .red : (pausedHere ? Theme.accent : .secondary))

        return HStack(spacing: 8) {
            stepIcon(done: done, working: working, pausedHere: pausedHere, failedHere: failedHere)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(done || working || pausedHere ? .primary : .secondary)
            Spacer(minLength: 6)
            Text(stateText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(stateColor)
        }
        .frame(minHeight: 26)
    }

    /// 四态图标：待办=时钟 / 进行中=小转圈 / 完成=绿勾 / 失败=红叉（对齐 SideInstaller 风格）。
    @ViewBuilder
    private func stepIcon(done: Bool, working: Bool, pausedHere: Bool, failedHere: Bool) -> some View {
        if done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if failedHere {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else if working {
            ProgressView().controlSize(.small)
        } else if pausedHere {
            Image(systemName: "pause.circle.fill").foregroundStyle(Theme.accent)
        } else {
            Image(systemName: "clock").foregroundStyle(.tertiary)
        }
    }

    // MARK: - 主操作

    private var actionButton: some View {
        Button {
            if model.outcome == .paused {
                model.resume()
            } else {
                model.run()
            }
        } label: {
            HStack(spacing: 10) {
                if model.outcome == .running {
                    ProgressView().tint(.white)
                    Text(model.status).lineLimit(1)   // 按钮内实时显示当前阶段（同 SideInstaller）
                } else if model.outcome == .paused {
                    Image(systemName: "play.fill")
                    Text("继续")
                } else {
                    Image(systemName: "syringe.fill")
                        .contentTransition(.symbolEffect(.replace))
                    Text("注入 + 签名 + 安装")
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.outcome == .running)
    }

    // MARK: - 日志

    private var logCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    sectionTitle("日志", systemImage: "doc.plaintext")
                    Spacer(minLength: 8)
                    Button {
                        UIPasteboard.general.string = log.text
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(log.text.isEmpty)
                    Button {
                        log.clear()
                    } label: {
                        Label("清空", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(log.text.isEmpty)
                }
                ScrollView {
                    Text(log.text)
                        .font(.system(.caption, design: .monospaced))
                        // 长按可直接选择/复制任意片段
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 300)
            }
        }
    }

    // MARK: - 工具

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.brand)
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                         to: nil, from: nil, for: nil)
    }
}

/// 用系统「文件」App 选文件的行。
struct FileRow: View {
    let title: String
    @Binding var url: URL?

    var body: some View {
        Button {
            let picker = DocumentPicker { url = $0 }
            rootVC()?.present(picker, animated: true)
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(url?.lastPathComponent ?? "未选择")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    private func rootVC() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let key = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        return key?.windows.first(where: \.isKeyWindow)?.rootViewController
    }
}
