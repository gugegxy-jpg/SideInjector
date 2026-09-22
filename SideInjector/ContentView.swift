import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var log: LogStore

    var body: some View {
        NavigationView {
            Form {
                Section("开发证书") {
                    FileRow(title: "P12 证书", url: $model.certP12)
                    SecureField("P12 密码", text: $model.certPass)
                    FileRow(title: "描述文件(mobileprovision)", url: $model.profile)
                    TextField("Team ID", text: $model.teamId)
                }
                Section("输入") {
                    FileRow(title: "IPA 文件", url: $model.ipa)
                    FileRow(title: "要注入的 dylib", url: $model.dylib)
                    TextField("注入后文件名", text: $model.dylibName)
                }
                Section {
                    Button(action: { model.run() }) {
                        if model.busy {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Text("注入 + 签名 + 安装").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.busy)
                    Text(model.status).foregroundStyle(.secondary)
                }
                Section("日志") {
                    ScrollView {
                        Text(log.text)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 200)
                }
            }
            .navigationTitle("SideInjector")
        }
    }
}

/// 用系统「文件」App 选文件的行。
struct FileRow: View {
    let title: String
    @Binding var url: URL?

    var body: some View {
        Button {
            let picker = DocumentPicker { url = $0 }
            UIApplication.shared.windows.first?.rootViewController?
                .present(picker, animated: true)
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(url?.lastPathComponent ?? "未选择")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
