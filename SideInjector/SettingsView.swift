import SwiftUI

/// 「设置」页 —— 底部第三个页签，位于「库」右侧（见 `ContentView.systemTabView`）。
///
/// 目前只有「执行期间不被打断」的两项开关，它们针对同一个问题：
/// 整个流程（解包 → 注入 → 签名 → 打包 → 上传安装）可能持续十几分钟，
/// 中途息屏 / 切到别的 App 会让本 App 被系统挂起，流程断在半路。
/// 两种手段各有取舍，所以都放出来让用户自己选（可以同时开）。
struct SettingsView: View {
    @ObservedObject private var model = Model.shared

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
            }
            .padding(20)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
    }
}
