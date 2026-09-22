import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var log: LogStore
    @State private var showLogs = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header

                    envCard

                    sectionCard(title: "开发证书") {
                        FileRow(title: "P12 证书", url: $model.certP12)
                        Divider()
                        SecureField("P12 密码", text: $model.certPass)
                        Divider()
                        FileRow(title: "描述文件 (mobileprovision)", url: $model.profile)
                        Divider()
                        TextField("Team ID", text: $model.teamId)
                        Divider()
                        FileRow(title: "配对文件 (iOS18–26 需要)", url: $model.pairingFile)
                    }

                    sectionCard(title: "输入") {
                        FileRow(title: "IPA 文件", url: $model.ipa)
                        Divider()
                        FileRow(title: "要注入的 dylib", url: $model.dylib)
                        Divider()
                        TextField("注入后文件名", text: $model.dylibName)
                    }

                    actionButton

                    statusCard

                    if showLogs {
                        sectionCard(title: "日志") {
                            ScrollView {
                                Text(log.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 200, maxHeight: 320)
                        }
                        .animation(.easeInOut, value: showLogs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .siBackdrop()
            .onAppear { model.checkEnvironment() }
            .navigationTitle("SideInjector")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { showLogs.toggle() }
                    } label: {
                        Image(systemName: showLogs ? "doc.plaintext.fill" : "doc.plaintext")
                    }
                }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "syringe.fill")
                .font(.system(size: 42))
                .foregroundStyle(.linearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
            Text("SideInjector")
                .font(.title.bold())
                .foregroundStyle(.primary)
            Text(UILook.isLiquidGlass ? "Liquid Glass · iOS 26+" : "毛玻璃 · iOS < 26")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    // MARK: - 卡片

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "folder.fill.badge.gear")
                .font(.headline)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .siGlass()
        .frame(maxWidth: .infinity)
    }

    // MARK: - 主操作按钮

    private var actionButton: some View {
        Button {
            model.run()
        } label: {
            HStack(spacing: 12) {
                if model.busy {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "bolt.fill")
                }
                Text(model.busy ? "处理中…" : "注入 + 签名 + 安装")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
        }
        .siGlassButton(tint: model.busy ? .gray : .blue)
        .frame(maxWidth: .infinity)
        .disabled(model.busy)
    }

    // MARK: - 状态 / 进度

    /// 安装环境检测卡片：本地回环隧道是否「绿」。
    private var envCard: some View {
        sectionCard(title: "安装环境") {
            HStack(spacing: 12) {
                Circle()
                    .fill(model.tunnelStatus?.ok == true ? Color.green
                          : (model.tunnelStatus?.ok == false ? Color.red : Color.gray))
                    .frame(width: 12, height: 12)
                    .shadow(color: (model.tunnelStatus?.ok == true ? Color.green
                                    : (model.tunnelStatus?.ok == false ? Color.red : Color.clear))
                                    .opacity(0.6), radius: 4)
                if let s = model.tunnelStatus {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.message)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if let dc = s.deviceClass {
                            Text("lockdownd: \(dc)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    ProgressView().tint(.secondary)
                    Text("检测中…").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.checkEnvironment()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: model.busy ? "hourglass.circle" : "info.circle")
                Text(model.status)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
            if model.stageIndex >= 0 || model.busy {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.stages.enumerated()), id: \.offset) { idx, title in
                        HStack(spacing: 10) {
                            Image(systemName: idx < model.stageIndex ? "checkmark.circle.fill"
                                          : (idx == model.stageIndex && model.busy ? "circle.fill" : "circle"))
                                .foregroundStyle(idx < model.stageIndex ? .green
                                                 : (idx == model.stageIndex ? .blue : .secondary))
                            Text(title)
                                .font(.footnote)
                                .foregroundStyle(idx == model.stageIndex ? .primary : .secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .siGlass()
        .frame(maxWidth: .infinity)
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
    }

    private func rootVC() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let key = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        return key?.windows.first(where: \.isKeyWindow)?.rootViewController
    }
}
