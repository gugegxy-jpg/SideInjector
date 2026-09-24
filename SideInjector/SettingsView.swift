import SwiftUI

/// 「设置」页 —— 底部第三个页签，位于「库」右侧（见 `ContentView.systemTabView`）。
///
/// 两块内容：
///   1. 「执行期间不被打断」的两个开关（息屏 / 后台保活）；
///   2. 「关于」：作者头像 + **名称**（整行可点，跳 GitHub 仓库）+ 版本号。
struct SettingsView: View {
    @ObservedObject private var model = Model.shared

    /// 作者显示名：默认是用户名，取到 GitHub 的 `name` 后替换掉。
    /// （GitHub 的「名称」没设置时为 `null`，那就保持用户名 —— 见 `AuthorProfile`。）
    @State private var authorName = AuthorProfile.username

    /// 仓库地址（点「作者」那一行时跳转）。
    private static let repoURL = URL(string: "https://github.com/\(AuthorProfile.username)/SideInjector")!
    /// 版本的展示串：`CFBundleShortVersionString（CFBundleVersion）`。
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        return "\(short)（\(build)）"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("设置").font(.largeTitle.weight(.bold))
                    } icon: {
                        Image(systemName: "gearshape.fill").foregroundStyle(Theme.brand)
                    }
                    Text("与执行流程相关的开关").font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.top, 8)
                // 与首页一致：切到本页签时各块按序「浮动出现」（见 `Theme.cascadeItem`）。
                .cascadeItem(0)

                PanelCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text("执行期间不被打断").font(.headline)
                        } icon: {
                            Image(systemName: "bolt.shield.fill").foregroundStyle(Theme.brand)
                        }
                        Toggle(isOn: $model.keepScreenAwake) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("执行期间不息屏").font(.subheadline.weight(.semibold))
                                Text("用系统标准方式在前台保持屏幕常亮。最省事，也不需要额外权限；"
                                     + "但你自己按电源键锁屏仍会中断。")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Toggle(isOn: $model.keepAliveInBackground) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("执行期间后台保活（切后台）").font(.subheadline.weight(.semibold))
                                Text("循环播放一段静音音频（`UIBackgroundModes: audio`），切后台时进程仍存活，"
                                     + "安装能继续跑完。不支持锁屏 —— 锁屏后进程会被系统挂起、流程会断，"
                                     + "需要长时间无人值守请改用上面的「不息屏」。"
                                     + "代价是全程持有一个音频会话 —— 更耗电，也会占用音频通道。")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("两者可同时开。只开一个的话：想省电选「后台保活」，想简单选「不息屏」。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .cascadeItem(1)

                // 关于：头像 + 作者名称（整行可点，跳仓库）。
                PanelCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text("关于").font(.headline)
                        } icon: {
                            Image(systemName: "person.crop.circle").foregroundStyle(Theme.brand)
                        }
                        Link(destination: Self.repoURL) {
                            HStack(spacing: 12) {
                                AuthorAvatar()
                                Text(authorName)
                                    .font(.subheadline.weight(.semibold))
                                Spacer(minLength: 6)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Text("版本 \(Self.appVersion)　·　第三方声明见 THIRD_PARTY_NOTICES.md")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .cascadeItem(2)
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        // 取一次 GitHub 资料（只为拿「名称」）：拿不到就继续显示用户名，不阻塞、不弹窗。
        .task {
            if let name = await AuthorProfile.fetchDisplayName() {
                authorName = name
            }
        }
    }
}

/// 作者资料：显示名（GitHub 的 `name`）。
///
/// 为什么要联网取：GitHub 的**用户名**（`login`）与**名称**（`name`，个人资料里显示的名字）
/// 是两个字段，只有公开 API 能拿到后者：
/// `https://api.github.com/users/<用户名>` → `{ "login": …, "name": … | null, "avatar_url": … }`。
/// `name` 未设置时是 `null` —— 调用侧**回退显示用户名**。
///
/// 只在打开设置页时请求一次（未认证的公开接口限额 60 次/小时/IP，够用）；
/// 离线 / 超限 / 解析失败一律返回 nil，静默回退。
enum AuthorProfile {
    /// GitHub 用户名（回退显示的内容，也是请求用的标识）。
    static let username = "gugegxy-jpg"

    /// 取 `name`；未设置或请求失败返回 nil。
    static func fetchDisplayName() async -> String? {
        guard let url = URL(string: "https://api.github.com/users/\(username)") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let name = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }
}

/// 作者头像。
///
/// 从 GitHub 的头像地址取（`https://github.com/<用户名>.png`，支持 `?size=` 指定尺寸）——
/// 好处是不用把图片打进包里，而且对方换头像后这里会跟着变。
/// 加载中 / 离线 / 失败时显示同尺寸的占位圆圈（首字母），布局不会跳动。
private struct AuthorAvatar: View {
    private static let url = URL(string: "https://github.com/\(AuthorProfile.username).png?size=200")

    var body: some View {
        AsyncImage(url: Self.url) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.14))
                    Text(String(AuthorProfile.username.prefix(1)).uppercased())
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))
        .accessibilityLabel("作者头像")
    }
}
