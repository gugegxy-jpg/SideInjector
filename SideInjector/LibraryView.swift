import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 「库」页签：证书库（添加 / 保存 / 删除） + 已签名 IPA 列表（点击直接安装）。
struct LibraryView: View {
    @ObservedObject private var certs = CertStore.shared
    @ObservedObject private var ipas = IPALibrary.shared
    @ObservedObject private var model = Model.shared

    // 新增证书表单
    @State private var newName = ""
    @State private var newP12: URL?
    @State private var newProv: URL?
    @State private var newPass = ""
    @State private var savedTip: String?
    @State private var errorTip: String?
    @State private var editingCert: SavedCert?
    @State private var pendingDeleteCert: SavedCert?
    @State private var pendingDeleteIPA: SignedIPA?
    /// 导入已签名 IPA 的结果提示。
    @State private var ipaTip: String?
    /// 当前缓存占用（打开页面 / 刷新 / 清理后重新统计）。
    @State private var cacheBytes: Int64 = 0
    /// 缓存区提示（刷新结果 / 释放大小）。
    @State private var cacheTip: String?
    @State private var confirmCleanCache = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                certSection
                ipaSection
                storageSection
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)   // 一滚动就收起键盘
        .onAppear { cacheBytes = Storage.cacheBytes() }
        .sheet(item: $editingCert) { CertEditView(cert: $0) }
        .confirmationDialog("删除该证书？", isPresented: certDeleteShown, presenting: pendingDeleteCert) { c in
            Button("删除", role: .destructive) {
                if model.selectedCertID == c.id { model.clearSelectedCert() }
                certs.remove(c)
                pendingDeleteCert = nil
            }
            Button("取消", role: .cancel) { pendingDeleteCert = nil }
        } message: { c in
            Text("将删除「\(c.name)」及其保存的证书文件，不可恢复。")
        }
        .confirmationDialog("删除该已签名 IPA？", isPresented: ipaDeleteShown, presenting: pendingDeleteIPA) { it in
            Button("删除", role: .destructive) {
                ipas.remove(it)
                pendingDeleteIPA = nil
            }
            Button("取消", role: .cancel) { pendingDeleteIPA = nil }
        } message: { it in
            Text("将删除「\(it.name)」，不可恢复。")
        }
        .confirmationDialog("清理缓存？", isPresented: $confirmCleanCache) {
            Button("清理", role: .destructive) {
                let freed = Storage.cleanCache()
                cacheBytes = Storage.cacheBytes()
                cacheTip = freed > 0 ? "已释放 \(Storage.human(freed))" : "没有可清理的缓存"
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只清理临时文件与 Caches。证书、已签名 IPA 库、导入的 IPA / dylib、配对文件与日志都会保留。")
        }
    }

    private var certDeleteShown: Binding<Bool> {
        Binding(get: { pendingDeleteCert != nil }, set: { if !$0 { pendingDeleteCert = nil } })
    }
    private var ipaDeleteShown: Binding<Bool> {
        Binding(get: { pendingDeleteIPA != nil }, set: { if !$0 { pendingDeleteIPA = nil } })
    }

    // MARK: - 存储与缓存

    private var storageSection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("存储与缓存").font(.headline)
                } icon: {
                    Image(systemName: "internaldrive.fill").foregroundStyle(Theme.brand)
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("缓存（临时文件）").font(.subheadline.weight(.semibold))
                        Text("解包 / 注入 / 签名 / 打包过程中的临时目录。清理**不会**影响已导入的 IPA、dylib、证书、签名产物与日志。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(Storage.human(cacheBytes))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button {
                        confirmCleanCache = true
                    } label: {
                        Label("清理缓存", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(cacheBytes == 0)

                    Button {
                        cacheBytes = Storage.cacheBytes()
                        cacheTip = "当前缓存 \(Storage.human(cacheBytes))"
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)

                    Spacer(minLength: 0)
                }

                if let cacheTip {
                    Text(cacheTip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text("日志文件：\(LogStore.shared.fileSizeText) · 首页「日志」卡片上可查看 / 导出 / 清空")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 证书库

    private var certSection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("证书库").font(.headline)
                } icon: {
                    Image(systemName: "key.fill").foregroundStyle(Theme.brand)
                }

                if certs.certs.isEmpty {
                    Text("还没有证书。填好下面的信息，点「保存到证书库」即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(certs.certs) { c in
                            certRow(c)
                            if c.id != certs.certs.last?.id { Divider() }
                        }
                    }
                }

                Divider()
                Text("添加证书")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("名称（如：我的开发证书）", text: $newName)
                    .textFieldStyle(.plain)
                    .fieldBackground()
                    .submitLabel(.done)
                    .onSubmit { dismissKeyboardNow() }
                FilePickRow(title: "P12 证书", url: $newP12,
                            types: [UTType(filenameExtension: "p12") ?? .data, .data])
                SecureField("P12 密码", text: $newPass)
                    .textFieldStyle(.plain)
                    .fieldBackground()
                    .submitLabel(.done)
                    .onSubmit { dismissKeyboardNow() }
                FilePickRow(title: "描述文件", url: $newProv,
                            types: [UTType(filenameExtension: "mobileprovision") ?? .data, .data])

                Button {
                    saveCert()
                } label: {
                    Label("保存到证书库", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle(gradient: Theme.gradient(.green)))
                .disabled(newP12 == nil || newProv == nil)

                if let savedTip {
                    Text("已保存：\(savedTip)").font(.caption).foregroundStyle(.green)
                }
                if let errorTip {
                    Text(errorTip).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func certRow(_ c: SavedCert) -> some View {
        HStack(spacing: 10) {
            Image(systemName: model.selectedCertID == c.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(model.selectedCertID == c.id ? Theme.accent : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.subheadline.weight(.semibold))
                Text(CertStore.shared.provURL(for: c).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if !CertStore.shared.isUsable(c) {
                    Text("证书文件缺失：请点「编辑」重新选择 P12 与描述文件")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Button {
                editingCert = c
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                pendingDeleteCert = c
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCertID = c.id }
        .frame(minHeight: 44)
    }

    private func saveCert() {
        guard let p12 = newP12, let prov = newProv else { return }
        errorTip = nil
        if let saved = certs.add(name: newName, p12: p12, prov: prov, password: newPass) {
            model.selectedCertID = saved.id
            savedTip = saved.name
            newName = ""; newP12 = nil; newProv = nil; newPass = ""
        } else {
            errorTip = "保存失败：无法读取所选文件"
        }
    }

    // MARK: - 已签名 IPA

    private var ipaSection: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("已签名 IPA 库").font(.headline)
                } icon: {
                    Image(systemName: "shippingbox.fill").foregroundStyle(Theme.brand)
                }

                if ipas.items.isEmpty {
                    Text("本 App 签名打包的产物会自动入库；也可以把别处已经签名好的 IPA 导入进来。点击条目或「安装」即可装到本机，点「导出」可保存/分享出去。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 0) {
                        ForEach(ipas.items) { item in
                            ipaRow(item)
                            if item.id != ipas.items.last?.id { Divider() }
                        }
                    }
                }

                Divider()
                Button {
                    let picker = DocumentPicker(types: [UTType(filenameExtension: "ipa") ?? .data, .data]) { urls in
                        importSignedIPA(urls.first)
                    }
                    topRootVC()?.present(picker, animated: true)
                } label: {
                    Label("导入已签名 IPA", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                if let ipaTip {
                    Text(ipaTip)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func ipaRow(_ item: SignedIPA) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.zipper").foregroundStyle(Theme.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("\(item.createdAt.formatted(date: .numeric, time: .shortened)) · \(item.sizeText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Button {
                exportIPA(item)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            Button {
                model.installSaved(item)
            } label: {
                Label("安装", systemImage: "arrow.down.app")
            }
            .buttonStyle(.bordered)
            .disabled(model.busy)
            Button(role: .destructive) {
                pendingDeleteIPA = item
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { if !model.busy { model.installSaved(item) } }
        .frame(minHeight: 46)
    }

    /// 导入外部「已经签名好的」IPA：复制入库，随即可点击安装或再导出。
    private func importSignedIPA(_ url: URL?) {
        guard let url else { return }
        ipaTip = nil
        guard url.pathExtension.lowercased() == "ipa" else {
            ipaTip = "导入失败：请选择 .ipa 文件"
            return
        }
        if let item = IPALibrary.shared.importExternal(url) {
            ipaTip = "已导入：\(item.name)（\(item.sizeText)），可点「安装」"
        } else {
            ipaTip = "导入失败：无法读取或复制该 IPA（可能已被系统清理，请重新选择）"
        }
    }

    /// 导出库里的 IPA：弹系统分享面板，可「存储到文件」或发给其他 App。
    private func exportIPA(_ item: SignedIPA) {
        let src = ipas.url(for: item)
        guard FileManager.default.fileExists(atPath: src.path) else {
            ipaTip = "导出失败：文件不存在（\(item.name)）"
            return
        }
        // 分享面板显示的是文件的真实文件名，而库内文件是 <UUID>.ipa：
        // 先按条目名复制一份到临时目录，导出的文件名才是可读的。
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("si_share_\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let named = tmp.appendingPathComponent(item.name.isEmpty ? "app.ipa" : item.name)
        try? fm.removeItem(at: named)
        let url = (try? fm.copyItem(at: src, to: named)) != nil ? named : src
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = vc.popoverPresentationController, let view = topRootVC()?.view {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        topRootVC()?.present(vc, animated: true)
    }
}

/// 用系统「文件」App 选文件的行（可指定类型）。
struct FilePickRow: View {
    let title: String
    @Binding var url: URL?
    var types: [UTType]

    var body: some View {
        Button {
            let picker = DocumentPicker(types: types) { url = $0.first }
            topRootVC()?.present(picker, animated: true)
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(url?.lastPathComponent ?? "未选择")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .fieldBackground()
    }
}

/// 取「最顶层」的视图控制器（沿 presentedViewController 向上），
/// 这样在已弹出的 sheet 里也能正常弹出系统文件选择器。
func topRootVC() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let key = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    var vc = key?.windows.first(where: \.isKeyWindow)?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
}

/// 编辑已保存的证书：改名称 / 密码，或替换 p12 / 描述文件。
struct CertEditView: View {
    let cert: SavedCert
    @ObservedObject private var certs = CertStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var password: String
    @State private var newP12: URL? = nil
    @State private var newProv: URL? = nil
    @State private var errorTip: String? = nil

    init(cert: SavedCert) {
        self.cert = cert
        _name = State(initialValue: cert.name)
        _password = State(initialValue: cert.password)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("名称", text: $name)
                        .submitLabel(.done)
                        .onSubmit { dismissKeyboardNow() }
                }
                Section("P12 密码") {
                    SecureField("密码", text: $password)
                        .submitLabel(.done)
                        .onSubmit { dismissKeyboardNow() }
                }
                Section("替换文件（可选）") {
                    FilePickRow(title: "P12 证书", url: $newP12,
                                types: [UTType(filenameExtension: "p12") ?? .data, .data])
                    FilePickRow(title: "描述文件", url: $newProv,
                                types: [UTType(filenameExtension: "mobileprovision") ?? .data, .data])
                }
                if let errorTip {
                    Section {
                        Text(errorTip).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("编辑证书")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private func save() {
        if certs.update(id: cert.id, name: name, password: password, p12: newP12, prov: newProv) != nil {
            // 若编辑的是当前选中证书，立即把最新内容同步到主流程。
            if Model.shared.selectedCertID == cert.id {
                Model.shared.refreshSelectedCert()
            }
            dismiss()
        } else {
            errorTip = "保存失败：无法读取所选文件"
        }
    }
}
