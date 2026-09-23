import SwiftUI
import Combine
import UIKit

/// App 日志。
///
/// 两级：
///   - **重要日志**（`append`）：阶段切换、汇总、自检、错误 —— 显示在界面日志卡片上；
///   - **细节日志**（`appendDetail`）：逐项进度、上游库（apple-codesign / goblin / idevice）
///     的内部输出、诊断细节 —— **只写后台日志文件**，界面不显示。
/// 两级都会按顺序写进 `Application Support/Logs/sideinjector.log`，可查看 / 导出 / 清理。
///
/// 性能（决定了签名时界面卡不卡）：
///   1. 任意线程只往内存缓冲 push；
///   2. 主线程定时器每 0.2 秒**合并提交一次**（以前是每行一次跨 FFI + 一次主线程刷新）；
///   3. 落盘在后台串行队列做；
///   4. 界面只渲染重要日志的末尾若干行（以前把几 MB 全文交给 `Text` 排版）。
final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// 界面只保留末尾这么多行重要日志。
    static let visibleLines = 200
    /// 日志文件超过这个大小就轮转（旧的保留一份 `sideinjector.1.log`）。
    private static let maxFileBytes: Int64 = 4 * 1024 * 1024

    /// 重要日志全文（「查看全部 → 复制」用）。
    @Published private(set) var text: String = ""
    /// 界面渲染用：重要日志的末尾若干行。
    @Published private(set) var tail: String = ""

    /// 后台日志文件（两级日志都在里面）。
    let fileURL: URL

    private let lock = NSLock()
    private var pending: [(line: String, important: Bool)] = []
    private var tailLines: [String] = []
    private let flushInterval: TimeInterval = 0.2
    private var timer: DispatchSourceTimer?
    private let ioQueue = DispatchQueue(label: "com.sideinjector.logfile", qos: .utility)

    private init() {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("sideinjector.log")

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + flushInterval,
                   repeating: flushInterval,
                   leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t

        append("———— \(Date().formatted(date: .numeric, time: .standard)) ————")
    }

    // MARK: - 写入

    /// 重要日志（界面显示）。可从任意线程调用 —— 签名时就是 Rust 的日志回调在调。
    func append(_ s: String) { enqueue(s, important: true) }

    /// 细节日志（只进后台日志文件，界面不显示）。
    func appendDetail(_ s: String) { enqueue(s, important: false) }

    private func enqueue(_ s: String, important: Bool) {
        lock.lock()
        pending.append((s, important))
        lock.unlock()
    }

    /// 清空日志（界面内存 + 后台日志文件）。
    func clear() {
        lock.lock()
        pending.removeAll()
        tailLines.removeAll()
        lock.unlock()
        text = ""
        tail = ""
        let url = fileURL
        let old = url.deletingLastPathComponent().appendingPathComponent("sideinjector.1.log")
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: - 读取 / 导出

    /// 日志文件字节数。
    var fileBytes: Int64 { Self.fileSize(of: fileURL) }
    /// 日志文件大小（人类可读）。
    var fileSizeText: String { Storage.human(fileBytes) }

    /// 读出完整日志（查看 / 导出用）；回调在主线程。
    func loadAll(_ done: @escaping (String) -> Void) {
        let url = fileURL
        ioQueue.async {
            let s = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            DispatchQueue.main.async { done(s) }
        }
    }

    // MARK: - 提交（主线程定时器）

    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !batch.isEmpty else { return }

        // 1) 两级日志都按顺序落盘（后台队列）
        let url = fileURL
        let lines = batch.map { $0.line }
        ioQueue.async { Self.write(lines, to: url) }

        // 2) 只有重要日志进界面
        let important = batch.filter { $0.important }.map { $0.line }
        guard !important.isEmpty else { return }
        text += important.joined(separator: "\n") + "\n"
        tailLines.append(contentsOf: important)
        if tailLines.count > Self.visibleLines {
            tailLines.removeFirst(tailLines.count - Self.visibleLines)
        }
        tail = tailLines.joined(separator: "\n")
    }

    // MARK: - 文件读写

    private static func fileSize(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 追加写入（必要时先轮转）。只在 ioQueue 上调用。
    private static func write(_ lines: [String], to url: URL) {
        guard let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        let fm = FileManager.default
        if fileSize(of: url) > maxFileBytes {
            let old = url.deletingLastPathComponent().appendingPathComponent("sideinjector.1.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// 日志卡片。
///
/// 单独成一个 view 是刻意的：它自己观察 `LogStore`，于是每批日志只重绘**这张卡片**，
/// 不会把整个首页（渐变、模糊卡片、列表…）重建一遍。
/// 卡片上只显示**重要日志**的末尾若干行；完整日志（含细节）在后台文件里。
struct LogCard: View {
    @ObservedObject private var log = LogStore.shared
    @State private var showAll = false
    @State private var shareURL: URL?
    @State private var confirmClear = false

    var body: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label {
                        Text("日志").font(.headline)
                    } icon: {
                        Image(systemName: "doc.plaintext").foregroundStyle(Theme.brand)
                    }
                    Spacer(minLength: 8)
                    Button {
                        showAll = true
                    } label: {
                        Label("查看全部", systemImage: "doc.text.magnifyingglass")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    Button {
                        shareURL = log.fileURL
                    } label: {
                        Label("导出", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(log.fileBytes == 0)
                    Button {
                        confirmClear = true
                    } label: {
                        Label("清空", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }

                ScrollView {
                    Text(log.tail)
                        .font(.system(.caption, design: .monospaced))
                        // 长按可直接选择/复制任意片段
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 300)
                .scrollIndicators(.hidden)

                if log.text.isEmpty {
                    Text("尚无日志。详细日志会写进后台日志文件（可「查看全部」或「导出」）。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("界面只显示重要日志的末尾 \(LogStore.visibleLines) 行 · 完整日志 \(log.fileSizeText)"
                         + "（含细节）在后台文件里，可「查看全部」/「导出」")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $showAll) { LogViewer() }
        .sheet(isPresented: shareShown) {
            if let shareURL { ShareSheet(activityItems: [shareURL]) }
        }
        .confirmationDialog("清空日志？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { log.clear() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会清掉界面上的重要日志与后台日志文件（含细节日志），不影响证书、IPA 库与导入的文件。")
        }
    }

    private var shareShown: Binding<Bool> {
        Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })
    }
}

/// 完整日志查看（含细节日志）：打开时从日志文件读一次快照，之后不随日志变化重排。
struct LogViewer: View {
    @ObservedObject private var log = LogStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var content: String?
    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if let content {
                    ScrollView {
                        Text(content.isEmpty ? "（日志文件为空）" : content)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    ProgressView("读取日志…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("完整日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = content ?? ""
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled((content ?? "").isEmpty)
                    Button {
                        shareURL = log.fileURL
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(log.fileBytes == 0)
                }
            }
        }
        .onAppear { log.loadAll { content = $0 } }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let shareURL { ShareSheet(activityItems: [shareURL]) }
        }
    }
}
