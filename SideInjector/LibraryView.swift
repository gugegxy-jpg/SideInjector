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

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                certSection
                ipaSection
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)   // 一滚动就收起键盘
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
    }

    private var certDeleteShown: Binding<Bool> {
        Binding(get: { pendingDeleteCert != nil }, set: { if !$0 { pendingDeleteCert = nil } })
    }
    private var ipaDeleteShown: Binding<Bool> {
        Binding(get: { pendingDeleteIPA != nil }, set: { if !$0 { pendingDeleteIPA = nil } })
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
                Text(URL(fileURLWithPath: c.provPath).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                    Text("已签名 IPA").font(.headline)
                } icon: {
                    Image(systemName: "shippingbox.fill").foregroundStyle(Theme.brand)
                }

                if ipas.items.isEmpty {
                    Text("完成一次「注入 + 签名」后，产物会自动出现在这里，点击即可直接安装。")
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
}

/// 用系统「文件」App 选文件的行（可指定类型）。
struct FilePickRow: View {
    let title: String
    @Binding var url: URL?
    var types: [UTType]

    var body: some View {
        Button {
            let picker = DocumentPicker(types: types) { url = $0 }
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
