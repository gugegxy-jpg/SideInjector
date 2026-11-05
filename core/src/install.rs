//! 设备端安装 —— 走 CoreDevice / RSD 路径（iOS 17+ 的本机安装通道）。
//!
//! 为什么不是经典 lockdownd：
//!   实测（App 内端口探测）在设备自身只能连上 **RSD 49152**，而 lockdownd 62078 /
//!   usbmuxd 27015 在 127.0.0.1、VPN 地址（10.7.0.0）、WiFi 地址上全部超时。
//!   也就是说 iOS 17+ 的设备端安装只有 RSD 这一条路。
//!
//! 代码出处（开源署名）：协议实现全部来自 `idevice` crate
//!   —— https://github.com/jkcoxson/idevice （MIT，Copyright © Jackson Coxson）。
//!   本文件未使用 SideInstaller 的代码（安装链路的实现已由 `idevice` 提供）。
//!
//! 链路：
//!   TcpStream::connect(127.0.0.1:49152)
//!     → RsdHandshake::new(stream)                      握手，拿到服务表（含各服务端口）
//!     → IpAddr 作为 RsdProvider（其 connect_to_service_port 就是普通 TCP）
//!         ├─ com.apple.afc                  上传 IPA 到 /PublicStaging
//!         └─ com.apple.mobile.installation_proxy   Install（PackageType=Developer）
//!
//! 进度：installation_proxy 会回百分比，这里写进 INSTALL_PERCENT，Swift 侧轮询。

use crate::log_msg;
use anyhow::{bail, Context, Result};
use idevice::services::installation_proxy::InstallationProxyClient;
use idevice::services::rsd::RsdHandshake;
use idevice::utils::installation::install_package_with_callback_rsd;
use idevice::{IdeviceService as _, RsdService as _};
use std::net::{IpAddr, Ipv4Addr};
use std::path::Path;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tokio::net::TcpStream;

/// RSD（RemoteServiceDiscovery / remoted）端口。
pub const RSD_PORT: u16 = 49152;

/// 安装进度：-1=未开始，0..100=进行中，100=完成。
static INSTALL_PERCENT: AtomicI32 = AtomicI32::new(-1);

/// 供 Swift 轮询的进度值。
pub fn install_percent() -> i32 {
    INSTALL_PERCENT.load(Ordering::Relaxed)
}

fn set_percent(v: i32) {
    INSTALL_PERCENT.store(v, Ordering::Relaxed);
}

/// 安装策略只对本次请求生效；默认遇到冲突即返回，等待界面明确选择。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InstallPolicy {
    Ask,
    Overwrite,
    Reinstall,
}

impl InstallPolicy {
    pub fn from_raw(value: i32) -> Result<Self> {
        match value {
            0 => Ok(Self::Ask),
            1 => Ok(Self::Overwrite),
            2 => Ok(Self::Reinstall),
            _ => bail!("无效的安装策略"),
        }
    }
}

#[derive(Debug)]
struct InstallConflict(serde_json::Value);

impl std::fmt::Display for InstallConflict {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("设备上已有相同 Bundle ID 的 App，请选择安装方式")
    }
}

impl std::error::Error for InstallConflict {}

// 与全局进度一样一次只允许一个安装请求；结果在下一次请求开始前保持可读。
static INSTALL_LOCK: Mutex<()> = Mutex::new(());
static INSTALL_RESULT: Mutex<Option<String>> = Mutex::new(None);

pub fn result_json() -> Option<String> {
    INSTALL_RESULT.lock().unwrap().clone()
}

pub(crate) struct InstallRequest {
    target: String,
    own_bundle_id: String,
    policy: InstallPolicy,
    uninstall_started: bool,
    uninstalled: bool,
}

impl InstallRequest {
    fn can_reinstall(&self, kind: &str) -> bool {
        !self.own_bundle_id.is_empty()
            && self.target != self.own_bundle_id
            && kind != "System"
    }
}

/// 三条安装通路共用预检。查询失败不能当作「未安装」，更不能跳过确认。
pub(crate) async fn prepare_install(
    client: &mut InstallationProxyClient,
    request: &mut InstallRequest,
) -> Result<()> {
    let apps = tokio::time::timeout(
        Duration::from_secs(30),
        client.get_apps(Some("Any"), Some(vec![request.target.clone()])),
    )
    .await
    .context("查询已安装应用超时，未执行安装或卸载")?
    .context("查询已安装应用失败，未执行安装或卸载")?;
    let Some(info) = apps.get(&request.target) else {
        log_msg(&format!("install: 预检：{} 未安装，执行全新安装", request.target));
        return Ok(());
    };
    let info = info.as_dictionary().context("已安装应用信息格式无效")?;
    let text = |key: &str| info.get(key).and_then(plist::Value::as_string).unwrap_or("");
    let kind = text("ApplicationType");
    let can_reinstall = request.can_reinstall(kind);
    let name = match text("CFBundleDisplayName") {
        "" => text("CFBundleName"),
        name => name,
    };
    log_msg(&format!("install: 预检：设备上已有 {}（{}）", request.target, name));
    match request.policy {
        InstallPolicy::Ask => {
            return Err(InstallConflict(serde_json::json!({
                "bundleId": request.target,
                "displayName": name,
                "version": text("CFBundleShortVersionString"),
                "canReinstall": can_reinstall,
                "restriction": if request.target == request.own_bundle_id {
                    "这是正在运行的 SideInjector，卸载会中断流程，仅允许覆盖安装。"
                } else if kind == "System" {
                    "系统应用不支持由本工具卸载重装。"
                } else if request.own_bundle_id.is_empty() {
                    "无法确认当前工具的 Bundle ID，已禁用卸载以保护安装流程。"
                } else { "" },
            })).into());
        }
        InstallPolicy::Overwrite => {
            log_msg("install: 用户选择覆盖安装（不卸载原 App；签名不兼容时交由 iOS 拒绝）");
            return Ok(());
        }
        InstallPolicy::Reinstall if !can_reinstall => {
            bail!("禁止卸载当前工具或系统应用，请选择覆盖安装");
        }
        InstallPolicy::Reinstall => {}
    }

    // 一旦提交卸载，即使响应丢失也不允许切换通路重试破坏性操作。
    request.uninstall_started = true;
    set_percent(-2);
    log_msg(&format!("install: 用户确认卸载重装，正在卸载 {}（应用数据将被清除）", request.target));
    tokio::time::timeout(Duration::from_secs(120), uninstall_app(client, &request.target))
        .await
        .context("卸载超时，设备状态不确定；已停止安装，请检查设备后重试")??;
    request.uninstalled = true;
    set_percent(0);
    log_msg("install: 原 App 已卸载，开始重新安装；原有数据无法恢复");
    Ok(())
}

/// 必须收到 Complete 才视为卸载成功；只有 Error 而无描述的响应也必须失败。
async fn uninstall_app(client: &mut InstallationProxyClient, target: &str) -> Result<()> {
    // 公开接口内部检查 Error / ErrorDescription，并等待 Status == Complete。
    // 底层 plist 收发属于库的私有方法，不能在 crate 外调用。
    client.uninstall(target, None).await.context("卸载应用失败")

}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(target: &str, own: &str) -> InstallRequest {
        InstallRequest {
            target: target.into(), own_bundle_id: own.into(),
            policy: InstallPolicy::Ask, uninstall_started: false, uninstalled: false,
        }
    }

    #[test]
    fn policy_values_match_swift() {
        assert_eq!(InstallPolicy::from_raw(0).unwrap(), InstallPolicy::Ask);
        assert_eq!(InstallPolicy::from_raw(1).unwrap(), InstallPolicy::Overwrite);
        assert_eq!(InstallPolicy::from_raw(2).unwrap(), InstallPolicy::Reinstall);
        assert!(InstallPolicy::from_raw(-1).is_err());
        assert!(InstallPolicy::from_raw(3).is_err());
    }

    #[test]
    fn protects_running_app_even_after_bundle_id_change() {
        assert!(!request("custom.installer", "custom.installer").can_reinstall("User"));
        assert!(request("custom.target", "custom.installer").can_reinstall("User"));
    }

    #[test]
    fn protects_system_apps_and_unknown_installer_identity() {
        assert!(!request("com.apple.target", "custom.installer").can_reinstall("System"));
        assert!(!request("custom.target", "").can_reinstall("User"));
    }

    #[test]
    fn conflict_survives_error_context_for_route_short_circuit() {
        let error = anyhow::Error::new(InstallConflict(serde_json::json!({"bundleId": "custom.target"})))
            .context("安装预检");
        assert!(error.is::<InstallConflict>());
        assert_eq!(error.downcast_ref::<InstallConflict>().unwrap().0["bundleId"], "custom.target");
    }
}

/// 设备端安装：把已签名的 IPA 装到本机。
///
/// 这是阻塞调用（内部自建 tokio 运行时），由 Swift 侧放到后台线程执行，
/// 进度通过 [`install_percent`] 轮询。
pub fn install_ipa(
    ipa: &Path,
    pairing: Option<&Path>,
    policy: InstallPolicy,
    own_bundle_id: &str,
    expected_bundle_id: &str,
) -> i32 {
    let Ok(_guard) = INSTALL_LOCK.try_lock() else {
        log_msg("install: 已有安装请求正在执行，拒绝并发安装");
        return -1;
    };
    *INSTALL_RESULT.lock().unwrap() = None;
    set_percent(0);
    let result = (|| -> Result<()> {
        let target = crate::ziputil::bundle_id_of_ipa(ipa)
            .filter(|id| !id.trim().is_empty())
            .context("无法读取待安装 IPA 的 Bundle ID，已停止安装")?;
        if policy != InstallPolicy::Ask && target != expected_bundle_id {
            bail!("待安装 IPA 的 Bundle ID 已变化，请重新检测并选择安装方式");
        }
        std::fs::File::open(ipa).context("待安装 IPA 不可读，未执行卸载")?;
        let mut request = InstallRequest {
            target,
            own_bundle_id: own_bundle_id.to_string(),
            policy,
            uninstall_started: false,
            uninstalled: false,
        };
        // 包大小写进日志（重要级）：超大包的问题（内存/磁盘/耗时）全靠它判断。
        let size = std::fs::metadata(ipa).map(|m| m.len()).unwrap_or(0);
        let size_text = if size >= 1024 * 1024 * 1024 {
            format!("{:.1} GB", size as f64 / 1024.0 / 1024.0 / 1024.0)
        } else {
            format!("{:.0} MB", size as f64 / 1024.0 / 1024.0)
        };
        log_msg(&format!(
            "install: 待安装 {}（{}）；配对文件：{}",
            ipa.display(),
            size_text,
            pairing
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "未提供".to_string())
        ));

        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("创建 tokio 运行时失败")?;
        let result = rt.block_on(install_async(ipa, pairing, &mut request));
        if request.uninstalled {
            result.context("原 App 已卸载，但重新安装失败；原有数据无法恢复，可从当前安装步骤重试")
        } else if request.uninstall_started {
            result.context("卸载未确认成功，已停止后续安装；请检查设备上的 App 状态后重试")
        } else {
            result
        }
    })();
    match result {
        Ok(()) => {
            set_percent(100);
            log_msg("install: 安装完成（installd 返回成功）");
            0
        }
        Err(e) => {
            set_percent(-1);
            if let Some(conflict) = e.downcast_ref::<InstallConflict>() {
                *INSTALL_RESULT.lock().unwrap() = Some(conflict.0.to_string());
                log_msg("install: 已暂停，等待用户选择覆盖安装或卸载重装");
                1
            } else {
                let message = format!("{e:#}");
                *INSTALL_RESULT.lock().unwrap() = Some(serde_json::json!({"error": message}).to_string());
                log_msg(&format!("install error: {message}"));
                -1
            }
        }
    }
}

/// 把 installd 返回的原始错误翻译成**可执行的处理建议**。
///
/// 为什么需要：installd 的失败经 `idevice` 传回来是 `UnknownErrorType("<英文>")` 这样的裸串，
/// 用户看不懂，而真正的原因往往只有一个。匹配不到就返回 `None`（不臆测）。
fn explain_install_error(raw: &str) -> Option<String> {
    // 取 `after` 之后、`before` 之前的片段（用于从 installd 文案里抠出两个 App ID）。
    fn between(text: &str, after: &str, before: &str) -> Option<String> {
        let rest = text.split_once(after)?.1;
        let end = rest.find(before)?;
        Some(rest[..end].to_string())
    }

    if raw.contains("MismatchedApplicationIdentifierEntitlement") {
        let new_id = between(raw, "entitlement string (", ")").unwrap_or_else(|| "(未知)".into());
        let old_id = between(
            raw,
            "installed application's application-identifier string (",
            ")",
        )
        .unwrap_or_else(|| "(未知)".into());
        return Some(format!(
            "══ 安装被 iOS 拒绝：跨 App ID 覆盖升级 ══\n\
             设备上已安装的同名 App：{old_id}\n\
             本次要安装的：          {new_id}\n\
             原因：两者 Bundle ID 相同，但 application-identifier（含证书团队前缀的 App ID）不同。\n\
             　　 iOS 不允许使用另一张证书覆盖升级已安装的同名 App；若设备上为 App Store\n\
             　　 版本，或由其他证书签名的版本，均会被拒绝。\n\
             处理（二选一）：\n\
             　 ① 先在设备上卸载该 App，然后重新安装；\n\
             　 ② 改用与该 App 相同的证书与描述文件签名。\n\
             说明：卸载会清除该 App 的数据；卸载后仍可安装本工具签出的版本。"
        ));
    }
    if raw.contains("MismatchedBundleIDSigningIdentifier") {
        return Some(
            "══ 安装被 iOS 拒绝：签名标识与 Bundle ID 不一致 ══\n\
             部分嵌套代码（framework / appex）的签名标识与其 CFBundleIdentifier 不一致。\n\
             请核对日志中以下两项：\n\
             　 · `重签（主可执行）：…（CFBundleIdentifier=…）` 一行是否标注 `**缺失**`；\n\
             　 · 结尾的 `深签（自实现）：完成 X，失败 Y` 中失败数是否为 0。"
                .to_string(),
        );
    }
    if raw.contains("ApplicationVerificationFailed") || raw.contains("InvalidSignature") {
        return Some(
            "══ 安装被 iOS 拒绝：签名校验失败 ══\n\
             常见原因：签名证书与描述文件不匹配（例如描述文件的 App ID 与目标 Bundle ID 不同）、\n\
             证书已过期或被吊销、设备不在描述文件的设备列表中。\n\
             请核对日志中 `描述文件：name=…；App ID=…；团队=…；目标 Bundle ID=…` 一行。"
                .to_string(),
        );
    }
    if raw.contains("app extension placeholder") || raw.contains("Mismatched bundle IDs") {
        let ext_id = between(raw, "with bundle ID ", " that does not match")
            .unwrap_or_else(|| "(未知)".into());
        let parent_id =
            between(raw, "required prefix of ", " for parent").unwrap_or_else(|| "(未知)".into());
        return Some(format!(
            "══ 安装被 iOS 拒绝：扩展的 Bundle ID 与父 App 不匹配 ══\n\
             扩展：  {ext_id}\n\
             父 App：{parent_id}\n\
             原因：iOS 要求扩展（.appex）的 Bundle ID 必须以父 App 的 Bundle ID 为前缀。\n\
             　　 通常由「仅修改了主 App 的 Bundle ID、未同步修改嵌套扩展」造成。\n\
             处理：在流程中执行一次「改 Bundle ID」步骤即可，工具会同步全部扩展\n\
             　　 （日志中可见 `嵌套扩展 Bundle ID：PlugIns/…：旧 → 新`）。\n\
             核对：签名结尾的 `扩展前缀自检：检查 N 个扩展，前缀不符 M 个` 中不符数应为 0。"
        ));
    }
    None
}

async fn install_async(ipa: &Path, pairing: Option<&Path>, request: &mut InstallRequest) -> Result<()> {
    // 通路 0（免电脑，优先）：RemotePairing 隧道 → 用户态 TCP → RSD → AFC + installation_proxy。
    //
    // 设备端自连 RSD 端口（49152）**要 TLS-PSK**，密钥来自 RemotePairing 会话；
    // 配对记录可以在设备上自配对生成（本 App「设备配对」），所以这条路不需要电脑。
    // 先用带超时的 TCP 探测筛掉不可达地址，避免对它们做长时间连接等待。
    let mut rp_hosts: Vec<Ipv4Addr> = Vec::new();
    // 各地址的探测结果留着，最后放进最终错误里 —— 排障时最需要的就是这几行。
    let mut probe_notes: Vec<String> = Vec::new();
    for host in probe_hosts() {
        let (ok, note) = probe_endpoint(host, RSD_PORT, false).await;
        // 端口探测是逐地址的诊断细节：只进后台日志文件，界面不显示。
        crate::log_detail(&format!("install: 端口探测 {note}"));
        probe_notes.push(note);
        if ok {
            rp_hosts.push(host);
        }
    }
    // 被 iOS **策略**拒绝的原因（例如跨 App ID 覆盖升级）：通路本身是通的，这类原因才是
    // 真因，而用户通常只复制日志尾部 —— 收集起来，最后放进 `install error:` 一行里。
    let mut hints: Vec<String> = Vec::new();
    let mut errors: Vec<String> = Vec::new();
    if let Some(pairing) = pairing {
        for host in rp_hosts.iter().copied() {
            log_msg(&format!(
                "install: 尝试免电脑通路（RP 隧道 + 用户态 TCP，{host}）"
            ));
            match crate::rp::install(ipa, pairing, host, report_percent, request).await {
                Ok(()) => {
                    log_msg("install: 免电脑通路安装成功");
                    return Ok(());
                }
                Err(e) => {
                    if e.is::<InstallConflict>() || request.uninstall_started {
                        return Err(e);
                    }
                    let raw = format!("{e:#}");
                    log_msg(&format!("install: 免电脑通路失败（{host}）：{raw}"));
                    errors.push(format!("RP（{host}）：{raw}"));
                    if let Some(hint) = explain_install_error(&raw) {
                        hints.push(hint);
                    }
                }
            }
        }
    } else {
        log_msg("install: 未提供配对文件，跳过免电脑通路（RP 隧道需要自配对记录）");
    }

    // 先探测再动手。原因（实测）：
    //   - 设备自连 49152，TCP 能连上，但发 RSD 升级请求后被 RST → 对端不是明文 remoted；
    //   - 127.0.0.1:62078 直接返回 EPERM（沙盒拒绝直连回环的 lockdownd），
    //     但 loopback VPN 的对端地址（10.7.0.1）上另有出口。
    // 所以这里分别探「哪个地址是 RSD」与「哪个地址的 lockdownd 能应答」，再按可用性选通路。
    let mut rsd_host: Option<Ipv4Addr> = None;
    for host in probe_hosts() {
        let (ok, note) = probe_endpoint(host, RSD_PORT, true).await;
        log_msg(&format!("install: RSD 探测 {note}"));
        if ok && rsd_host.is_none() {
            rsd_host = Some(host);
        }
    }

    let mut lockdown_host: Option<Ipv4Addr> = None;
    for host in probe_hosts() {
        let (ok, note) = probe_lockdown(host).await;
        log_msg(&format!("install: lockdownd 探测 {note}"));
        if ok && lockdown_host.is_none() {
            lockdown_host = Some(host);
        }
    }

    // 通路 1：RSD（iOS 17+ 正统链路，需对端确实是明文 remoted）。
    if let Some(host) = rsd_host {
        log_msg(&format!("install: 尝试 RSD 通路（{host}:{RSD_PORT}）"));
        match rsd_install(ipa, host, request).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                if e.is::<InstallConflict>() || request.uninstall_started {
                    return Err(e);
                }
                log_msg(&format!("install: RSD 通路失败，转经典通路：{e:#}"));
                errors.push(format!("RSD（{host}）：{e:#}"));
            }
        }
    }

    // 通路 2：经典 lockdownd（loopback VPN 暴露本机 lockdownd + 配对记录）。
    // 这是 SideStore + StosVPN 在设备端自装的同款路径，不需要 RSD。
    if let Some(host) = lockdown_host {
        let Some(pairing) = pairing else {
            bail!(
                "lockdownd（{host}:62078）可应答，但没有配对文件：\n\
                 经典通路必须用配对记录建立会话。请在首页「输入」里选择配对文件\
                 （PC 上用 jitterbugpair / idevicepair 生成的那种）。"
            );
        };
        // 经典通路走的是 idevice 的 `install_package_with_callback`，它对**文件型**包同样是
        // `tokio::fs::read`（整个 IPA 读进内存）。大包会直接被 iOS jetsam 杀掉 App
        // ——「崩一下、没日志」最难查，所以这里主动跳过并说明。
        // （RSD / 免电脑通路不受此限：我们自己分块上传。）
        const CLASSIC_MAX_BYTES: u64 = 1500 * 1024 * 1024;
        let size = std::fs::metadata(ipa).map(|m| m.len()).unwrap_or(0);
        if size > CLASSIC_MAX_BYTES {
            let msg = format!(
                "经典通路已跳过：包约 {:.1} GB，超过该通路的内存上限\
                 （它会把整个 IPA 读进内存，大包会被系统杀掉）。请用 RSD / 免电脑通路。",
                size as f64 / 1024.0 / 1024.0 / 1024.0
            );
            log_msg(&format!("install: {msg}"));
            errors.push(format!("经典（{host}）：{msg}"));
        } else {
            log_msg(&format!(
                "install: 尝试经典通路（lockdownd {host}:62078 + 配对文件 {}）",
                pairing.display()
            ));
            match classic_install(ipa, pairing, host, request).await {
                Ok(()) => return Ok(()),
                Err(e) => {
                    if e.is::<InstallConflict>() || request.uninstall_started {
                        return Err(e);
                    }
                    log_msg(&format!("install: 经典通路失败：{e:#}"));
                    errors.push(format!("经典（{host}）：{e:#}"));
                }
            }
        }
    }

    // 通路是通的、最后被 iOS **策略**拒绝时（跨 App ID 覆盖升级等），这个原因才是真因：
    // 优先作为最终错误抛出，让日志尾部就是「原因 + 处理办法」。
    if hints.is_empty() {
        if let Some(hint) = explain_install_error(&errors.join("\n")) {
            hints.push(hint);
        }
    }
    if let Some(hint) = hints.first() {
        bail!("{hint}");
    }

    if errors.is_empty() {
        // 「为什么没有通路」必须**照实际探测结果**说，不能写成固定文案。
        // 踩过的坑：原来这里硬编码了「只有 127.0.0.1 连得上」，而真实情况是一个地址都连不上
        // （127.0.0.1 / 10.7.0.1 全是 Connection refused），错误信息与日志自相矛盾。
        //
        // 两种失败形状要分开说（实测）：
        //   ① rp_hosts 非空 → 至少能建立 TCP：多半是 127.0.0.1 那个**假阳性**
        //      （VPN 本地监听接受连接，但一发 RSD 升级请求就被 RST），真正干活的是 10.7.0.1；
        //   ② rp_hosts 为空 → 连回环都没人监听，说明 loopback VPN 整体没生效。
        let reason = if !rp_hosts.is_empty() {
            "候选地址可建立 TCP，但均非明文 RSD，lockdownd(62078) 亦无应答"
        } else {
            "49152 端口无服务监听：本机 127.0.0.1:49152 拒绝连接（Connection refused），\
             10.7.0.1 拒绝连接，10.7.0.2 连接超时。判定：loopback VPN 未生效"
        };
        bail!(
            "未找到可用的安装通路：{reason}。\n\
             探测明细：\n  - {}\n\
             处理（建议按顺序尝试）：\n\
             ① 重新连接 LocalDevVPN。隧道接口存在但端口不可用的情况，多数可由此恢复；\n\
             ② 断开其它 VPN（Shadowrocket / Clash 等）。iOS 同一时间仅允许一个 VPN 生效；\n\
             　 代理类 VPN 的 utun 地址通常为 198.18.0.1，会拦截发往 10.7.0.1 的流量；\n\
             ③ 切换一次飞行模式（或重新开关 WiFi），强制系统重建网络路径；\n\
             ④ 重启设备。该项可恢复此类故障，但代价最大，建议最后尝试。\n\
             重试时日志中应出现 `端口探测 127.0.0.1:49152 TCP 可连接` 或 `10.7.0.1:49152 TCP 可连接`。\n\
             说明：标题栏的 `LocalDevVPN` 仅表示隧道接口存在（隧道上有 10.7.x.x 地址），\n\
             不代表 49152 端口有服务监听，请以端口探测结果为准。\n\
             另外：免电脑通路需要配对文件（首页「输入」→ 配对文件）；如需进一步定位，\
             请提供 install: 开头的完整日志。",
            probe_notes.join("\n  - ")
        );
    }
    bail!("安装通路均失败：\n - {}", errors.join("\n - "));
}

/// 通路 1：RSD —— 握手拿到服务表后，用 AFC 上传到 /PublicStaging，再走 installation_proxy 安装。
async fn rsd_install(ipa: &Path, host: Ipv4Addr, request: &mut InstallRequest) -> Result<()> {
    let stream = TcpStream::connect((host, RSD_PORT))
        .await
        .with_context(|| format!("连接 RSD 失败（{host}:{RSD_PORT}）"))?;
    let mut handshake = RsdHandshake::new(stream).await.context("RSD 握手失败")?;
    log_msg(&format!(
        "install: RSD 握手成功（uuid={}，协议 v{}，服务 {} 个）",
        handshake.uuid,
        handshake.protocol_version,
        handshake.services.len()
    ));

    // 关键服务是否都在（缺失说明设备端权限/开发者模式有问题，先报出来更好定位）。
    for name in ["com.apple.afc", "com.apple.mobile.installation_proxy"] {
        let ok = handshake.services.contains_key(name);
        log_msg(&format!(
            "install: 服务 {name} {}",
            if ok { "✓" } else { "✗ 缺失" }
        ));
    }
    if !handshake.services.contains_key("com.apple.afc") {
        bail!("RSD 未提供 com.apple.afc：请确认开发者模式已开启");
    }
    if !handshake
        .services
        .contains_key("com.apple.mobile.installation_proxy")
    {
        bail!("RSD 未提供 com.apple.mobile.installation_proxy：请确认开发者模式已开启");
    }

    // 必须以 Developer 安装，否则 installd 不读内嵌描述文件，会在校验阶段拒绝。
    let mut opts = plist::Dictionary::new();
    opts.insert(
        "PackageType".to_string(),
        plist::Value::String("Developer".to_string()),
    );

    log_msg("install: 上传到 /PublicStaging 并安装（AFC + installation_proxy）…");
    let mut rsd = IpAddr::V4(host);
    let mut client = InstallationProxyClient::connect_rsd(&mut rsd, &mut handshake)
        .await.context("连接安装预检服务失败")?;
    prepare_install(&mut client, request).await?;
    drop(client);
    install_package_with_callback_rsd(
        &mut rsd,
        &mut handshake,
        ipa,
        Some(plist::Value::Dictionary(opts)),
        |(percent, _)| async move {
            report_percent(percent as i32);
        },
        (),
    )
    .await
    .context("安装失败（AFC 上传或 installation_proxy 安装）")?;

    Ok(())
}

/// 通路 2：经典 lockdownd —— 直连 62078 + 配对记录建立会话，
/// 之后由 `idevice` 的安装例程做「AFC 上传到 PublicStaging → installation_proxy Install」。
///
/// 注意：这里的配对文件必须是 **lockdownd 配对记录**（DeviceCertificate / HostPrivateKey …），
/// 即 jitterbugpair / idevicepair 生成的那种；RemotePairing 的配对文件格式不同。
async fn classic_install(ipa: &Path, pairing_path: &Path, host: Ipv4Addr, request: &mut InstallRequest) -> Result<()> {
    use idevice::pairing_file::PairingFile;
    use idevice::provider::TcpProvider;
    use idevice::utils::installation::install_package_with_callback;

    let pairing = PairingFile::read_from_file(pairing_path).map_err(|e| {
        anyhow::anyhow!(
            "读取配对文件失败（{}）：{e:?}\n\
             经典通路需要 lockdownd 配对记录（jitterbugpair / idevicepair 生成），\
             请确认所选文件类型正确",
            pairing_path.display()
        )
    })?;

    let provider = TcpProvider {
        addr: IpAddr::V4(host),
        scope_id: None,
        pairing_file: pairing,
        label: "SideInjector".to_string(),
    };

    let mut opts = plist::Dictionary::new();
    opts.insert(
        "PackageType".to_string(),
        plist::Value::String("Developer".to_string()),
    );

    let mut client = InstallationProxyClient::connect(&provider)
        .await.context("连接安装预检服务失败")?;
    prepare_install(&mut client, request).await?;
    drop(client);
    install_package_with_callback(
        &provider,
        ipa,
        Some(plist::Value::Dictionary(opts)),
        |(percent, _)| async move {
            report_percent(percent as i32);
        },
        (),
    )
    .await
    .map_err(|e| anyhow::anyhow!("AFC 上传 / installation_proxy 安装失败：{e:?}"))?;

    Ok(())
}

/// 统一记录进度（每跨过 5% 记一条，避免刷屏）。
/// `pub(crate)`：RP 隧道通路（rp.rs）也通过它上报百分比。
pub(crate) fn report_percent(p: i32) {
    let prev = INSTALL_PERCENT.swap(p, Ordering::Relaxed);
    if p / 5 != prev / 5 {
        log_msg(&format!("install[进度]: {p}%"));
    }
}

/// 探测 lockdownd：连接 + 发 QueryType（XML plist），有应答即认为可用。
///
/// 区分三种情况很重要：连接超时（地址/路由不对）、`Operation not permitted`（沙盒拒绝直连
/// 回环的 62078，但对 loopback VPN 的对端地址通常放行）、以及正常应答。
async fn probe_lockdown(host: Ipv4Addr) -> (bool, String) {
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    const LOCKDOWN_PORT: u16 = 62078;
    const QUERY_TYPE: &[u8] = br#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Request</key><string>QueryType</string></dict></plist>"#;

    let addr = std::net::SocketAddr::from((host, LOCKDOWN_PORT));
    let mut stream =
        match tokio::time::timeout(Duration::from_millis(1500), TcpStream::connect(addr)).await {
            Ok(Ok(s)) => s,
            Ok(Err(e)) => return (false, format!("{host}:{LOCKDOWN_PORT} 连接失败：{e}")),
            Err(_) => return (false, format!("{host}:{LOCKDOWN_PORT} 连接超时（1.5s）")),
        };
    if let Err(e) = stream.write_all(QUERY_TYPE).await {
        return (
            false,
            format!("{host}:{LOCKDOWN_PORT} 已连接，但发送 QueryType 失败：{e}"),
        );
    }
    let mut buf = vec![0u8; 512];
    match tokio::time::timeout(Duration::from_millis(1500), stream.read(&mut buf)).await {
        Ok(Ok(n)) if n > 0 => {
            let text = String::from_utf8_lossy(&buf[..n]).replace(['\r', '\n'], " ");
            let head: String = text.chars().take(120).collect();
            (true, format!("{host}:{LOCKDOWN_PORT} 应答 {n} 字节：{head}"))
        }
        Ok(Ok(_)) => (false, format!("{host}:{LOCKDOWN_PORT} 已连接但应答为空")),
        Ok(Err(e)) => (false, format!("{host}:{LOCKDOWN_PORT} 读取失败：{e}")),
        Err(_) => (
            false,
            format!("{host}:{LOCKDOWN_PORT} 已连接但 1.5s 内无应答"),
        ),
    }
}


/// loopback VPN 把设备自身服务暴露出来的常见地址（回环 + StosVPN 常用的 10.7.0.x）。
fn probe_hosts() -> Vec<Ipv4Addr> {
    vec![
        Ipv4Addr::LOCALHOST,
        Ipv4Addr::new(10, 7, 0, 1),
        Ipv4Addr::new(10, 7, 0, 2),
    ]
}

/// 探测一个端点：TCP 连接 →（RSD 端口则）发送标准 RSD 升级请求 → 读响应。
///
/// 返回 `(是否像 RSD, 描述)`；描述直接进日志。判据：响应用 `HTTP/` 开头即认作 RSD
/// （remoted 会回 `HTTP/1.1 101 Switching Protocols`）。
async fn probe_endpoint(host: Ipv4Addr, port: u16, rsd_http: bool) -> (bool, String) {
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let addr = std::net::SocketAddr::from((host, port));
    let mut stream = match tokio::time::timeout(Duration::from_millis(1500), TcpStream::connect(addr)).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => return (false, format!("{host}:{port} 连接失败：{e}")),
        Err(_) => return (false, format!("{host}:{port} 连接超时（1.5s）")),
    };
    if !rsd_http {
        return (true, format!("{host}:{port} TCP 可连接"));
    }

    let req = format!(
        "GET / HTTP/1.1\r\nHost: {host}\r\nConnection: Upgrade\r\nUpgrade: PTTH/1.0\r\n\r\n"
    );
    if let Err(e) = stream.write_all(req.as_bytes()).await {
        return (false, format!("{host}:{port} 已连接，但发送升级请求失败：{e}"));
    }
    let mut buf = vec![0u8; 512];
    match tokio::time::timeout(Duration::from_millis(1500), stream.read(&mut buf)).await {
        Ok(Ok(0)) => (
            false,
            format!("{host}:{port} 请求后对端立即关闭（0 字节）→ 不是 RSD"),
        ),
        Ok(Ok(n)) => {
            let text = String::from_utf8_lossy(&buf[..n]).replace(['\r', '\n'], " ");
            let head: String = text.chars().take(160).collect();
            let hex: String = buf[..n.min(32)]
                .iter()
                .map(|b| format!("{b:02x}"))
                .collect::<Vec<_>>()
                .join(" ");
            let looks_rsd = text.starts_with("HTTP/");
            (
                looks_rsd,
                format!("{host}:{port} 收到 {n} 字节，响应：{head}；hex={hex}"),
            )
        }
        Ok(Err(e)) => (false, format!("{host}:{port} 请求后读取失败：{e}")),
        Err(_) => (
            false,
            format!("{host}:{port} 已连接，但 1.5s 内无响应 → 不是 RSD（疑似被中间层吞掉）"),
        ),
    }
}
