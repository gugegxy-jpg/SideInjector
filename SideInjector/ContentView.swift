import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var log: LogStore
    @Environment(\.horizontalSizeClass) private var hSize
    @State private var presentingShare = false
    @ObservedObject private var pairing = PairingController.shared

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                    .ignoresSafeArea()
                // 外层 VStack 填充 ScrollView 宽度，内层列由其默认 .center 水平居中，
                // 避免 SwiftUI 默认 .topLeading 在 iPad 上把内容顶到左边、右侧留白（参照 SideInstaller）。
                ScrollView {
                    VStack(spacing: 0) {
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
                        .frame(maxWidth: hSize == .regular ? CGFloat(900) : .infinity)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity)
                    .animation(.smooth(duration: 0.35), value: model.busy)
                    .animation(.smooth(duration: 0.35), value: model.stageIndex)
                    .animation(.smooth(duration: 0.35), value: model.shareItem != nil)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .sheet(isPresented: $presentingShare) {
                if let url = model.shareItem {
                    ShareSheet(activityItems: [url])
                }
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
    }

    // MARK: - 进度

    private var progressCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(model.busy ? "处理中" : "已完成")
                        .font(.headline)
                    Spacer(minLength: 4)
                    Text("\(Int(progress * 100))%")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(.tertiarySystemFill))
                            .overlay(Capsule().strokeBorder(.white.opacity(0.05), lineWidth: 1))
                        Capsule()
                            .fill(Theme.brand)
                            .frame(width: max(12, geo.size.width * progress))
                            .animation(.smooth(duration: 0.45), value: progress)
                    }
                }
                .frame(height: 10)
                VStack(spacing: 0) {
                    ForEach(Array(model.stages.enumerated()), id: \.offset) { idx, title in
                        stepRow(idx: idx, title: title)
                        if idx < model.stages.count - 1 {
                            Divider().padding(.leading, 28)
                        }
                    }
                }
            }
        }
    }

    private func stepRow(idx: Int, title: String) -> some View {
        let done = idx < model.stageIndex
        let active = idx == model.stageIndex && model.busy
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : (active ? Theme.accent : Color(.secondarySystemBackground)))
                    .frame(width: 24, height: 24)
                Image(systemName: done ? "checkmark" : "circle")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(done || active ? .white : .secondary)
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(active ? .primary : (done ? .primary : .secondary))
                .animation(.smooth(duration: 0.3), value: active)
            Spacer()
        }
        .frame(minHeight: 28)
    }

    private var progress: Double {
        let count = Double(max(1, model.stages.count))
        guard model.stageIndex >= 0 else { return 0 }
        let idx = Double(model.stageIndex)
        return model.busy ? min((idx + 0.5) / count, 1) : 1
    }

    // MARK: - 主操作

    private var actionButton: some View {
        Button {
            model.run()
        } label: {
            HStack(spacing: 10) {
                if model.busy {
                    ProgressView().tint(.white)
                    Text("处理中…")
                } else {
                    Image(systemName: "syringe.fill")
                    Text("注入 + 签名 + 安装")
                }
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(model.busy)
    }

    // MARK: - 日志

    private var logCard: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("日志", systemImage: "doc.plaintext")
                ScrollView {
                    Text(log.text)
                        .font(.system(.caption, design: .monospaced))
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
