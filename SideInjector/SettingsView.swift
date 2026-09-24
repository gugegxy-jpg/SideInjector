import SwiftUI

/// 「设置」页 —— 底部第三个页签，位于「库」右侧（见 `ContentView.systemTabView`）。
///
/// 两块内容：
///   1. 「执行期间不被打断」的两个开关（息屏 / 后台保活）；
///   2. 「关于」：作者 + 仓库入口（点击跳 GitHub）。
struct SettingsView: View {
    @ObservedObject private var model = Model.shared

    /// 仓库地址（「关于」里点击跳转用）。
    private static let repoURL = URL(string: "https://github.com/gugegxy-jpg/SideInjector")!
    /// 版本号（`CFBundleShortVersionString`（build））。
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
                                Text("执行期间后台保活（可锁屏 / 切后台）").font(.subheadline.weight(.semibold))
                                Text("循环播放一段静音音频（`UIBackgroundModes: audio`），锁屏 / 切后台时进程仍存活，"
                                     + "安装能继续跑完。代价是全程持有一个音频会话 —— 更耗电，也会占用音频通道。")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("两者可同时开。只开一个的话：想省电选「后台保活」，想简单选「不息屏」。")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 关于 / 作者：整行可点，跳 GitHub 仓库。
                PanelCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label {
                            Text("关于").font(.headline)
                        } icon: {
                            Image(systemName: "person.crop.circle").foregroundStyle(Theme.brand)
                        }
                        Link(destination: Self.repoURL) {
                            HStack(spacing: 10) {
                                Image(systemName: "curlybraces")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 30, height: 30)
                                    .background(Circle().fill(Theme.accent.opacity(0.14)))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("作者：gugegxy-jpg").font(.subheadline.weight(.semibold))
                                    Text("github.com/gugegxy-jpg/SideInjector")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Text("版本 \(Self.appVersion)　·　参考 SideInstaller by FrizzleM、"
                             + "apple-codesign（MPL-2.0）与 idevice（MIT）；"
                             + "完整第三方声明见仓库根目录 THIRD_PARTY_NOTICES.md")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }
}
