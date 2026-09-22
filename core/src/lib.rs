//! SideInjector Rust core —— 通过 FFI 暴露给 SwiftUI App 调用。
//!
//! 四大能力：
//!   1. si_unzip_ipa  —— 解 IPA（zip）到目录
//!   2. si_inject_dylib —— 往主二进制插入 LC_LOAD_DYLIB（用 constructor 自动执行的 dylib）
//!   3. si_sign_bundle —— 用导入的开发证书重签整个 .app
//!   4. si_zip_ipa    —— 把 .app 目录重新打包成 IPA
//!   5. si_install_ipa —— 设备端安装（依赖 SideInstaller rust-core 的 CoreDevice 传输，见 install.rs）
//!
//! 所有函数返回 0 表示成功，-1 表示失败；失败原因通过日志回调吐出。

mod inject;
mod sign;
mod install;
mod ziputil;
mod pair;

use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};

type LogCb = extern "C" fn(*const c_char);
static mut LOG_CB: Option<LogCb> = None;

/// 跨模块日志：若有 Swift 注册的回调则转发，否则静默。
pub(crate) fn log_msg(msg: &str) {
    unsafe {
        if let Some(cb) = LOG_CB {
            if let Ok(c) = CString::new(msg) {
                cb(c.as_ptr());
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn si_set_log_callback(cb: LogCb) {
    unsafe { LOG_CB = Some(cb); }
}

fn to_str(p: *const c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p).to_str().ok().map(|s| s.to_string()) }
}

#[no_mangle]
pub extern "C" fn si_unzip_ipa(ipa: *const c_char, out: *const c_char) -> c_int {
    let (Some(ipa), Some(out)) = (to_str(ipa), to_str(out)) else {
        log_msg("si_unzip_ipa: null argument");
        return -1;
    };
    match ziputil::unzip(std::path::Path::new(&ipa), std::path::Path::new(&out)) {
        Ok(_) => 0,
        Err(e) => {
            log_msg(&format!("unzip error: {e}"));
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn si_inject_dylib(
    app: *const c_char,
    dylib_src: *const c_char,
    dylib_name: *const c_char,
) -> c_int {
    let (Some(app), Some(src), Some(name)) =
        (to_str(app), to_str(dylib_src), to_str(dylib_name))
    else {
        log_msg("si_inject_dylib: null argument");
        return -1;
    };
    match inject::inject_dylib(
        std::path::Path::new(&app),
        std::path::Path::new(&src),
        &name,
    ) {
        Ok(_) => 0,
        Err(e) => {
            log_msg(&format!("inject error: {e}"));
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn si_sign_bundle(
    app: *const c_char,
    p12: *const c_char,
    p12_password: *const c_char,
    prov: *const c_char,
    team_id: *const c_char,
) -> c_int {
    let app = match to_str(app) {
        Some(s) => s,
        None => {
            log_msg("si_sign_bundle: null app path");
            return -1;
        }
    };
    let p12 = to_str(p12);
    let pw = to_str(p12_password).unwrap_or_default();
    let prov = to_str(prov);
    let team = to_str(team_id);
    match sign::sign_bundle(
        std::path::Path::new(&app),
        p12.as_deref(),
        &pw,
        prov.as_deref(),
        team.as_deref(),
    ) {
        Ok(_) => 0,
        Err(e) => {
            log_msg(&format!("sign error: {e}"));
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn si_zip_ipa(dir: *const c_char, out: *const c_char) -> c_int {
    let (Some(dir), Some(out)) = (to_str(dir), to_str(out)) else {
        log_msg("si_zip_ipa: null argument");
        return -1;
    };
    match ziputil::zip_dir(std::path::Path::new(&dir), std::path::Path::new(&out)) {
        Ok(_) => 0,
        Err(e) => {
            log_msg(&format!("zip error: {e}"));
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn si_install_ipa(ipa: *const c_char) -> c_int {
    let Some(ipa) = to_str(ipa) else {
        log_msg("si_install_ipa: null path");
        return -1;
    };
    match install::install_ipa(std::path::Path::new(&ipa)) {
        Ok(_) => 0,
        Err(e) => {
            log_msg(&format!("install error: {e}"));
            -1
        }
    }
}

/// 释放由 core 分配并返回给 Swift 的 C 字符串。
#[no_mangle]
pub extern "C" fn si_string_free(p: *mut c_char) {
    if !p.is_null() {
        unsafe { drop(CString::from_raw(p)); }
    }
}
