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
        .scrollDismissesKeyboard(.interactively)
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
                FilePickRow(title: "P12 证书", url: $newP12,
                            types: [UTType(filenameExtension: "p12") ?? .data, .data])
                SecureField("P12 密码", text: $newPass)
                    .textFieldStyle(.plain)
                    .fieldBackground()
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
            Button(role: .destructive) {
                if model.selectedCertID == c.id { model.selectedCertID = nil }
                certs.remove(c)
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
                ipas.remove(item)
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

/// 取当前 key window 的 rootViewController，用于弹出系统文件选择器。
func topRootVC() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let key = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    return key?.windows.first(where: \.isKeyWindow)?.rootViewController
}
