import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var log: LogStore

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                    .ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        header.cascadeItem(0)
                        certCard.cascadeItem(1)
                        inputCard.cascadeItem(2)
                        tunnelCard.cascadeItem(3)
                        if model.busy || model.stageIndex >= 0 {
                            progressCard.transition(.cardAppear)
                        }
                        actionButton.cascadeItem(4)
                        logCard.cascadeItem(5)
                    }
                    .padding(20)
                    .animation(.smooth(duration: 0.35), value: model.busy)
                    .animation(.smooth(duration: 0.35), value: model.stageIndex)
                    .animation(.smooth(duration: 0.35), value: model.tunnelStatus?.ok)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationBarHidden(true)
            .preferredColorScheme(.dark)
            .tint(Theme.accent)
            .onAppear { model.checkEnvironment() }
        }
    }

    // MARK: - 头部

    private var header: some View {
        BrandHeader(icon: "syringe.fill",
                    title: "SideInjector",
                    subtitle: UILook.isLiquidGlass ? "Liquid Glass · iOS 26+" : "毛玻璃 · iOS 17+",
                    animateIcon: model.busy) {
            statusPill
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
        }
    }

    private var statusPill: some View {
        let ok = model.tunnelStatus?.ok
        return StatusPill(
            text: ok == true ? "隧道已连通" : (ok == false ? "隧道未连接" : "检测中"),
            systemImage: ok == true ? "checkmark.shield.fill" : (ok == false ? "shield.slash.fill" : "shield"),
            color: ok == true ? .green : (ok == false ? .red : .secondary)
        )
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
            }
        }
    }

    // MARK: - 安装环境（本地回环隧道）

    private var tunnelCard: some View {
        let ok = model.tunnelStatus?.ok
        let tint: Color = ok == true ? .green : (ok == false ? .red : Theme.accent2)
        return CalloutCard(tint: tint) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: ok == true ? "checkmark.shield.fill"
                      : (ok == false ? "shield.slash.fill" : "shield.fill"))
                    .font(.title2)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(ok == true ? "本地回环隧道已连通"
                         : (ok == false ? "本地回环隧道未建立" : "正在检测安装环境…"))
                        .font(.subheadline.weight(.semibold))
                    if let s = model.tunnelStatus {
                        Text(s.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    model.checkEnvironment()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .background(Circle().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
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
