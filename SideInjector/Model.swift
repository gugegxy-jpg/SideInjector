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
    /// 只注入导出：跳过签名，只做「解压 → 注入 → 改 Bundle → 打包」，产出未签名 IPA。
    /// 未签名的 IPA 装不上设备，因此该模式下「设备配对」「安装到设备」两阶段会被跳过。
    @Published var skipSign: Bool = false
    /// iOS 18–26 需要 PC 生成的配对文件；iOS 27+ 可设备端自配对（见「设备配对」卡片）。
    @Published var pairingFile: URL?

    // MARK: - 输入
    /// 选中的 IPA。切换时顺带读一次它自带的 Bundle ID / 显示名（只读，用于提示与「是否改过」判定）。
    @Published var ipa: URL? {
        didSet { refreshIpaInfo() }
    }
    /// 已导入到持久目录的 IPA 列表：首页可像选证书一样直接下拉选择，无需每次重选文件。
    @Published var savedIPAs: [URL] = []
    /// 可一次选择多个 dylib，逐个注入（注入名默认取各自文件名）。
    @Published var dylibs: [URL] = []
    @Published var bundleId: String = ""
    @Published var displayName: String = ""

    // MARK: - 当前 IPA 自带信息（**只作提示**，不会自动填进输入框）

    /// 当前 IPA 自带的 Bundle ID（空 = 未知 / 还没读到）。
    @Published var ipaBundleId: String = ""
    /// 当前 IPA 自带的显示名（优先 `CFBundleDisplayName`，退回 `CFBundleName`）。
    @Published var ipaDisplayName: String = ""
    /// 当前 IPA 里「扩展 Bundle ID 不以主 App ID 为前缀」的列表 —— 非空说明这个包**自带错配**。
    @Published var ipaExtensionMismatch: [String] = []
    /// 显式修复开关：勾选后才会把嵌套扩展的 Bundle ID 对齐到主 App（修复第三方改包用）。
    @Published var syncExtensionIDs: Bool = false

    /// 输入框提示语：把「当前值」写在提示里，而**不是**填成输入值 —— 输入框的语义是「留空 = 不改」。
    /// （若预填成值，流程第 2 步就必然执行，会连带改写 `CFBundleName`、并在用户什么都没改的
    ///   情况下触发扩展 ID 同步，属于静默改变产物语义。）
    var bundleIdPlaceholder: String {
        ipaBundleId.isEmpty ? "Bundle ID（留空不改）" : "Bundle ID（当前：\(ipaBundleId)，留空不改）"
    }
    var displayNamePlaceholder: String {
        ipaDisplayName.isEmpty ? "显示名称（留空不改）" : "显示名称（当前：\(ipaDisplayName)，留空不改）"
    }

    /// IPA 信息缓存：同一个文件只解析一次（键 = 路径，另存大小 + 修改时间判断文件是否变过）。
    ///
    /// 为什么需要：解析 zip 必须读**整个中央目录**，成本与条目数成正比（大 IPA 在设备上可达
    /// 几十到几百毫秒），而用户常在已导入的多个 IPA 之间来回切换 —— 缓存后切换是瞬时的。
    private var ipaInfoCache: [String: (size: UInt64, mtime: Date, bundleId: String, displayName: String, mismatched: [String])] = [:]
    /// 读取序号：连续切换时丢弃过期结果（先发起的一次若后返回，不得覆盖当前选择的信息）。
    private var ipaInfoToken = 0

    /// 文件大小 + 修改时间（判断缓存是否还有效）。只是 stat，很轻，可在主线程调用。
    private static func fileStamp(_ url: URL) -> (size: UInt64, mtime: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = a[.size] as? UInt64,
              let mtime = a[.modificationDate] as? Date else { return nil }
        return (size, mtime)
    }

    /// 把读到的信息写进界面状态（**只在主线程调用**）。
    private func applyIpaInfo(_ info: (bundleId: String, displayName: String, mismatched: [String])) {
        ipaBundleId = info.bundleId
        ipaDisplayName = info.displayName
        ipaExtensionMismatch = info.mismatched
        if !info.mismatched.isEmpty {
            LogStore.shared.append("⚠️ 这个 IPA 自带错配：\(info.mismatched.count) 个扩展的 Bundle ID 与主 App 前缀不符（\(info.mismatched.joined(separator: "、"))）——不改就装不上；可在输入区勾选「同步嵌套扩展 Bundle ID」修复")
        }
    }

    /// 读取当前 IPA 自带信息：**后台线程 + 缓存**，只读、不解包、不改文件。
    ///
    /// 关于「大 IPA」：这一步**不会**读 637 MB 的包体 —— zip 的条目索引集中在中央目录里，
    /// 我们只读索引 + 两个极小的 `Info.plist`（主 App 与扩展），包体一个字节都不解压。
    /// 但索引大小 ∝ 条目数（大包上万条），仍有几十到几百毫秒，所以：
    ///   - 放在后台队列，不阻塞界面；
    ///   - 同一个文件只解析一次，来回切换已导入的 IPA 秒回；
    ///   - 用序号丢弃过期结果，快速连续切换不会串台。
    func refreshIpaInfo() {
        ipaInfoToken += 1
        let token = ipaInfoToken
        guard let url = ipa else {
            ipaBundleId = ""
            ipaDisplayName = ""
            ipaExtensionMismatch = []
            return
        }
        let path = url.path
        let stamp = Self.fileStamp(url)
        // 命中缓存且文件没变 → 直接应用，完全不碰磁盘。
        if let stamp, let c = ipaInfoCache[path], c.size == stamp.size, c.mtime == stamp.mtime {
            applyIpaInfo((bundleId: c.bundleId, displayName: c.displayName, mismatched: c.mismatched))
            return
        }
        // 未命中：先清空，避免把上一个 IPA 的值当成本包的值显示出来。
        ipaBundleId = ""
        ipaDisplayName = ""
        ipaExtensionMismatch = []
        DispatchQueue.global(qos: .utility).async {
            let parsed = Self.parseIpaInfo(RustBridge.shared.ipaInfo(ipa: path))
            DispatchQueue.main.async {
                guard token == self.ipaInfoToken else { return } // 过期结果，丢弃
                if let stamp {
                    self.ipaInfoCache[path] = (size: stamp.size, mtime: stamp.mtime,
                                               bundleId: parsed.bundleId,
                                               displayName: parsed.displayName,
                                               mismatched: parsed.mismatched)
                }
                self.applyIpaInfo(parsed)
            }
        }
    }

    /// 解析 `si_ipa_info` 返回的 JSON（纯函数，可在任意线程调用）。
    private static func parseIpaInfo(_ json: String?) -> (bundleId: String, displayName: String, mismatched: [String]) {
        guard let json, let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ("", "", [])
        }
        return (obj["bundleId"] as? String ?? "",
                obj["displayName"] as? String ?? "",
                obj["extensionMismatch"] as? [String] ?? [])
    }

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
        let skipSign: Bool
    }

    // MARK: - 流程上下文（用于暂停后从失败处续跑 / 取消后清理）
    private struct FlowContext {
        let ipaCopy: URL
        let ipaName: String
        /// 已复制进沙盒的 dylib 与其注入名。
        let dylibs: [(url: URL, name: String)]
        /// 「只注入导出」模式下为空（该模式不需要证书）。
        let p12Copy: URL?
        let provCopy: URL?
        let pairingCopy: URL?
        let tmp: URL
        let outIpa: URL
        let bundleId: String
        let displayName: String
        let certPass: String
        /// 只注入导出：跳过签名，且不触发配对与安装。
        let skipSign: Bool
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
        // 用 CertStore 推导出的可用路径：覆盖安装后数据容器会换 UUID，
        // 索引里记录的旧绝对路径会失效，直接读 cert.p12Path 就会「证书丢了」。
        certP12 = CertStore.shared.p12URL(for: cert)
        profile = CertStore.shared.provURL(for: cert)
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
        if skipSign {
            // 「只注入导出」模式不需要证书，但必须有 dylib：否则产物与原 IPA 一模一样，没有意义。
            guard !dylibs.isEmpty else {
                return failInput("已勾选「跳过签名」：该模式只做注入导出，请先选择要注入的 dylib（否则产物与原 IPA 相同）")
            }
        } else {
            guard certP12 != nil else {
                return failInput("还没有选择证书：请到「库」页签添加证书，再在首页下拉中选择（或勾选「跳过签名」只做注入导出）")
            }
            guard profile != nil else {
                return failInput("所选证书缺少描述文件（mobileprovision），请到「库」页签编辑该证书并重新选择")
            }
            // 覆盖安装会更换数据容器路径，证书文件可能读不到：先明确告知怎么修，别让它到签名阶段才失败。
            if let cert = selectedCert, !CertStore.shared.isUsable(cert) {
                return failInput("所选证书的证书文件已丢失（覆盖安装会更换数据容器路径）：请到「库」页签对该证书点「编辑」重新选择 P12 与描述文件并保存")
            }
        }

        // 2) 立刻给出可见反馈：准备阶段要把 IPA/证书复制进沙盒，大 IPA 会耗时。
        let snap = InputSnapshot(ipa: ipa, dylibs: dylibs,
                                 p12: certP12, prov: profile, pairing: pairingFile,
                                 bundleId: bundleId, displayName: displayName, certPass: certPass,
                                 skipSign: skipSign)
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
        LogStore.shared.append("准备文件：\(ipa.lastPathComponent)"
                               + (skipSign ? "（模式：只注入导出，跳过签名与安装）" : ""))

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
        // 优先**硬链接**、其次移动、最后才复制：选择器给的副本本来就在 App 容器内（同一卷），
        // 链接 / 改名都是瞬时操作、不额外占空间。原来一律 copyItem —— 导入一个几百 MB 的包
        // 会在主线程整份复制一遍（界面卡住 + 存储翻倍）。
        var ok = (try? fm.linkItem(at: url, to: dst)) != nil
        if !ok, (try? fm.moveItem(at: url, to: dst)) != nil {
            ok = true
        }
        if !ok {
            ok = (try? fm.copyItem(at: url, to: dst)) != nil
        }
        if ok {
            // 不再删除上一次导入的 IPA：导入即入库，之后可在下拉里反复选用。
            ipa = dst
            LogStore.shared.append("已导入 IPA（可在下拉中重复选择）：\(url.lastPathComponent)")
            refreshSavedIPAs()
        } else {
            ipa = url
            LogStore.shared.append("IPA 导入持久目录失败，暂用原路径：\(url.lastPathComponent)")
        }
        inputError = nil
    }

    /// 重新扫描持久目录，刷新「已导入 IPA」下拉列表。
    func refreshSavedIPAs() {
        let dir = Self.persistentInputDir()
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                includingPropertiesForKeys: nil)) ?? []
        savedIPAs = urls
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 删除一个已导入的 IPA：从持久目录移除并刷新列表；若它正被选中则清空选择。
    func removeSavedIPA(_ url: URL) {
        if ipa == url { ipa = nil }
        if Self.isOwnedInput(url) {
            try? FileManager.default.removeItem(at: url)
        }
        refreshSavedIPAs()
        LogStore.shared.append("已删除导入的 IPA：\(Self.displayName(for: url))")
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
        // 交给 Storage 统一处理：tmp 下带我们前缀的目录全清（含 si_out_* 解包工作树、
        // si_export_* 导出产物、si_share_* 导出副本）。放后台队列，避免几十 GB 的删除卡住界面。
        DispatchQueue.global(qos: .utility).async {
            let freed = Storage.cleanWorkDirs()
            if freed > 50 * 1024 * 1024 {
                LogStore.shared.append("已清理临时文件 \(Storage.human(freed))")
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
        // 「只注入导出」模式下证书不是必需的；只有要签名时才强制要求 P12 + 描述文件。
        let p12Copy = copyIn(snap.p12, "cert.p12")
        let provCopy = copyIn(snap.prov, "profile.mobileprovision")
        if !snap.skipSign {
            guard p12Copy != nil else {
                failInput("无法读取证书里的 P12 文件：请到「库」页签编辑该证书并重新选择 P12")
                return nil
            }
            guard provCopy != nil else {
                failInput("无法读取证书里的描述文件（mobileprovision）：请到「库」页签编辑该证书并重新选择")
                return nil
            }
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
        // 产物单独放一个目录、并用「原 IPA 名 + 后缀」命名：
        // 分享/保存到「文件」App 时名字才是可读的（原来是 signed_<UUID>.ipa）。
        let exportDir = fm.temporaryDirectory.appendingPathComponent("si_export_\(UUID().uuidString)")
        try? fm.createDirectory(at: exportDir, withIntermediateDirectories: true)
        let stem = (snap.ipa.lastPathComponent as NSString).deletingPathExtension
        let outIpa = exportDir.appendingPathComponent(snap.skipSign
            ? "\(stem)-injected-unsigned.ipa"
            : "\(stem)-signed.ipa")

        return FlowContext(ipaCopy: ipaCopy, ipaName: snap.ipa.lastPathComponent,
                           dylibs: copiedDylibs, p12Copy: p12Copy,
                           provCopy: provCopy, pairingCopy: pairingCopy, tmp: tmp, outIpa: outIpa,
                           bundleId: snap.bundleId, displayName: snap.displayName,
                           certPass: snap.certPass, skipSign: snap.skipSign)
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
                    // 「没改」判定：留空，或与 IPA 自带的当前值**完全相同** → 什么都不写。
                    // 这样即便用户手动填了与当前相同的值，也不会连带触发扩展 ID 同步
                    // （改扩展 ID 属于产物语义变更，只能由显式开关触发）。
                    let original = Self.parseIpaInfo(RustBridge.shared.ipaInfo(ipa: ctx.ipaCopy.path))
                    let bChanged = !b.isEmpty && b != original.bundleId
                    let dChanged = !d.isEmpty && d != original.displayName
                    let sync = self.syncExtensionIDs
                    if !bChanged && !dChanged && !sync {
                        self.markSkipped(2, "未修改 Bundle 信息，跳过")
                    } else {
                        guard let app = self.resolveApp(tmp: ctx.tmp) else {
                            self.pause(at: 2, reason: "未在 Payload 中找到 .app"); return
                        }
                        self.markRunning(2, "修改 Bundle 信息…")
                        if bChanged || dChanged {
                            if r.setBundleInfo(app: app.path,
                                               bundleId: bChanged ? b : "",
                                               displayName: dChanged ? d : "") != 0 {
                                self.pause(at: 2, reason: "修改 Bundle 信息失败"); return
                            }
                        }
                        // 显式修复：把嵌套扩展的 Bundle ID 对齐到主 App（只有勾选开关才会走到这里）。
                        if sync && r.syncExtensionIDs(app: app.path) != 0 {
                            self.pause(at: 2, reason: "同步嵌套扩展 Bundle ID 失败"); return
                        }
                        self.markDone(2)
                    }

                case 3:
                    if ctx.skipSign {
                        self.markSkipped(3, "跳过签名（只注入导出）")
                    } else {
                        guard let app = self.resolveApp(tmp: ctx.tmp) else {
                            self.pause(at: 3, reason: "未在 Payload 中找到 .app"); return
                        }
                        guard let p12 = ctx.p12Copy, let prov = ctx.provCopy else {
                            self.pause(at: 3, reason: "证书文件不可用：请到「库」页签重新选择 P12 与描述文件"); return
                        }
                        self.markRunning(3, "重签…")
                        if r.sign(app: app.path, p12: p12.path, pw: ctx.certPass,
                                  prov: prov.path, team: "") != 0 {
                            self.pause(at: 3, reason: "重签失败：请检查证书/描述文件是否匹配，以及 IPA 是否已砸壳"); return
                        }
                        self.markDone(3)
                    }

                case 4:
                    self.markRunning(4, "打包 IPA…")
                    if r.zip(dir: ctx.tmp.path, out: ctx.outIpa.path) != 0 {
                        self.pause(at: 4, reason: "重新打包失败"); return
                    }
                    DispatchQueue.main.async {
                        guard self.outcome != .idle else { return }
                        self.shareItem = ctx.outIpa
                        // 只入库「已签名」产物：未签名 IPA 装不上设备，
                        // 混进库里会让「点一下即可安装」变成必然失败。
                        if !ctx.skipSign {
                            // 自动入库：即使后面安装失败，也能在「库」里点击直接安装或导出。
                            IPALibrary.shared.add(url: ctx.outIpa, name: ctx.outIpa.lastPathComponent)
                        }
                    }
                    self.markDone(4)

                case 5: // 设备配对（= pairingStage）
                    if ctx.skipSign {
                        // 未签名 IPA 无法安装 → 配对与安装都跳过（不触发任何安装动作）。
                        self.markSkipped(self.pairingStage, "只注入导出，无需配对")
                    } else if self.isPaired {
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
                    if ctx.skipSign {
                        // 关键：只注入导出时**绝不触发安装**。
                        self.markSkipped(self.installStage, "只注入导出，不安装")
                        break
                    }
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
            self.finishSuccess(ctx.skipSign
                ? "已完成：已生成未签名 IPA（点「导出」保存到「文件」App）"
                : "已完成：安装成功")
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
    private func finishSuccess(_ message: String = "已完成：安装成功") {
        DispatchQueue.main.async {
            guard self.outcome != .idle else { return }
            self.progress = 1
            self.stageIndex = max(0, self.stepCount - 1)
            self.outcome = .done
            self.pauseReason = nil
            self.status = message
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
