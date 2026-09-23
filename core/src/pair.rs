//! 设备端自配对（Remote Pairing）：在 App 本进程内起 TCP 服务，
//! 设备（iOS 27+ 开发者模式）通过 Bonjour 发现本机并连入完成配对，
//! 产出 RpPairingFile（无需 Mac）。
//!
//! 代码出处（开源署名）：
//!   协议实现：`idevice` crate 的 `remote_pairing` —— https://github.com/jkcoxson/idevice
//!          许可：MIT（Copyright © Jackson Coxson）。
//!   参考实现：FrizzleM/SideInstaller —— https://github.com/FrizzleM/SideInstaller
//!          对应文件：rust-core/src/pairing.rs
//!          许可：SideInstaller License（Copyright © 2026 FrizzleM）——
//!                允许使用 / 修改 / 以源码形式再分发（须署名 "SideInstaller by FrizzleM"、
//!                附该许可并标明所做修改）；禁止商业使用；禁止再分发其官方构建 / IPA。
//!   本文件改动：主机启停与状态上报改为「后台线程 + 全局状态 + Swift 轮询」模型
//!          （si_pairing_start / _status / _port / _pin / _error …），并补了机型标识与错误上报。
//!
//! 采用「后台线程 + 全局状态 + Swift 轮询」的模型（避免 C 函数指针回调的复杂度）：
//!   - si_pairing_start  启动配对线程
//!   - si_pairing_status / _port / _identifier / _txt_json / _pin / _name / _error 供轮询

use crate::log_msg;
use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use std::ffi::{c_char, c_int, CStr, CString};
use std::sync::Mutex;

struct PairState {
    status: c_int, // 0=配对中, 1=成功, -1=失败
    service_port: u16,
    service_identifier: Option<String>,
    txt_records_json: Option<String>,
    pin: Option<String>,
    device_name: Option<String>,
    error: Option<String>,
}

static PAIR_STATE: Mutex<Option<PairState>> = Mutex::new(None);

fn with_state<R>(f: impl FnOnce(&PairState) -> R) -> Option<R> {
    PAIR_STATE.lock().ok().and_then(|g| g.as_ref().map(f))
}

fn mutate_state(f: impl FnOnce(&mut PairState)) {
    if let Ok(mut g) = PAIR_STATE.lock() {
        if let Some(s) = g.as_mut() {
            f(s);
        }
    }
}

fn cstr_ptr(s: Option<String>) -> *mut c_char {
    match s {
        Some(s) => CString::new(s).map(|c| c.into_raw()).unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
}

fn input_str(p: *const c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(p).to_string_lossy().into_owned() }
    }
}

/// 启动自配对（后台线程）。返回 0 表示已启动，-1 表示状态锁异常。
#[no_mangle]
pub extern "C" fn si_pairing_start(out_path: *const c_char) -> c_int {
    let out_path = input_str(out_path);
    let out_path = if out_path.is_empty() {
        "rp_pairing.plist".to_string()
    } else {
        out_path
    };

    {
        let mut g = match PAIR_STATE.lock() {
            Ok(g) => g,
            Err(_) => return -1,
        };
        *g = Some(PairState {
            status: 0,
            service_port: 0,
            service_identifier: None,
            txt_records_json: None,
            pin: None,
            device_name: None,
            error: None,
        });
    }

    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build();
        let rt = match rt {
            Ok(rt) => rt,
            Err(e) => {
                mutate_state(|s| {
                    s.status = -1;
                    s.error = Some(format!("tokio 运行时创建失败: {e}"));
                });
                return;
            }
        };
        match rt.block_on(run_pair(out_path)) {
            Ok(name) => mutate_state(|s| {
                s.status = 1;
                s.device_name = Some(name);
            }),
            Err(e) => mutate_state(|s| {
                s.status = -1;
                s.error = Some(e);
            }),
        }
    });
    0
}

async fn run_pair(out_path: String) -> Result<String, String> {
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};
    use tokio::net::TcpListener;

    let name = "SideInjector".to_string();
    // 机型标识与参考实现（SideInstaller）一致用 Mac 机型：其「设置 → 开发者 → 配对」
    // 是按可配对主机（Mac）列举的，给一个真实 Mac 机型标识更稳妥。
    let model = "Mac17,7".to_string();

    // 复用已有配对文件（保留 host 密钥）；否则生成新的
    let mut pairing_file = match RpPairingFile::read_from_file(&out_path).await {
        Ok(mut f) => {
            f.alt_irk = None;
            f
        }
        Err(_) => RpPairingFile::generate(&name),
    };

    let host_info = PairableHostInfo::generate(&name, &model);
    let service_identifier = pairing_file.identifier().to_string();

    // mDNS TXT 记录，供 Swift 用 Bonjour 广播（设备借此发现/识别本机）
    let txt: Vec<(String, String)> = host_info.mdns_txt_records(&service_identifier);
    let txt_json = serde_json::to_string(&txt).unwrap_or_else(|_| "[]".to_string());

    let listener = TcpListener::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0))
        .await
        .map_err(|e| format!("绑定监听失败: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("取本地端口失败: {e}"))?
        .port();

    log_msg(&format!("自配对：监听端口 {port}，服务 {service_identifier}"));
    mutate_state(|s| {
        s.service_port = port;
        s.service_identifier = Some(service_identifier.clone());
        s.txt_records_json = Some(txt_json);
    });

    let (stream, peer) = listener
        .accept()
        .await
        .map_err(|e| format!("等待设备连接失败: {e}"))?;
    log_msg(&format!("自配对：设备已连接（{peer}）"));

    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);

    let peer_dev = host
        .accept(&mut pairing_file, |pin| async move {
            log_msg(&format!("自配对：请在设备上输入 PIN {pin}"));
            mutate_state(|s| s.pin = Some(pin));
        })
        .await
        .map_err(|e| format!("配对失败: {e}"))?;

    pairing_file
        .write_to_file(&out_path)
        .await
        .map_err(|e| format!("写配对文件失败: {e}"))?;
    log_msg(&format!("自配对完成：{} ({})", peer_dev.name, peer_dev.model));
    Ok(peer_dev.name)
}

#[no_mangle]
pub extern "C" fn si_pairing_status() -> c_int {
    with_state(|s| s.status).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn si_pairing_service_port() -> c_int {
    with_state(|s| s.service_port as c_int).unwrap_or(0)
}

#[no_mangle]
pub extern "C" fn si_pairing_service_identifier() -> *mut c_char {
    cstr_ptr(with_state(|s| s.service_identifier.clone()).flatten())
}

#[no_mangle]
pub extern "C" fn si_pairing_txt_json() -> *mut c_char {
    cstr_ptr(with_state(|s| s.txt_records_json.clone()).flatten())
}

#[no_mangle]
pub extern "C" fn si_pairing_pin() -> *mut c_char {
    cstr_ptr(with_state(|s| s.pin.clone()).flatten())
}

#[no_mangle]
pub extern "C" fn si_pairing_device_name() -> *mut c_char {
    cstr_ptr(with_state(|s| s.device_name.clone()).flatten())
}

#[no_mangle]
pub extern "C" fn si_pairing_error() -> *mut c_char {
    cstr_ptr(with_state(|s| s.error.clone()).flatten())
}
