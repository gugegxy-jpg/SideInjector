import SwiftUI
import Combine
import UIKit

/// App 日志的缓冲与发布。
///
/// 为什么要批处理：签名时 Rust 侧会**逐行**回调（一轮流程可到上万行）。如果每行都
/// `DispatchQueue.main.async` 再改一次 `@Published`，就是上万次主线程切换 +
/// 上万次 SwiftUI 重绘 —— 界面必然卡死（签名时「整个 App 很卡」的主因之一）。
/// 现在改成：任意线程把行写进缓冲，主线程定时器每 0.2 秒**合并提交一次**。
///
/// 另外界面只渲染末尾 `visibleLines` 行（`tail`）：全文动辄几 MB，整段交给 `Text`
/// 会让每次刷新都重排几 MB 文本；「复制」按钮拿到的仍是全文（`text`）。
final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// 界面只保留末尾这么多行。
    static let visibleLines = 200

    /// 全文（「复制」按钮拿到的就是它）。
    @Published private(set) var text: String = ""
    /// 只给界面渲染的末尾若干行。
    @Published private(set) var tail: String = ""

    private let lock = NSLock()
    private var pending: [String] = []
    private var tailLines: [String] = []
    private let flushInterval: TimeInterval = 0.2
    private var timer: DispatchSourceTimer?

    private init() {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + flushInterval,
                   repeating: flushInterval,
                   leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
    }

    /// 追加一行日志（可从任意线程调用；签名时就是 Rust 的日志回调在调）。
    func append(_ s: String) {
        lock.lock()
        pending.append(s)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        pending.removeAll()
        tailLines.removeAll()
        lock.unlock()
        text = ""
        tail = ""
    }

    /// 把缓冲合并成一次提交（只在主线程定时器里跑，因此可以直接写 `@Published`）。
    private func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !batch.isEmpty else { return }

        // 全文只追加一次（避免逐行 `text +=` 带来的重复分配）。
        text += batch.joined(separator: "\n") + "\n"

        tailLines.append(contentsOf: batch)
        if tailLines.count > Self.visibleLines {
            tailLines.removeFirst(tailLines.count - Self.visibleLines)
        }
        tail = tailLines.joined(separator: "\n")
    }
}

/// 日志卡片。
///
/// 单独成一个 view 是刻意的：它自己观察 `LogStore`，于是每批日志只重绘**这张卡片**，
/// 不会把整个首页（渐变、模糊卡片、列表…）重建一遍。
struct LogCard: View {
    @ObservedObject private var log = LogStore.shared

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
                        UIPasteboard.general.string = log.text   // 始终复制全文
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(log.text.isEmpty)
                    Button {
                        log.clear()
                    } label: {
                        Label("清空", systemImage: "trash")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(log.text.isEmpty)
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
                    Text("尚无日志。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("界面只显示末尾 \(LogStore.visibleLines) 行；点「复制」得到的是完整日志。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
