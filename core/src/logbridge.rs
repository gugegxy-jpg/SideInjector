//! 把 apple-codesign / apple-bundles 内部的 `log` 输出转发到 App 日志。
//!
//! 为什么需要：这两个库抛出的 IO 错误**不携带路径**（只会是
//! `I/O error: No such file or directory (os error 2)`），单靠错误串无法定位
//! 是哪个 bundle / 哪个文件出问题。打开它们的日志后，就能看到
//! `signing main executable …`、`writing Mach-O to …`、`writing sealed resources to …`
//! 之类的进度，从而知道它死在什么地方。

use crate::log_msg;
use log::{LevelFilter, Log, Metadata, Record};
use std::sync::Once;

struct Bridge;

impl Log for Bridge {
    fn enabled(&self, _metadata: &Metadata) -> bool {
        true
    }

    fn log(&self, record: &Record) {
        // 只放行 Error/Warn/Info/Debug；Trace 量过大，容易把 App 日志冲爆。
        if record.level() <= log::Level::Debug {
            log_msg(&format!("[{}] {}", record.target(), record.args()));
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
