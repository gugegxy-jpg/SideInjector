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

use crate::log_msg;
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
        if record.level() <= log::Level::Debug {
            let msg = record.args().to_string();
            note(&msg);
            log_msg(&format!("[{}] {msg}", record.target()));
        }
    }

    fn flush(&self) {}
}

static BRIDGE: Bridge = Bridge;
static INIT: Once = Once::new();

/// 幂等初始化全局日志器（多次调用只生效一次）。
pub fn init() {
    INIT.call_once(|| {
        let _ = log::set_logger(&BRIDGE);
        log::set_max_level(LevelFilter::Debug);
    });
}
