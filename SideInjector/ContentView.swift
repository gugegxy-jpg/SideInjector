import SwiftUI
import UniformTypeIdentifiers

// 首页 UI 与交互风格参照 FrizzleM/SideInstaller
//   —— https://github.com/FrizzleM/SideInstaller
//   许可：SideInstaller License（Copyright © 2026 FrizzleM）：
//   须署名 "SideInstaller by FrizzleM" 并标明修改；禁止商业使用；禁止再分发其官方构建 / IPA。
//   本文件为自有实现，仅布局与交互风格对齐（全宽自适应、四态步骤图标、
//   按钮内显示当前阶段、仅安装时显示进度条）。完整说明见 THIRD_PARTY_NOTICES.md。
struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var log: LogStore
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var presentingShare = false
    @State private var tab = 0
    @ObservedObject private var pairing = PairingController.shared
    @ObservedObject private var certs = CertStore.shared
    /// 环境自检（iOS 版本 / LocalDevVPN 状态 / 隧道端口探测）
    @State private var env = EnvSnapshot()
    @State private var envBusy = false

    var body: some View {
        // 背景作为「兄弟层」铺满全屏（含安全区）；内容层尊重安全区。
        ZStack(alignment: .top) {
            AppBackground()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Group {
                    if tab == 0 { homeTab } else { LibraryView() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomTabBar
            }
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
        // 键盘「完成」只在最外层挂一次，避免多处嵌套导致出现位置异常。
        .keyboardDoneButton()
        // 启动前校验/准备失败时弹窗说明原因（否则会「点了没反应」）。
        .alert("无法开始", isPresented: inputErrorShown) {
            Button("好", role: .cancel) { model.inputError = nil }
        } message: {
            Text(model.inputError ?? "")
        }
    }

    private var inputErrorShown: Binding<Bool> {
        Binding(get: { model.inputError != nil },
                set: { if !$0 { model.inputError = nil } })
    }

    // MARK: - 主页

    private var homeTab: some View {
        ScrollView {
            VStack(spacing: 18) {
                header.cascadeItem(0)
                certCard.cascadeItem(1)
                inputCard.cascadeItem(2)
                pairingCard
                envCard
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
            .padding(.bottom, 12)
            // iPhone 全宽；iPad 限宽成居中列（参照 SideInstaller 全宽自适应，
            // 这里给 iPad 一个可读最大列宽，避免超宽拉伸）。
            .frame(maxWidth: hSize == .regular ? CGFloat(900) : .infinity,
                   maxHeight: .infinity, alignment: .top)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)   // 不显示右侧滚动条
    }

    // MARK: - 底部页签

    private var bottomTabBar: some View {
        HStack(spacing: 0) {
            tabButton(0, "主页", "house.fill")
            tabButton(1, "库", "books.vertical.fill")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        // iOS 26+ 用系统 Liquid Glass 悬浮胶囊；旧系统退回毛玻璃胶囊。
        .siGlassBar()
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func tabButton(_ idx: Int, _ title: String, _ icon: String) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { tab = idx }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(tab == idx ? Theme.accent : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                sectionTitle("开发证书（选择「库」中已保存的证书）", systemImage: "folder.fill.badge.gear")
                if certs.certs.isEmpty {
                    Text("还没有保存的证书：请到「库」页签添加并保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("证书", selection: $model.selectedCertID) {
                        Text("请选择").tag(UUID?.none)
                        ForEach(certs.certs) { c in
                            Text(c.name).tag(Optional(c.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accent)
                    if let cert = model.selectedCert {
                        Text("描述文件：\(CertStore.shared.provURL(for: cert).lastPathComponent)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - 输入

    private var inputCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("输入", systemImage: "doc.badge.plus")
                // IPA 改为「导入一次即入库，之后像选证书一样下拉选择」。
                HStack(spacing: 10) {
                    Text("IPA 文件").foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if model.savedIPAs.isEmpty {
                        Text("未选择（请先导入）")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Picker("", selection: $model.ipa) {
                            Text("请选择").tag(URL?.none)
                            ForEach(model.savedIPAs, id: \.self) { u in
                                Text(Model.displayName(for: u)).tag(Optional(u))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .lineLimit(1)
                    }
                    Button {
                        let picker = DocumentPicker(types: [UTType(filenameExtension: "ipa") ?? .data, .data]) { urls in
                            model.importIPA(urls.first)
                        }
                        topRootVC()?.present(picker, animated: true)
                    } label: {
                        Label("导入", systemImage: "plus.circle")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                .onAppear { model.refreshSavedIPAs() }
                Divider()
                Button {
                    let picker = DocumentPicker(types: [UTType(filenameExtension: "dylib") ?? .data, .data],
                                                allowsMultiple: true) { urls in
                        model.importDylibs(urls)
                    }
                    topRootVC()?.present(picker, animated: true)
                } label: {
                    HStack {
                        Text("要注入的 dylib（可多选）").foregroundStyle(.primary)
                        Spacer()
                        Text(model.dylibs.isEmpty ? "未选择" : "\(model.dylibs.count) 个")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                if !model.dylibs.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(model.dylibs, id: \.self) { u in
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox").foregroundStyle(Theme.brand)
                                Text(Model.displayName(for: u))
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Button {
                                    model.dylibs.removeAll { $0 == u }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            }
                            .frame(minHeight: 32)
                        }
                    }
                }
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
                Divider()
                FileRow(title: "配对文件 (iOS 18–26 需要)", url: $model.pairingFile)
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

    // MARK: - 环境自检

    private var envCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    sectionTitle("环境自检", systemImage: "stethoscope")
                    Spacer(minLength: 8)
                    Button {
                        Task { await refreshEnv(logIt: true) }
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(envBusy)
                }
                envRow("iOS 版本", "\(env.osVersion)（\(env.osBuild)）")
                envRow("配对能力", env.selfPairCapable
                       ? "iOS 27+ · 支持设备端自配对（无需配对文件）"
                       : "iOS 18–26 · 需要 PC 生成的配对文件")
                envRow("LocalDevVPN", env.vpnUp
                       ? "已连接 · \(env.vpnDetail)"
                       : "未连接 · \(env.vpnDetail)")
                if !env.portLines.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("隧道端口探测").font(.caption).foregroundStyle(.secondary)
                        ForEach(env.portLines, id: \.self) { line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
        .onAppear {
            if env.osVersion == "?" { Task { await refreshEnv(logIt: false) } }
        }
    }

    private func envRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 采集环境信息（iOS 版本 / LocalDevVPN / 隧道端口）；手动刷新时同时写日志，便于复制发我。
    private func refreshEnv(logIt: Bool) async {
        await MainActor.run { envBusy = true }
        var snap = EnvProbe.snapshot()
        snap.portLines = await InstallEngine.shared.probePorts()
        await MainActor.run {
            env = snap
            envBusy = false
        }
        if logIt {
            LogStore.shared.append("环境自检：iOS \(snap.osVersion)（\(snap.osBuild)）"
                                   + (snap.selfPairCapable ? " · 支持设备端自配对" : " · 需配对文件"))
            LogStore.shared.append("环境自检：LocalDevVPN \(snap.vpnUp ? "已连接" : "未连接") · \(snap.vpnDetail)")
            for line in snap.portLines { LogStore.shared.append("tunnel-probe: \(line)") }
        }
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
                            HStack(spacing: 10) {
                                Button {
                                    model.resume()
                                } label: {
                                    Label("继续", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                Button(role: .destructive) {
                                    model.cancel()
                                } label: {
                                    Label("取消", systemImage: "xmark")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                } else if model.outcome == .running {
                    // 运行中也能取消；同步 FFI 会在当前步骤返回后停下。
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            model.cancel()
                        } label: {
                            Label("取消", systemImage: "xmark")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(model.displayStages.enumerated()), id: \.offset) { idx, title in
                        stepRow(idx: idx, title: title)
                        if idx < model.displayStages.count - 1 {
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
                .scrollIndicators(.hidden)
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
            let picker = DocumentPicker { url = $0.first }
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
