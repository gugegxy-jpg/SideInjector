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
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var presentingShare = false
    @State private var tab = 0
    @ObservedObject private var pairing = PairingController.shared
    @ObservedObject private var certs = CertStore.shared
    /// 网络 / 隧道状态（**实时**）：顶部标题栏显示 iOS 版本 · LocalDevVPN · WiFi。
    @ObservedObject private var net = NetworkMonitor.shared
    /// 环境自检（iOS 版本 / LocalDevVPN 状态 / 隧道端口探测）
    @State private var env = EnvSnapshot()
    @State private var envBusy = false

    var body: some View {
        // 背景作为「兄弟层」铺满全屏（含安全区）。
        //
        // 底部 dock 为什么不再自绘：自绘时它必须放在内容区的 VStack 里，下方露出的是
        // OLED 黑底，看起来就是「矩形深色底板 + 一层胶囊玻璃」，而且拿不到系统的浮动 /
        // 收起行为。iOS 18+ 改用系统 `TabView`：iOS 26+ 会由系统渲染成**浮动 Liquid Glass**
        // 页签栏（向下滚动还会收起），内容能从它下面穿过。
        //
        // 注意 `Tab` / `TabView(selection:content:)` 是 **iOS 18+** API，
        // 而本工程部署目标是 iOS 17.0 —— 所以必须走 `#available` 分支，
        // iOS 17 保留自绘 dock 作为退让（`legacyTabLayout`）。
        ZStack {
            AppBackground()
                .ignoresSafeArea()
            if #available(iOS 18.0, *) {
                systemTabView
            } else {
                legacyTabLayout
            }
        }
        // 状态栏蒙版：内容滚动到状态栏下面时，系统时钟/电量不再和 App 文字压字。
        // 材质跟系统版本走（iOS 26+ Liquid Glass / 旧系统毛玻璃），固定在屏幕顶部、不吃点击。
        .siStatusBarMask()
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
                        Label(model.skipSign ? "导出未签名 IPA（保存到「文件」）"
                                             : "分享 / 导出已签名 IPA",
                              systemImage: "square.and.arrow.up")
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

    // MARK: - 底部页签栏

    /// iOS 18+：系统页签栏。
    /// iOS 26+ 下系统会自动渲染成**浮动 Liquid Glass**（并在向下滚动时收起，见 `siFloatingTabBar()`），
    /// 内容从它下面穿过 —— 不会再出现「深色底板 + 胶囊玻璃」那种观感。
    @available(iOS 18.0, *)
    private var systemTabView: some View {
        TabView(selection: $tab) {
            Tab("主页", systemImage: "house.fill", value: 0) { homeTab }
            Tab("库", systemImage: "books.vertical.fill", value: 1) { LibraryView() }
            // 设置放最后（底部栏「库」右侧）。
            Tab("设置", systemImage: "gearshape.fill", value: 2) { SettingsView() }
        }
        .siFloatingTabBar()
    }

    /// iOS 17（本工程最低版本）没有 `Tab` API，沿用自绘 dock 退让。
    private var legacyTabLayout: some View {
        VStack(spacing: 0) {
            Group {
                if tab == 0 {
                    homeTab
                } else if tab == 1 {
                    LibraryView()
                } else {
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            legacyTabBar
        }
    }

    private var legacyTabBar: some View {
        HStack(spacing: 0) {
            legacyTabButton(0, "主页", "house.fill")
            legacyTabButton(1, "库", "books.vertical.fill")
            legacyTabButton(2, "设置", "gearshape.fill")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .siGlassBar()
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func legacyTabButton(_ idx: Int, _ title: String, _ icon: String) -> some View {
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
        // 副标题原先是「Liquid Glass · iOS 26+」这类**外观**描述（对使用者没有信息量）。
        // 现在放真正需要一眼看到的三项：iOS 版本 · LocalDevVPN 状态 · WiFi 状态。
        // 实时刷新（见 NetworkMonitor）：开关 WiFi / 连接或断开 VPN 后这里会立刻变化。
        BrandHeader(icon: "syringe.fill",
                    title: "SideInjector",
                    subtitle: net.headline,
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
                Divider()
                Toggle(isOn: $model.skipSign) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("跳过签名（只注入后导出）")
                        Text("产出未签名 IPA 供导出/自行签名；该模式不会触发设备配对与安装。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(Theme.accent)
            }
        }
    }

    // MARK: - 输入

    private var inputCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("输入", systemImage: "doc.badge.plus")
                // IPA：导入后入库，点条目选中、垃圾桶删除。
                // 这里不用 Picker(.menu)：它的标签不参与截断，文件名一长就会把按钮挤走/换行超框。
                HStack(spacing: 10) {
                    Text("IPA 文件").foregroundStyle(.primary)
                    Spacer(minLength: 8)
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

                if model.savedIPAs.isEmpty {
                    Text("还没有导入 IPA：点「导入」选择文件（会保存在 App 内，之后可随时切换或删除）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.savedIPAs, id: \.self) { u in
                            HStack(spacing: 8) {
                                Image(systemName: model.ipa == u ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(model.ipa == u ? Theme.accent : Color.secondary)
                                Text(Model.displayName(for: u))
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                Button {
                                    model.removeSavedIPA(u)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.ipa = u }
                            .frame(minHeight: 32)
                        }
                    }
                }

                Divider()
                Button {
                    let picker = DocumentPicker(types: [UTType(filenameExtension: "dylib") ?? .data, .data],
                                                allowsMultiple: true) { urls in
                        model.importDylibs(urls)
                    }
                    topRootVC()?.present(picker, animated: true)
                } label: {
                    HStack(spacing: 8) {
                        Text("要注入的 dylib（可多选）").foregroundStyle(.primary)
                        Spacer(minLength: 8)
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
                                    .truncationMode(.middle)
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
                TextField(model.bundleIdPlaceholder, text: $model.bundleId)
                    .textFieldStyle(.plain)
                    .fieldBackground()
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                if !model.ipaBundleId.isEmpty {
                    Text("这个 IPA 当前的 Bundle ID 是 \(model.ipaBundleId)，留空即不改")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Divider()
                TextField(model.displayNamePlaceholder, text: $model.displayName)
                    .textFieldStyle(.plain)
                    .fieldBackground()
                if !model.ipaDisplayName.isEmpty {
                    Text("当前的显示名是 \(model.ipaDisplayName)，留空即不改")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !model.ipaExtensionMismatch.isEmpty {
                    Text("⚠️ 这个 IPA 自带错配：\(model.ipaExtensionMismatch.count) 个扩展的 Bundle ID 与主 App 前缀不符，原样签名也装不上")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Toggle(isOn: $model.syncExtensionIDs) {
                    Text("同步嵌套扩展 Bundle ID（修复第三方改包，仅勾选时执行）")
                        .font(.caption)
                }
                .disabled(model.busy)
                Divider()
                FileRow(title: "配对文件 (经典通路/手动安装需要)", url: $model.pairingFile)
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
        // 离开配对卡片就取消那次「授权探测」的 Bonjour 浏览 ——
        // 它只为触发系统的本地网络授权弹窗，常驻只会白白 mDNS 浏览（费电）。
        .onDisappear { PairingController.shared.cancelPermissionProbe() }
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
                // 逐条端口探测结果不再铺在界面上（3 个候选地址通常 1 个可用、2 个超时，
                // 一列红叉很扎眼）。这里只给一句结论；逐条明细写进后台日志（用日志卡片的「复制」取）。
                let okPorts = env.portLines.filter { $0.contains("可连接") || $0.contains("收到") }
                envRow("隧道端口", env.portLines.isEmpty
                       ? "未检测"
                       : (okPorts.isEmpty
                          ? "49152 无可用出口 · 请确认 LocalDevVPN 已连接"
                          : "49152 可用（\(okPorts.count) 个地址）"))
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
            // 逐条端口探测只进后台日志（界面上只显示一句结论）。
            for line in snap.portLines { LogStore.shared.appendDetail("tunnel-probe: \(line)") }
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
                    Text(model.skipSign ? "注入 + 打包（不签名）" : "注入 + 签名 + 安装")
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.outcome == .running)
    }

    // MARK: - 日志

    /// 日志卡片（实现见 `LogCard`：它单独观察 `LogStore`，只重绘自己；
    /// 界面只渲染末尾若干行，避免签名时上万行日志把首页一起拖卡）。
    private var logCard: some View { LogCard() }

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
