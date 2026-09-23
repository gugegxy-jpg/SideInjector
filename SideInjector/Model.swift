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
/// 设计要点：
/// - 进度是**真实**的：只有安装真正成功才到 100%，失败/暂停绝不会显示「已完成」。
/// - 「设备配对」是流程中的一个阶段，且**只需一次**：已配对会自动跳过。
/// - 任一步失败即**暂停并保留现场**，用户可点「继续」从该步续跑，也可点「取消」放弃。
/// - 点「执行」立刻给出「准备文件…」反馈；复制大文件在后台线程进行，
///   不会卡住主线程（否则会出现「点了没反应」）。
final class Model: ObservableObject {
    static let shared = Model()

    // MARK: - 证书（下拉选择证书库里已保存的证书）
    @Published var certP12: URL?
    @Published var certPass: String = ""
    @Published var profile: URL?
    /// 首页证书下拉的选中项。变化时同步 p12 / 描述文件 / 密码。
    @Published var selectedCertID: UUID? {
        didSet { applySelectedCert() }
    }
    /// iOS 18–26 需要 PC 生成的配对文件；iOS 27+ 可设备端自配对（见「设备配对」卡片）。
    @Published var pairingFile: URL?

    // MARK: - 输入
    @Published var ipa: URL?
    /// 可一次选择多个 dylib，逐个注入（注入名默认取各自文件名）。
    @Published var dylibs: [URL] = []
    @Published var bundleId: String = ""
    @Published var displayName: String = ""

    // MARK: - 运行状态
    @Published var status: String = "空闲"
    @Published var outcome: RunOutcome = .idle
    @Published var progress: Double = 0
    @Published var stageIndex: Int = -1
    @Published var pauseReason: String? = nil
    @Published var shareItem: URL? = nil
    /// 启动前校验/准备失败的原因（非 nil 时界面弹窗提示）。
    @Published var inputError: String? = nil

    /// 全流程阶段。配对只需一次：已配对会自动跳过该阶段。
    let stages = ["解压 IPA", "注入 dylib", "修改 Bundle 信息", "重签", "打包 IPA", "设备配对", "安装到设备"]

    private let pairingStage = 5
    private let installStage = 6

    var busy: Bool { outcome == .running || outcome == .paused }

    // MARK: - 运行模式（完整流程 / 仅安装库里已签名的 IPA）
    private enum FlowMode { case full, installOnly }
    private var mode: FlowMode = .full
    private var installOnlyURL: URL?

    /// 界面展示的阶段：库里直接安装时只有一步。
    var displayStages: [String] { mode == .installOnly ? ["安装到设备"] : stages }
    private var stepCount: Int { mode == .installOnly ? 1 : stages.count }

    // MARK: - 输入快照（在主线程抓取，供后台准备使用）
    private struct InputSnapshot {
        let ipa: URL
        let dylibs: [URL]
        let p12: URL?
        let prov: URL?
        let pairing: URL?
        let bundleId: String
        let displayName: String
        let certPass: String
    }

    // MARK: - 流程上下文（用于暂停后从失败处续跑 / 取消后清理）
    private struct FlowContext {
        let ipaCopy: URL
        let ipaName: String
        /// 已复制进沙盒的 dylib 与其注入名。
        let dylibs: [(url: URL, name: String)]
        let p12Copy: URL
        let provCopy: URL
        let pairingCopy: URL?
        let tmp: URL
        let outIpa: URL
        let bundleId: String
        let displayName: String
        let certPass: String
    }
    private var ctx: FlowContext?
    private var resumeStep = 0
    private var flowTask: Task<Void, Never>?

    // MARK: - 选中证书

    var selectedCert: SavedCert? {
        guard let id = selectedCertID else { return nil }
        return CertStore.shared.certs.first { $0.id == id }
    }

    private func applySelectedCert() {
        guard let cert = selectedCert else { return }
        certP12 = URL(fileURLWithPath: cert.p12Path)
        profile = URL(fileURLWithPath: cert.provPath)
        certPass = cert.password
    }

    /// 证书被编辑后，把最新内容同步回当前选中项。
    func refreshSelectedCert() { applySelectedCert() }

    /// 当前选中的证书被删除时调用：清空引用，避免指向已不存在的文件。
    func clearSelectedCert() {
        selectedCertID = nil
        certP12 = nil
        profile = nil
        certPass = ""
    }

    // MARK: - 入口

    func run() {
        guard !busy else { return }

        // 1) 校验（失败立刻弹窗；此时不动日志，方便看到上次现场）
        guard let ipa else { return failInput("请先选择 IPA 文件") }
        guard certP12 != nil else {
            return failInput("还没有选择证书：请到「库」页签添加证书，再在首页下拉中选择")
        }
        guard profile != nil else {
            return failInput("所选证书缺少描述文件（mobileprovision），请到「库」页签编辑该证书并重新选择")
        }

        // 2) 立刻给出可见反馈：准备阶段要把 IPA/证书复制进沙盒，大 IPA 会耗时。
        let snap = InputSnapshot(ipa: ipa, dylibs: dylibs,
                                 p12: certP12, prov: profile, pairing: pairingFile,
                                 bundleId: bundleId, displayName: displayName, certPass: certPass)
        LogStore.shared.clear()
        shareItem = nil
        stageIndex = -1
        progress = 0
        pauseReason = nil
        inputError = nil
        mode = .full
        installOnlyURL = nil
        outcome = .running
        status = "准备文件（复制到沙盒）…"
        LogStore.shared.append("准备文件：\(ipa.lastPathComponent)")

        // 3) 在后台线程做复制，避免卡住主线程（这就是之前「点了没反应」的原因）。
        flowTask = Task.detached { [weak self] in
            guard let self else { return }
            guard let ctx = self.buildContext(snap) else { return }   // 失败时已 failInput
            DispatchQueue.main.async {
                guard self.outcome != .idle else { return }
                self.ctx = ctx
                self.resumeStep = 0
                self.status = "开始处理…"
                self.runFlow(from: 0, ctx: ctx)
            }
        }
    }

    /// 启动前失败：回到空闲并弹窗提示（可从任意线程调用）。
    private func failInput(_ msg: String) {
        DispatchQueue.main.async {
            self.outcome = .idle
            self.stageIndex = -1
            self.progress = 0
            self.status = msg
            self.inputError = msg
            LogStore.shared.append("无法开始：\(msg)")
        }
    }

    // MARK: - 输入文件持久化
    //
    // DocumentPicker(asCopy:) 给的副本位于 App 的临时目录，系统可能随时清理；
    // 一旦被清理，run() 里复制进沙盒就会失败（表现为「点了没反应」）。
    // 因此在「选择文件」的当下就把文件复制进 App 的持久目录，之后始终读自己这份。

    private static func persistentInputDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Inputs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 是否是我们自己导入到持久目录的副本（可以安全删除）。
    private static func isOwnedInput(_ url: URL) -> Bool {
        url.path.contains("/Inputs/")
    }

    /// 选择 IPA 后立刻落盘到持久目录。
    func importIPA(_ url: URL?) {
        guard let url else { return }
        let fm = FileManager.default
        let dir = Self.persistentInputDir()
        let dst = dir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
        let a = url.startAccessingSecurityScopedResource()
        defer { if a { url.stopAccessingSecurityScopedResource() } }
        if (try? fm.copyItem(at: url, to: dst)) != nil {
            if let old = ipa, Self.isOwnedInput(old) { try? fm.removeItem(at: old) }
            ipa = dst
            LogStore.shared.append("已导入 IPA：\(url.lastPathComponent)")
        } else {
            ipa = url
            LogStore.shared.append("IPA 导入持久目录失败，暂用原路径：\(url.lastPathComponent)")
        }
        inputError = nil
    }

    /// 选择 dylib 后立刻落盘到持久目录（可多选）。
    func importDylibs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fm = FileManager.default
        let dir = Self.persistentInputDir()
        for url in urls {
            let dst = dir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
            let a = url.startAccessingSecurityScopedResource()
            if (try? fm.copyItem(at: url, to: dst)) != nil {
                dylibs.append(dst)
            } else {
                dylibs.append(url)
                LogStore.shared.append("dylib 导入持久目录失败，暂用原路径：\(url.lastPathComponent)")
            }
            if a { url.stopAccessingSecurityScopedResource() }
        }
    }

    /// 展示用文件名：去掉导入时加上的 UUID 前缀，还原用户看到的原始名字。
    static func displayName(for url: URL) -> String {
        let n = url.lastPathComponent
        if let idx = n.firstIndex(of: "_"),
           n.distance(from: n.startIndex, to: idx) == 36 {   // UUID 字符串长度
            return String(n[n.index(after: idx)...])
        }
        return n
    }

    /// 「库」里点击一条已签名 IPA → 直接安装（只跑安装阶段）。
    func installSaved(_ item: SignedIPA) {
        guard !busy else { return }
        LogStore.shared.clear()
        mode = .installOnly
        installOnlyURL = IPALibrary.shared.url(for: item)
        ctx = nil
        resumeStep = 0
        shareItem = nil
        stageIndex = -1
        progress = 0
        pauseReason = nil
        outcome = .running
        status = "准备安装：\(item.name)"
        runInstallOnly()
    }

    /// 用户修好环境（连 Wi-Fi / 开 VPN / 完成配对）后从这里继续。
    func resume() {
        guard outcome == .paused else { return }
        pauseReason = nil
        outcome = .running
        status = "继续处理…"
        switch mode {
        case .full:
            guard let ctx else { outcome = .idle; return }
            runFlow(from: resumeStep, ctx: ctx)
        case .installOnly:
            runInstallOnly()
        }
    }

    /// 取消当前流程：停止任务、清理临时文件、复位到空闲（保留已选输入）。
    func cancel() {
        guard busy else { return }
        // 先置为 idle：流程里所有状态回调都会因 outcome == .idle 而被忽略，
        // 避免已取消的步骤随后又把状态改回「处理中/已暂停」。
        outcome = .idle
        flowTask?.cancel()
        flowTask = nil
        cleanupTemp()
        ctx = nil
        resumeStep = 0
        installOnlyURL = nil
        mode = .full
        stageIndex = -1
        progress = 0
        pauseReason = nil
        shareItem = nil
        status = "已取消"
        LogStore.shared.append("已取消当前流程，临时文件已清理")
    }

    /// 清理本次流程用到的临时目录与临时产物。
    private func cleanupTemp() {
        let fm = FileManager.default
        if let ctx {
            try? fm.removeItem(at: ctx.ipaCopy.deletingLastPathComponent())  // si_in_*
            try? fm.removeItem(at: ctx.tmp)                                  // si_out_*
            try? fm.removeItem(at: ctx.outIpa)                               // signed_*.ipa
        }
        // 兜底：清掉可能残留的同前缀临时项。
        if let items = try? fm.contentsOfDirectory(at: fm.temporaryDirectory,
                                                   includingPropertiesForKeys: nil) {
            for u in items {
                let n = u.lastPathComponent
                if n.hasPrefix("si_in_") || n.hasPrefix("si_out_") || n.hasPrefix("signed_") {
                    try? fm.removeItem(at: u)
                }
            }
        }
    }

    // MARK: - 上下文构建（把用户选的文件复制进沙盒；在后台线程执行）

    private func buildContext(_ snap: InputSnapshot) -> FlowContext? {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("si_in_\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            failInput("无法创建临时目录：\(error.localizedDescription)")
            return nil
        }

        /// 记录输入文件是否可读 / 大小，便于定位「准备失败」的真正原因。
        func probe(_ url: URL?, _ label: String) {
            guard let url else {
                LogStore.shared.append("输入检查：\(label) 未选择")
                return
            }
            let a = url.startAccessingSecurityScopedResource()
            defer { if a { url.stopAccessingSecurityScopedResource() } }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value
            let sizeText = size.map { "\($0)B" } ?? "未知"
            LogStore.shared.append("输入检查：\(label) 可读=\(attrs != nil) 大小=\(sizeText) 文件=\(url.lastPathComponent)")
        }

        func copyIn(_ url: URL?, _ name: String) -> URL? {
            guard let url else { return nil }
            let dst = workDir.appendingPathComponent(name)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: url, to: dst)) != nil, fm.fileExists(atPath: dst.path) {
                return dst
            }
            // 兜底：个别安全作用域 URL 上 copyItem 会失败，改为读数据再写入。
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                try? data.write(to: dst)
                if fm.fileExists(atPath: dst.path) { return dst }
            }
            return nil
        }

        probe(snap.ipa, "IPA")
        probe(snap.p12, "P12")
        probe(snap.prov, "描述文件")
        probe(snap.pairing, "配对文件")

        guard let ipaCopy = copyIn(snap.ipa, "in.ipa") else {
            failInput("无法读取 IPA 文件「\(snap.ipa.lastPathComponent)」：文件可能已被系统清理或无权访问，请重新选择 IPA")
            return nil
        }
        guard let p12Copy = copyIn(snap.p12, "cert.p12") else {
            failInput("无法读取证书里的 P12 文件：请到「库」页签编辑该证书并重新选择 P12")
            return nil
        }
        guard let provCopy = copyIn(snap.prov, "profile.mobileprovision") else {
            failInput("无法读取证书里的描述文件（mobileprovision）：请到「库」页签编辑该证书并重新选择")
            return nil
        }
        let pairingCopy = copyIn(snap.pairing, "pairing.plist")

        // 多个 dylib：逐个复制进沙盒，注入名默认取文件名（去重、补 .dylib 后缀）。
        var copiedDylibs: [(url: URL, name: String)] = []
        var usedNames = Set<String>()
        for (idx, src) in snap.dylibs.enumerated() {
            let base = Self.dylibInjectionName(from: src.lastPathComponent, fallbackIndex: idx)
            let name = Self.uniqueName(base, used: &usedNames)
            if let dst = copyIn(src, "dylib_\(idx)_\(name)") {
                copiedDylibs.append((url: dst, name: name))
            } else {
                LogStore.shared.append("跳过无法读取的 dylib：\(src.lastPathComponent)（请重新选择）")
            }
        }

        let tmp = fm.temporaryDirectory.appendingPathComponent("si_out_\(UUID().uuidString)")
        let outIpa = fm.temporaryDirectory.appendingPathComponent("signed_\(UUID().uuidString).ipa")

        return FlowContext(ipaCopy: ipaCopy, ipaName: snap.ipa.lastPathComponent,
                           dylibs: copiedDylibs, p12Copy: p12Copy,
                           provCopy: provCopy, pairingCopy: pairingCopy, tmp: tmp, outIpa: outIpa,
                           bundleId: snap.bundleId, displayName: snap.displayName,
                           certPass: snap.certPass)
    }

    /// 由源文件名推断注入名（补 .dylib 后缀；空则用序号兜底）。
    private static func dylibInjectionName(from file: String, fallbackIndex: Int) -> String {
        var n = file.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { n = "inject\(fallbackIndex).dylib" }
        if !n.lowercased().hasSuffix(".dylib") { n += ".dylib" }
        return n
    }

    /// 保证注入名在本次流程内唯一（重名时追加 -2、-3…）。
    private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        if !used.contains(name) { used.insert(name); return name }
        let stem = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidate = "\(stem)-\(i).dylib"
            if !used.contains(candidate) { used.insert(candidate); return candidate }
            i += 1
        }
    }

    // MARK: - 完整流程

    private func runFlow(from start: Int, ctx: FlowContext) {
        flowTask = Task.detached { [weak self] in
            guard let self else { return }
            let r = RustBridge.shared

            var i = start
            while i < self.stages.count {
                if Task.isCancelled { return }
                switch i {
                case 0:
                    self.markRunning(0, "解压 IPA…")
                    if r.unzip(ipa: ctx.ipaCopy.path, out: ctx.tmp.path) != 0 {
                        self.pause(at: 0, reason: "解压 IPA 失败：IPA 可能损坏或非标准格式"); return
                    }
                    self.markDone(0)

                case 1:
                    guard let app = self.resolveApp(tmp: ctx.tmp) else {
                        self.pause(at: 1, reason: "未在 Payload 中找到 .app"); return
                    }
                    if ctx.dylibs.isEmpty {
                        self.markSkipped(1, "未选择 dylib，跳过注入")
                    } else {
                        self.markRunning(1, "注入 dylib（\(ctx.dylibs.count) 个）…")
                        for d in ctx.dylibs {
                            if Task.isCancelled { return }
                            if r.inject(app: app.path, dylib: d.url.path, name: d.name) != 0 {
                                self.pause(at: 1, reason: "注入 \(d.name) 失败：主二进制可能不是单切片 arm64，或该 IPA 未砸壳")
                                return
                            }
                        }
                        self.markDone(1)
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
                    DispatchQueue.main.async {
                        guard self.outcome != .idle else { return }
                        self.shareItem = ctx.outIpa
                        // 自动入库：即使后面安装失败，也能在「库」里点击直接安装。
                        IPALibrary.shared.add(url: ctx.outIpa, name: ctx.ipaName)
                    }
                    self.markDone(4)

                case 5: // 设备配对（= pairingStage）
                    if self.isPaired {
                        self.markSkipped(self.pairingStage, "已配对")
                    } else {
                        DispatchQueue.main.async {
                            guard self.outcome != .idle else { return }
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

    // MARK: - 仅安装（库里已签名的 IPA）

    private func runInstallOnly() {
        guard let url = installOnlyURL else { return }
        flowTask = Task.detached { [weak self] in
            guard let self else { return }
            if Task.isCancelled { return }
            if !self.isPaired {
                DispatchQueue.main.async {
                    guard self.outcome != .idle else { return }
                    self.stageIndex = 0
                    self.resumeStep = 0
                    self.outcome = .paused
                    let reason = "尚未配对：请在「设备配对」卡片点「开始配对」完成一次配对，完成后会自动继续"
                    self.pauseReason = reason
                    self.status = reason
                }
                return
            }
            self.markRunning(0, "安装到设备…")
            let result = await InstallEngine.shared.install(ipaPath: url.path, pairingURL: nil) { frac, msg in
                self.installProgress(frac, msg)
            }
            if result.ok {
                self.finishSuccess()
            } else {
                self.pause(at: 0, reason: result.message)
            }
        }
    }

    // MARK: - 状态更新（统一切回主线程；outcome == .idle 表示已取消，全部忽略）

    private func markRunning(_ i: Int, _ msg: String) {
        DispatchQueue.main.async {
            guard self.outcome != .idle else { return }
            self.stageIndex = i
            self.status = msg
            self.progress = max(self.progress, (Double(i) + 0.2) / Double(self.stepCount))
        }
    }
    private func markDone(_ i: Int) {
        DispatchQueue.main.async {
            guard self.outcome != .idle else { return }
            self.progress = max(self.progress, Double(i + 1) / Double(self.stepCount))
        }
    }
    private func markSkipped(_ i: Int, _ msg: String) {
        DispatchQueue.main.async {
            guard self.outcome != .idle else { return }
            self.stageIndex = i
            self.status = msg + "（已跳过）"
            self.progress = max(self.progress, Double(i + 1) / Double(self.stepCount))
        }
    }
    private func installProgress(_ frac: Double, _ msg: String) {
        DispatchQueue.main.async {
            guard self.outcome != .idle else { return }
            let span = 1.0 / Double(self.stepCount)
            let base = (self.mode == .installOnly ? 0 : Double(self.installStage)) / Double(self.stepCount)
            // 安装阶段内部最多到 99%，只有真正成功才由 finishSuccess 推到 100%。
            self.progress = min(max(self.progress, base + span * frac), 0.99)
            self.status = msg
        }
    }
    private func pause(at step: Int, reason: String) {
        DispatchQueue.main.async {
            guard self.outcome != .idle else { return }
            self.resumeStep = step
            self.stageIndex = step
            self.outcome = .paused
            self.pauseReason = reason
            self.status = reason
        }
    }
    private func finishSuccess() {
        DispatchQueue.main.async {
            guard self.outcome != .idle else { return }
            self.progress = 1
            self.stageIndex = max(0, self.stepCount - 1)
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
