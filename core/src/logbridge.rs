//! 把 apple-codesign / apple-bundles 内部的 `log` 输出转发到 App 日志。
//!
//! 为什么需要：这两个库抛出的 IO 错误**不携带路径**（只会是
//! `I/O error: No such file or directory (os error 2)`），单靠错误串无法定位
//! 是哪个 bundle / 哪个文件出问题。打开它们的日志后，就能看到
//! `entering nested bundle …`、`copying file …`、`writing sealed resources to …`
//! 之类的进度，从而知道它死在什么地方。
//!
//! 代码出处（开源署名）：桥接对象为 apple-codesign / apple-bundles
//!   —— https://github.com/indygreg/apple-platform-rs ，许可 MPL-2.0。
//!   本文件是本项目自有的 `log::Log` 实现（转发到 App 日志），未使用该仓库的代码。

// 本文件里转发的一切（apple-codesign / apple-bundles 内部过程、idevice 的 tracing）
// 都属于「细节日志」：只进后台日志文件，界面不显示 —— 它们逐条打印，量极大。
use crate::log_detail as log_msg;
use log::{LevelFilter, Log, Metadata, Record};
use std::sync::{Mutex, Once};

static LAST_BUNDLE: Mutex<Option<String>> = Mutex::new(None);

/// 记下「最后进入的嵌套 bundle」——签名失败时它就是嫌疑对象。
fn note(msg: &str) {
    if let Some(rest) = msg.strip_prefix("entering nested bundle ") {
        if let Ok(mut g) = LAST_BUNDLE.lock() {
            *g = Some(rest.to_string());
        }
    }
}

/// 最后一次「entering nested bundle X」里的 X。
pub fn last_bundle() -> Option<String> {
    LAST_BUNDLE.lock().ok().and_then(|g| g.clone())
}

struct Bridge;

impl Log for Bridge {
    fn enabled(&self, _metadata: &Metadata) -> bool {
        true
    }

    fn log(&self, record: &Record) {
        // 只放行 Error/Warn/Info/Debug；Trace 量过大，容易把 App 日志冲爆。
        if record.level() > log::Level::Debug {
            return;
        }
        let target = record.target();
        // 两个纯噪声源（都只在下游 Warn/Error 时才有价值）：
        //   goblin                        —— 把每个 Mach-O 的**每条 load command** 都打出来，
        //                                    一轮签名能上万行、每行上百字符；
        //   apple_codesign::code_resources —— 逐文件打印正则规则匹配结果。
        // 它们会把 App 日志冲爆（上万次跨 FFI + 主线程刷新 → 界面卡死），
        // 而真正有用的进度信息来自我们自己打的日志与 macho_signing/bundle_signing。
        if record.level() > log::Level::Warn
            && (target.starts_with("goblin") || target.starts_with("apple_codesign::code_resources"))
        {
            return;
        }
        let msg = record.args().to_string();
        // 第三个噪声源：bundle_signing 的**逐文件**进度（`copying file …`）。
        // 一轮签名能打几千到上万行（跨 FFI 转发 + 落盘 + 界面刷新都要吃一遍），而它只在
        // 「签名中途失败」时才有参考价值 —— 那种情况已由我们自己的
        // 「签名中断：输出目录已产出文件 …」覆盖。这里只按**消息内容**筛，
        // `entering nested bundle …` 必须保留（失败时要靠 last_bundle() 指认嫌疑对象）。
        if record.level() >= log::Level::Info
            && target.starts_with("apple_codesign::bundle_signing")
            && (msg.starts_with("copying file") || msg.starts_with("copying directory"))
        {
            return;
        }
        note(&msg);
        log_msg(&format!("[{target}] {msg}"));
    }

    fn flush(&self) {}
}

static BRIDGE: Bridge = Bridge;
static INIT: Once = Once::new();

/// 把 idevice 内部的 `tracing` 事件写进 App 日志。
///
/// 为什么必须接：idevice 用的是 `tracing`，而上面的桥只接了 `log`。
/// 例如 `RsdHandshake` 解析服务表时，对「缺 Entitlement」或「Port 不是字符串」的服务
/// 是 `warn!` + **跳过该服务** —— 不接 tracing 就完全看不到「服务被丢弃」这件事。
struct TracingWriter;

impl std::io::Write for TracingWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let text = String::from_utf8_lossy(buf);
        let trimmed = text.trim_end();
        if !trimmed.is_empty() {
            for line in trimmed.lines() {
                log_msg(&format!("[tracing] {line}"));
            }
        }
        Ok(buf.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

struct TracingMakeWriter;

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for TracingMakeWriter {
    type Writer = TracingWriter;

    fn make_writer(&'a self) -> Self::Writer {
        TracingWriter
    }
}

/// 幂等初始化全局日志器（多次调用只生效一次）。
pub fn init() {
    INIT.call_once(|| {
        let _ = log::set_logger(&BRIDGE);
        log::set_max_level(LevelFilter::Debug);
        // tracing：只放行 INFO/WARN/ERROR（Debug/Trace 量太大，会把 App 日志冲爆）。
        let _ = tracing_subscriber::fmt()
            .with_writer(TracingMakeWriter)
            .with_max_level(tracing::Level::INFO)
            .with_ansi(false)
            .without_time()
            .try_init();
    });
}
