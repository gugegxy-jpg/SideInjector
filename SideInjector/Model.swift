import SwiftUI
import Combine

/// 全流程状态：空闲 / 运行中 / 已暂停（可续跑）/ 完成 / 失败。
enum RunOutcome: Equatable {
    case idle, running, paused, done, failed

    var label: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "处理中"
        case .paused: return "已暂停"
        case .done: return "已完成"
        case .failed: return "失败"
        }
    }
}

/// 主流程控制器。
///
/// 设计要点（对齐 SideInstaller 的体验）：
/// - 进度是**真实**的：只有安装真正成功才到 100%，失败/暂停绝不会显示「已完成」。
/// - 「设备配对」是流程中的一个阶段，且**只需一次**：已配对会自动跳过。
/// - 任一步失败即**暂停并保留现场**（解压产物/签名中间件都在），用户修好环境后
///   点「继续」从该步续跑。
final class Model: ObservableObject {
    static let shared = Model()

    // MARK: - 证书 / 描述文件
    @Published var certP12: URL?
    @Published var certPass: String = ""
    @Published var profile: URL?
    /// iOS 18–26 需要 PC 生成的配对文件；iOS 27+ 可设备端自配对（见「设备配对」卡片）。
    @Published var pairingFile: URL?

    // MARK: - 输入
    @Published var ipa: URL?
    @Published var dylib: URL?
    @Published var dylibName: String = "inject.dylib"
    @Published var bundleId: String = ""
    @Published var displayName: String = ""

    // MARK: - 运行状态
    @Published var status: String = "空闲"
    @Published var outcome: RunOutcome = .idle
    @Published var progress: Double = 0
    @Published var stageIndex: Int = -1
    @Published var pauseReason: String? = nil
    @Published var shareItem: URL? = nil

    /// 全流程阶段。配对只需一次：已配对会自动跳过该阶段。
    let stages = ["解压 IPA", "注入 dylib", "修改 Bundle 信息", "重签", "打包 IPA", "设备配对", "安装到设备"]

    private let pairingStage = 5
    private let installStage = 6

    var busy: Bool { outcome == .running || outcome == .paused }

    // MARK: - 流程上下文（用于暂停后从失败处续跑）
    private struct FlowContext {
        let ipaCopy: URL
        let dylibCopy: URL?
        let p12Copy: URL
        let provCopy: URL
        let pairingCopy: URL?
        let tmp: URL
        let outIpa: URL
        let bundleId: String
        let displayName: String
        let certPass: String
        let dylibName: String
    }
    private var ctx: FlowContext?
    private var resumeStep = 0

    // MARK: - 入口

    func run() {
        guard !busy else { return }
        guard let ipa else { status = "请先选择 IPA 文件"; return }
        guard certP12 != nil else { status = "请先选择 P12 证书"; return }
        guard profile != nil else { status = "请先选择 mobileprovision 描述文件"; return }

        LogStore.shared.clear()
        shareItem = nil
        stageIndex = -1
        progress = 0
        pauseReason = nil
        outcome = .idle

        guard let ctx = buildContext(ipa: ipa) else { return }
        self.ctx = ctx
        resumeStep = 0
        outcome = .running
        status = "开始处理…"
        runFlow(from: 0, ctx: ctx)
    }

    /// 用户修好环境（连 Wi-Fi / 开 VPN / 完成配对）后从这里继续。
    func resume() {
        guard let ctx, outcome == .paused else { return }
        pauseReason = nil
        outcome = .running
        status = "继续处理…"
        runFlow(from: resumeStep, ctx: ctx)
    }

    /// 取消 / 复位。
    func reset() {
        ctx = nil
        resumeStep = 0
        outcome = .idle
        stageIndex = -1
        progress = 0
        pauseReason = nil
        status = "空闲"
    }

    // MARK: - 上下文构建（把用户选的文件复制进沙盒，规避安全作用域）

    private func buildContext(ipa: URL) -> FlowContext? {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("si_in_\(UUID().uuidString)")
        try? fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        func copyIn(_ url: URL?, _ name: String) -> URL? {
            guard let url else { return nil }
            let dst = workDir.appendingPathComponent(name)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try? fm.removeItem(at: dst)
            guard (try? fm.copyItem(at: url, to: dst)) != nil else { return nil }
            return fm.fileExists(atPath: dst.path) ? dst : nil
        }

        guard let ipaCopy = copyIn(ipa, "in.ipa") else {
            status = "无法读取 IPA 文件（系统拒绝访问，请换用「文件」App 内可访问的位置）"
            return nil
        }
        let dylibCopy = copyIn(dylib, "in.dylib")
        guard let p12Copy = copyIn(certP12, "cert.p12") else {
            status = "无法读取 P12 证书（系统拒绝访问）"
            return nil
        }
        guard let provCopy = copyIn(profile, "profile.mobileprovision") else {
            status = "无法读取 mobileprovision 描述文件（系统拒绝访问）"
            return nil
        }
        let pairingCopy = copyIn(pairingFile, "pairing.plist")

        let tmp = fm.temporaryDirectory.appendingPathComponent("si_out_\(UUID().uuidString)")
        let outIpa = fm.temporaryDirectory.appendingPathComponent("signed_\(UUID().uuidString).ipa")

        return FlowContext(ipaCopy: ipaCopy, dylibCopy: dylibCopy, p12Copy: p12Copy,
                           provCopy: provCopy, pairingCopy: pairingCopy, tmp: tmp, outIpa: outIpa,
                           bundleId: bundleId, displayName: displayName,
                           certPass: certPass, dylibName: dylibName)
    }

    // MARK: - 流程执行

    private func runFlow(from start: Int, ctx: FlowContext) {
        Task.detached { [weak self] in
            guard let self else { return }
            let r = RustBridge.shared

            var i = start
            while i < self.stages.count {
                switch i {
                case 0:
                    self.markRunning(0, "解压 IPA…")
                    if r.unzip(ipa: ctx.ipaCopy.path, out: ctx.tmp.path) != 0 {
                        self.pause(at: 0, reason: "解压 IPA 失败：IPA 可能损坏或非标准格式")
                        return
                    }
                    self.markDone(0)

                case 1:
                    guard let app = self.resolveApp(tmp: ctx.tmp) else {
                        self.pause(at: 1, reason: "未在 Payload 中找到 .app"); return
                    }
                    if let dylib = ctx.dylibCopy {
                        self.markRunning(1, "注入 dylib…")
                        if r.inject(app: app.path, dylib: dylib.path, name: ctx.dylibName) != 0 {
                            self.pause(at: 1, reason: "注入 dylib 失败：主二进制可能不是单切片 arm64，或该 IPA 未砸壳"); return
                        }
                        self.markDone(1)
                    } else {
                        self.markSkipped(1, "未选择 dylib，跳过注入")
                    }

                case 2:
                    let b = ctx.bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
                    let d = ctx.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if b.isEmpty && d.isEmpty {
                        self.markSkipped(2, "未修改 Bundle 信息，跳过")
                    } else {
                        guard let app = self.resolveApp(tmp: ctx.tmp) else {
                            self.pause(at: 2, reason: "未在 Payload 中找到 .app"); return
                        }
                        self.markRunning(2, "修改 Bundle 信息…")
                        if r.setBundleInfo(app: app.path, bundleId: b, displayName: d) != 0 {
                            self.pause(at: 2, reason: "修改 Bundle 信息失败"); return
                        }
                        self.markDone(2)
                    }

                case 3:
                    guard let app = self.resolveApp(tmp: ctx.tmp) else {
                        self.pause(at: 3, reason: "未在 Payload 中找到 .app"); return
                    }
                    self.markRunning(3, "重签…")
                    if r.sign(app: app.path, p12: ctx.p12Copy.path, pw: ctx.certPass,
                              prov: ctx.provCopy.path, team: "") != 0 {
                        self.pause(at: 3, reason: "重签失败：请检查证书/描述文件是否匹配，以及 IPA 是否已砸壳"); return
                    }
                    self.markDone(3)

                case 4:
                    self.markRunning(4, "打包 IPA…")
                    if r.zip(dir: ctx.tmp.path, out: ctx.outIpa.path) != 0 {
                        self.pause(at: 4, reason: "重新打包失败"); return
                    }
                    DispatchQueue.main.async { self.shareItem = ctx.outIpa }
                    self.markDone(4)

                case 5: // 设备配对（= pairingStage）
                    // 配对只需一次：已配对直接跳过。
                    if self.isPaired {
                        self.markSkipped(self.pairingStage, "已配对")
                    } else {
                        DispatchQueue.main.async {
                            self.stageIndex = self.pairingStage
                            self.resumeStep = self.pairingStage
                            self.outcome = .paused
                            let reason = "尚未配对：请在「设备配对」卡片点「开始配对」完成一次配对，完成后会自动继续"
                            self.pauseReason = reason
                            self.status = reason
                        }
                        return
                    }

                case 6: // 安装到设备（= installStage）
                    self.markRunning(self.installStage, "安装到设备…")
                    let result = await InstallEngine.shared.install(
                        ipaPath: ctx.outIpa.path,
                        pairingURL: ctx.pairingCopy
                    ) { frac, msg in
                        self.installProgress(frac, msg)
                    }
                    if result.ok {
                        self.markDone(self.installStage)
                    } else {
                        self.pause(at: self.installStage, reason: result.message); return
                    }

                default:
                    break
                }
                i += 1
            }
            self.finishSuccess()
        }
    }

    // MARK: - 状态更新（统一切回主线程）

    private func markRunning(_ i: Int, _ msg: String) {
        DispatchQueue.main.async {
            self.stageIndex = i
            self.status = msg
            self.progress = max(self.progress, (Double(i) + 0.2) / Double(self.stages.count))
        }
    }
    private func markDone(_ i: Int) {
        DispatchQueue.main.async {
            self.progress = max(self.progress, Double(i + 1) / Double(self.stages.count))
        }
    }
    private func markSkipped(_ i: Int, _ msg: String) {
        DispatchQueue.main.async {
            self.stageIndex = i
            self.status = msg + "（已跳过）"
            self.progress = max(self.progress, Double(i + 1) / Double(self.stages.count))
        }
    }
    private func installProgress(_ frac: Double, _ msg: String) {
        DispatchQueue.main.async {
            let span = 1.0 / Double(self.stages.count)
            let base = Double(self.installStage) / Double(self.stages.count)
            // 安装阶段内部最多到 99%，只有真正成功才由 finishSuccess 推到 100%。
            self.progress = min(max(self.progress, base + span * frac), 0.99)
            self.status = msg
        }
    }
    private func pause(at step: Int, reason: String) {
        DispatchQueue.main.async {
            self.resumeStep = step
            self.stageIndex = step
            self.outcome = .paused
            self.pauseReason = reason
            self.status = reason
        }
    }
    private func finishSuccess() {
        DispatchQueue.main.async {
            self.progress = 1
            self.stageIndex = self.stages.count - 1
            self.outcome = .done
            self.pauseReason = nil
            self.status = "已完成：安装成功"
        }
    }

    // MARK: - 工具

    /// 确保 tmp/Payload 存在并返回其中的 .app（幂等，供各步骤与续跑复用）。
    private func resolveApp(tmp: URL) -> URL? {
        let fm = FileManager.default
        let payload = tmp.appendingPathComponent("Payload")
        if !fm.fileExists(atPath: payload.path) {
            if let app = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) {
                try? fm.createDirectory(at: payload, withIntermediateDirectories: true)
                try? fm.moveItem(at: app, to: payload.appendingPathComponent(app.lastPathComponent))
            }
        }
        return try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
    }

    /// 是否已配对：设备端自配对产物、已导入的配对文件，或已成功配过一次。
    var isPaired: Bool {
        if PairingController.shared.pairedDeviceName != nil { return true }
        if PairingController.shared.pairingFilePath != nil { return true }
        if let url = pairingFile, FileManager.default.fileExists(atPath: url.path) { return true }
        return false
    }
}
