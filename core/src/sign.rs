//! 用导入的开发证书重签整个 .app bundle（进程内库签名）。
//!
//! iOS 禁止 App 通过 fork/exec 启动子进程（spawn 会报 `operation not permitted`），
//! 因此不能把 rcodesign 当外部二进制调用；这里直接链接 apple-codesign 库完成签名。
//!
//! 代码出处（开源署名）：
//!   库依赖：apple-codesign / apple-bundles —— https://github.com/indygreg/apple-platform-rs
//!          许可：MPL-2.0（文件级弱著佐权）。本仓库**未修改其源码**，仅作库链接使用；
//!          分发本 App 时按 MPL-2.0 提供其源码获取地址（crates.io / 上游仓库）即可。
//!   参考实现：下方 `diagnose_bundle` / `classify_bundle` / `report_bundle` 是阅读其
//!          `apple-bundles` 的 `DirectoryBundle` 实现（`shallow` 判定、优先
//!          `Resources/Info.plist`、嵌套 bundle 候选规则）后写成的**镜像检查**，
//!          用于复现它的判定结果、定位它抛出的「不带路径」的 ENOENT。
//!          另：`sign_nested_executable` 里「签主可执行 + 嵌回原 CodeResources」的做法，
//!          与上游 `SingleBundleSigner::write_signed_bundle` 中签主可执行的那段一致
//!          （`set_binary_identifier(SettingsScope::Main, ident)` /
//!          `set_code_resources_data` / `set_info_plist_data` 的用法）。
//!   本文件改动：签名调用链（嵌套代码改为「只重签主可执行」、Entitlements 提取、
//!          签出到独立目录 `.si_signed`、失败时报告输出目录进度）均为本项目自有实现。
//!
//! 嵌套代码为什么不再「整个 bundle 一起签」（实测结论）：
//!   apple-codesign 签 bundle 必须走 `walk_and_seal_directory`（边封资源边把文件搬到
//!   输出目录），在设备上对**带主可执行文件**的嵌套项会稳定抛**不带路径**的
//!   `ENOENT (os error 2)`——本项目一次流程里 93 项有 63 项失败，且失败的清一色是
//!   "有主可执行"的 framework/appex，成功的 30 项都是没有主可执行的资源 bundle。
//!   而 `MachOSigner` 直接改写 Mach-O 这条路已被验证可用（主 App 的主可执行就是
//!   由它写出的）。于是嵌套项改为：只重签它的主可执行，并保留该 bundle 原有的
//!   `_CodeSignature/CodeResources`——框架/应用的封印本来就把自己的主可执行排除在外
//!   （规则 `^<主可执行>$ exclude: true`），内容没变则封印依旧成立；主 App 重新生成的
//!   CodeResources 会封住嵌套项的新签名。

use crate::log_msg;
use anyhow::{Context, Result};
use apple_codesign::cryptography::parse_pfx_data;
use apple_codesign::{MachOSigner, SettingsScope, SigningSettings, UnifiedSigner};
use std::fs;
use std::path::Path;

pub fn sign_bundle(
    app: &Path,
    p12: Option<&str>,
    password: &str,
    prov: Option<&str>,
    _team: Option<&str>,
) -> Result<()> {
    let p12 = p12.ok_or_else(|| anyhow::anyhow!("缺少 p12 证书路径"))?;
    let prov = prov.ok_or_else(|| anyhow::anyhow!("缺少 mobileprovision 描述文件"))?;

    log_msg(&format!(
        "sign_bundle: app={} p12={} prov={}",
        app.display(),
        p12,
        prov
    ));
    if !app.exists() {
        anyhow::bail!("待签名的 .app 不存在：{}", app.display());
    }
    diagnose_bundle(app);

    let p12_data = fs::read(p12).with_context(|| format!("读取 P12 证书失败：{p12}"))?;
    let prov_data = fs::read(prov).with_context(|| format!("读取描述文件失败：{prov}"))?;

    // p12 → 证书 + 私钥
    let (cert, key) = parse_pfx_data(&p12_data, password).context("解析 P12 证书失败（检查密码）")?;

    let mut settings = SigningSettings::default();
    settings.set_signing_key(&key, cert);
    settings.chain_apple_certificates();
    settings.set_team_id_from_signing_certificate();

    // 嵌套代码用的基础设置：**故意不带**主 App 的 Entitlements。
    // 主 App 的授权只应出现在主可执行上；把它塞进每个 framework 会让 installd 以
    // 「嵌套代码授权超出描述文件」之类的理由拒绝（嵌套代码的授权必须是描述文件的子集）。
    // 每项在签名时按需自己补 Entitlements。
    let nested_template = settings.clone();

    // 从 mobileprovision 提取 Entitlements 并写回签名设置
    let entitlements = extract_profile_entitlements(&prov_data)?;
    settings.set_entitlements_xml(SettingsScope::Main, entitlements.as_str())?;

    // 不要用 sign_path_in_place：对「目录型 bundle」它会先把目标文件删掉、再从源路径复制，
    // 而 in-place 时输入与输出是同一个路径 —— 等于删掉源文件后再去 lstat 它，直接 ENOENT。
    // 这里改成签到一个独立输出目录，成功后再整体替换回原 .app（等价于 CLI 的 -o）。
    let parent = app
        .parent()
        .ok_or_else(|| anyhow::anyhow!("无法取得 .app 的父目录：{}", app.display()))?;
    let name = app
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| anyhow::anyhow!("非法的 .app 名称：{}", app.display()))?;

    let out_root = parent.join(".si_signed");
    let _ = fs::remove_dir_all(&out_root);
    fs::create_dir_all(&out_root)
        .with_context(|| format!("创建签名输出目录失败：{}", out_root.display()))?;
    let out = out_root.join(name);

    // ① 先逐个重签嵌套代码（我们自己做"深签"），顺序是从深到浅。
    let mut nested_settings = nested_template.clone();
    // 资源 bundle / dylib 仍走「文件或 bundle 级签名」；对每个嵌套项自身用浅签，
    // 不再向下递归（它的嵌套项也在我们的清单里，会各自被处理）。
    nested_settings.set_shallow(true);

    let nested = collect_signable_nested(app);
    log_msg(&format!("深签（自实现）：待重签嵌套代码 {} 项", nested.len()));
    let mut failed = 0usize;
    let mut signed_exe = 0usize;
    let mut reported = 0usize;
    for item in &nested {
        let is_dir = item.is_dir();
        let id = if is_dir { bundle_id_of(item) } else { None };
        let name = item
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();

        // 逐项日志一律走「细节」级（只进后台日志文件）：一轮 90 多项，全打到界面上没意义。
        // 每 20 项补一条**重要**日志，界面才有进度感。
        let done = signed_exe + failed;
        if done > 0 && done % 20 == 0 && done != reported {
            reported = done;
            log_msg(&format!("重签进度 {done}/{}…", nested.len()));
        }

        // ①-a 带主可执行文件的 bundle（.framework / .appex / .app）：只重签它的主可执行。
        //      （为什么不用「签整个 bundle」，见文件头说明。）
        //
        //      签名标识必须等于该 bundle 的 CFBundleIdentifier，否则 installd 会拒绝：
        //      `MismatchedBundleIDSigningIdentifier`
        //      （实例：KAPinField.framework 原签名标识是 KAPinField，而它的 bundle id 是
        //       org.cocoapods.KAPinField）。只签 Mach-O 时 apple-codesign **不会**自动
        //      取 Info.plist，必须显式 `set_binary_identifier`。
        if let Some(exe_path) = if is_dir { main_executable_of(item) } else { None } {
            crate::log_detail(&format!(
                "  重签（主可执行）：{name}（CFBundleIdentifier={}）",
                id.clone().unwrap_or_else(|| "**缺失**".to_string())
            ));
            match sign_nested_executable(
                &exe_path,
                item,
                id.as_deref(),
                &nested_template,
                &entitlements,
                is_extension(item),
            ) {
                Ok(()) => signed_exe += 1,
                Err(e) => {
                    failed += 1;
                    log_msg(&format!(
                        "  重签失败（保留原签名）：{} —— {e:#}",
                        item.display()
                    ));
                    // 复现 apple-bundles 的判定规则，看它「看到的」结构是什么样。
                    diagnose_bundle(item);
                }
            }
            continue;
        }

        // ①-b-1 没有 Info.plist 的目录（原包就没带，如 GoogleCast 的
        //       `GoogleCastUIResources.bundle` / `GoogleCastCoreResources.bundle` /
        //       根目录的 `Settings.bundle`）：它不算可签名的 bundle，apple-bundles 直接拒绝。
        //       保持原样即可（iOS 只当普通资源），不该记成「失败」让日志变吓人。
        if is_dir && info_plist_of(item).is_none() {
            crate::log_detail(&format!(
                "  跳过（无 Info.plist，非可签名 bundle，保持原样）：{name}"
            ));
            continue;
        }

        // ①-b-2 其余项：没有主可执行的资源 bundle（只封资源）、以及注入的 .dylib。
        crate::log_detail(&format!("  重签（资源/二进制）：{name}"));
        match sign_in_place(item, &nested_settings) {
            Ok(()) => {}
            Err(e) => {
                failed += 1;
                log_msg(&format!(
                    "  重签失败（保留原签名）：{} —— {e:#}",
                    item.display()
                ));
                if let Some(b) = crate::logbridge::last_bundle() {
                    log_msg(&format!("    最后进入的 bundle：{b}"));
                }
                // 复现 apple-bundles 的判定规则，定位它「看到的」路径为何不存在。
                diagnose_bundle(item);
            }
        }
    }
    log_msg(&format!(
        "深签（自实现）：完成 {}，失败 {}（其中主可执行重签 {signed_exe} 项）",
        nested.len() - failed,
        failed
    ));
    if failed > 0 {
        log_msg(&format!(
            "⚠️ 有 {failed} 项嵌套代码未能重签（保留原签名）：安装时可能被 installd 以 \
             MismatchedBundleIDSigningIdentifier / 资源封印不匹配为由拒绝"
        ));
    }

    // 主 App 自己也要清一遍分离签名残留（理由同 sign_nested_executable）。
    clean_stale_signature_files(app);

    // ② 再浅签主 App：把最终内容整体封进主 App 的 CodeResources。
    //
    // ★ 这里有个反直觉的关键点：apple-codesign 的「浅签」**不是只复制嵌套代码**，
    //   它会把 app 里所有嵌套 Mach-O 逐个**重新签名**（日志里的
    //   `signing Mach-O file Frameworks/xxx.framework/xxx`），而那条路径**不会**继承
    //   `Main` 作用域的标识 —— 标识会被按**二进制名**重算
    //   （`KAPinField` / `GZIP` / `libbluray`…），把我们上一步逐项签好的结果整个覆盖；
    //   installd 于是报 `MismatchedBundleIDSigningIdentifier`（原包也是栽在这条规则上）。
    //
    //   解法：给每个嵌套 Mach-O 登记一个**路径作用域**的标识
    //   （`SettingsScope::Path("Frameworks/KAPinField.framework/KAPinField")`）。
    //   apple-codesign 在按相对路径签这个 Mach-O 时会把该作用域映射成 `Main`，
    //   于是用我们给的值（= 它的 `CFBundleIdentifier`）。
    let mut shallow = settings.clone();
    shallow.set_shallow(true);
    let mut registered = 0usize;
    for item in &nested {
        if !item.is_dir() {
            continue;
        }
        let (Some(exe), Some(want)) = (main_executable_of(item), bundle_id_of(item)) else {
            continue;
        };
        if let Ok(rel) = exe.strip_prefix(app) {
            shallow.set_binary_identifier(SettingsScope::Path(rel.to_string_lossy().to_string()), want);
            registered += 1;
        }
    }
    log_msg(&format!(
        "浅签阶段登记路径作用域签名标识 {registered} 项（apple-codesign 会逐个重签这些 Mach-O）"
    ));
    let _ = fs::remove_dir_all(&out_root);
    fs::create_dir_all(&out_root)
        .with_context(|| format!("创建签名输出目录失败：{}", out_root.display()))?;
    let signer = UnifiedSigner::new(shallow);
    if let Err(e) = signer.sign_path(app, &out) {
        log_msg(&format!("主 App 浅签失败：{e:#}"));
        if let Some(b) = crate::logbridge::last_bundle() {
            log_msg(&format!("主 App 浅签失败：最后进入的嵌套 bundle = {b}"));
        }
        // apple-codesign 的 IO 错误不带路径；统计输出目录已产出的内容可推断它走到哪儿。
        report_partial_output(&out_root);
        return Err(anyhow::anyhow!(
            "签名 .app 失败：{}：{e:#}",
            app.display()
        ));
    }
    log_msg("主 App 浅签完成（嵌套代码为各自重签后的版本）");

    // 用签名后的产物替换原 .app
    fs::remove_dir_all(app).with_context(|| format!("移除原 .app 失败：{}", app.display()))?;
    fs::rename(&out, app).with_context(|| format!("替换回 .app 失败：{}", app.display()))?;
    let _ = fs::remove_dir_all(&out_root);

    // ④ 收尾自证：把「最终会打进 IPA 的那份 app」逐项读回签名标识，与 bundle id 比对。
    verify_signed_identifiers(app);

    log_msg("apple-codesign 库签名完成");
    Ok(())
}

/// 收尾自证：把最终打进 IPA 的那份 app 里，每个代码项的主可执行签名标识读回来，
/// 与它的 `CFBundleIdentifier` 比对。installd 的
/// `MismatchedBundleIDSigningIdentifier` 校验的就是这条规则；这里提前把结果打出来，
/// 免得装到一半失败还要回头猜「到底是哪一项没签上」。
fn verify_signed_identifiers(app: &Path) {
    let mut checked = 0usize;
    let mut bad = 0usize;

    // 主 App 自己
    if let Some((exe, want)) = main_executable_of(app).zip(bundle_id_of(app)) {
        if let Ok(data) = fs::read(&exe) {
            checked += 1;
            match code_directory_identifier(&data) {
                Some(got) if got == want => {}
                other => {
                    bad += 1;
                    log_msg(&format!(
                        "⚠️ 标识自检：主 App 实际「{}」，期望「{want}」",
                        other.unwrap_or_else(|| "(读不到)".to_string())
                    ));
                }
            }
        }
    }

    // 每个嵌套项
    for item in collect_signable_nested(app) {
        if !item.is_dir() {
            continue;
        }
        let (Some(exe), Some(want)) = (main_executable_of(&item), bundle_id_of(&item)) else {
            continue;
        };
        let Ok(data) = fs::read(&exe) else { continue };
        checked += 1;
        let name = item
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        match code_directory_identifier(&data) {
            Some(got) if got == want => {}
            Some(got) => {
                bad += 1;
                log_msg(&format!(
                    "⚠️ 标识自检：{name} 实际「{got}」，期望「{want}」（installd 会以此拒绝）"
                ));
            }
            None => {
                bad += 1;
                log_msg(&format!("⚠️ 标识自检：{name} 读不到签名标识"));
            }
        }
    }

    log_msg(&format!(
        "签名标识自检：检查 {checked} 项，不匹配 {bad} 项（0 表示每个代码项的签名标识都等于它的 bundle id）"
    ));
}

/// 收集需要单独重签的嵌套代码：`.framework` / `.appex` / `.bundle` / `.xpc` / `.app`
/// 目录，以及 `Frameworks/` 下注入的 `.dylib`；按深度**从深到浅**排序（先签里面的）。
fn collect_signable_nested(app: &Path) -> Vec<std::path::PathBuf> {
    let mut found: Vec<(usize, std::path::PathBuf)> = Vec::new();
    let mut stack: Vec<(usize, std::path::PathBuf)> = vec![(0, app.to_path_buf())];
    while let Some((depth, dir)) = stack.pop() {
        let Ok(rd) = fs::read_dir(&dir) else { continue };
        for entry in rd.flatten() {
            let path = entry.path();
            let Ok(md) = fs::symlink_metadata(&path) else {
                continue;
            };
            if md.file_type().is_symlink() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            if md.is_dir() {
                let is_bundle = name.ends_with(".framework")
                    || name.ends_with(".appex")
                    || name.ends_with(".bundle")
                    || name.ends_with(".xpc")
                    || name.ends_with(".app");
                if is_bundle {
                    found.push((depth + 1, path.clone()));
                }
                stack.push((depth + 1, path));
            } else if name.ends_with(".dylib") {
                found.push((depth + 1, path));
            }
        }
    }
    found.sort_by(|a, b| b.0.cmp(&a.0));
    found.into_iter().map(|(_, p)| p).collect()
}

/// 找出一个 bundle 的 Info.plist（iOS 扁平布局 / macOS 布局 / versioned framework）。
fn info_plist_of(bundle: &Path) -> Option<std::path::PathBuf> {
    [
        bundle.join("Info.plist"),                             // iOS 应用 / framework（扁平）
        bundle.join("Contents/Info.plist"),                    // macOS 风格
        bundle.join("Resources/Info.plist"),                   // versioned framework（软链目标）
        bundle.join("Versions/Current/Resources/Info.plist"),  // versioned framework
    ]
    .into_iter()
    .find(|c| c.is_file())
}

/// 读 Info.plist 里的一个字符串键。
fn plist_string(plist: &Path, key: &str) -> Option<String> {
    let value = plist::Value::from_file(plist).ok()?;
    let dict = value.as_dictionary()?;
    dict.get(key)
        .and_then(|x| x.as_string())
        .map(|s| s.to_string())
}

/// 读出一个 bundle 的 `CFBundleIdentifier`。
///
/// 为什么需要它：installd 会校验「**签名标识 == bundle id**」，否则报
/// `MismatchedBundleIDSigningIdentifier`。而单独签一个 Mach-O 时 apple-codesign
/// **不会**自动从 Info.plist 取标识，必须由我们用 `set_binary_identifier` 显式给。
/// 若该键缺失，标识就永远修不好 —— 所以调用处会把它打出来，缺失时标 `**缺失**`。
fn bundle_id_of(path: &Path) -> Option<String> {
    plist_string(&info_plist_of(path)?, "CFBundleIdentifier")
}

/// 依 `CFBundleExecutable` 找出 bundle 的主可执行文件。
fn main_executable_of(bundle: &Path) -> Option<std::path::PathBuf> {
    let exe = plist_string(&info_plist_of(bundle)?, "CFBundleExecutable")?;
    if exe.is_empty() || exe.contains('/') {
        return None;
    }
    [
        bundle.join(&exe),                         // .framework / .appex / .app（iOS 扁平）
        bundle.join("Contents/MacOS").join(&exe),  // macOS 风格
    ]
    .into_iter()
    .find(|c| c.is_file())
}

/// 是否扩展（.appex）：扩展需要带授权，其它嵌套代码一律清空授权。
fn is_extension(item: &Path) -> bool {
    item.file_name()
        .map(|n| n.to_string_lossy().ends_with(".appex"))
        .unwrap_or(false)
}

/// 空的 Entitlements plist：显式清空嵌套代码（framework / 注入 dylib）的授权。
const EMPTY_ENTITLEMENTS: &str = concat!(
    r#"<?xml version="1.0" encoding="UTF-8"?>"#,
    r#"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
    r#"<plist version="1.0"><dict/></plist>"#
);

/// 重签一个 bundle 的**主可执行文件**（不重签整个 bundle，理由见文件头）。
///
/// 做四件必须的事：
///   1. 清掉 `_CodeSignature/` 下的**分离签名残留**（第三方打包工具留下的
///      `CodeDirectory` / `CodeRequirements` / `CodeSignature`）。Security.framework
///      一旦看到这些文件会**优先**采用它们，我们刚嵌进 Mach-O 的新签名就被忽略，
///      标识仍是旧值 → installd 报 `MismatchedBundleIDSigningIdentifier`；
///   2. 签名标识显式设为该 bundle 的 `CFBundleIdentifier`（installd 会校验）；
///   3. 把该 bundle 原有的 `_CodeSignature/CodeResources` 原样嵌回签名
///      （主可执行本来就不在里面，资源没动 → 封印依旧成立）；
///   4. 扩展带上主 App 的授权（描述文件允许的子集），framework / dylib 清空授权。
fn sign_nested_executable(
    exe: &Path,
    bundle: &Path,
    bundle_id: Option<&str>,
    template: &SigningSettings,
    app_entitlements: &str,
    extension: bool,
) -> Result<()> {
    // 先清掉第三方工具留下的「分离签名」残留（见函数说明）。
    clean_stale_signature_files(bundle);

    let data = fs::read(exe).with_context(|| format!("读取主可执行失败：{}", exe.display()))?;

    let mut s = template.clone();
    if let Some(id) = bundle_id {
        s.set_binary_identifier(SettingsScope::Main, id);
    }
    if let Ok(bytes) = fs::read(bundle.join("_CodeSignature").join("CodeResources")) {
        s.set_code_resources_data(SettingsScope::Main, bytes);
    }
    if let Some(plist) = info_plist_of(bundle) {
        if let Ok(bytes) = fs::read(&plist) {
            s.set_info_plist_data(SettingsScope::Main, bytes);
        }
    }
    let ents = if extension {
        app_entitlements
    } else {
        EMPTY_ENTITLEMENTS
    };
    s.set_entitlements_xml(SettingsScope::Main, ents)?;

    let signer = MachOSigner::new(&data)?;
    let mut signed = Vec::with_capacity(data.len() + (1 << 17));
    signer.write_signed_binary(&s, &mut signed)?;

    // 自证：把刚生成的签名里的 CodeDirectory 标识读回来，和期望值比对。
    // （installd 的 `MismatchedBundleIDSigningIdentifier` 校验的就是这个值。）
    // 一致就不打日志（一轮 60 项，界面只该留异常）；不一致才值得看。
    match (code_directory_identifier(&signed), bundle_id) {
        (Some(got), Some(want)) if got == want => {}
        (Some(got), want) => {
            log_msg(&format!(
                "  ⚠️ 标识自检不符：实际「{got}」，期望「{}」",
                want.unwrap_or("(无)")
            ));
        }
        (None, _) => {
            log_msg("  ⚠️ 标识自检：读不回签名标识（新签名可能没写进去）");
        }
    }

    // 原子替换：先写同目录的临时文件（并保留可执行位），再 rename 覆盖原文件，
    // 避免写一半失败把二进制写坏。
    let fname = exe
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "exe".to_string());
    let tmp = exe.with_file_name(format!(".si_exe_{fname}"));
    fs::write(&tmp, &signed).with_context(|| format!("写入新签名失败：{}", tmp.display()))?;
    let mode = fs::metadata(exe)?.permissions();
    fs::set_permissions(&tmp, mode)?;
    fs::rename(&tmp, exe).with_context(|| format!("替换主可执行失败：{}", exe.display()))?;
    Ok(())
}

/// 删掉 `_CodeSignature/` 下除 `CodeResources` 外的残留文件（分离签名）。
///
/// 为什么必须删：`Security.framework` 校验 bundle 时，若 `_CodeSignature/` 里存在这类
/// 分离签名文件（`CodeDirectory` / `CodeRequirements` / `CodeSignature`），它会**优先**
/// 采用分离签名，而不是 Mach-O 里嵌入的那份 —— 于是我们刚写进去的新标识被忽略，
/// 旧标识（第三方工具按二进制名打的，如 `KAPinField`）继续生效，
/// installd 就报 `MismatchedBundleIDSigningIdentifier`。
///
/// 删除是安全的：CodeResources 规则里 `^_CodeSignature/` 被显式排除，
/// 这些文件本来就不在封印范围内，删掉不会让资源封印失效。
fn clean_stale_signature_files(bundle: &Path) -> usize {
    let dir = bundle.join("_CodeSignature");
    let Ok(rd) = fs::read_dir(&dir) else { return 0 };
    let mut removed = 0usize;
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        if name == "CodeResources" {
            continue;
        }
        let p = e.path();
        let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
        let done = if is_dir {
            fs::remove_dir_all(&p).is_ok()
        } else {
            fs::remove_file(&p).is_ok()
        };
        if done {
            removed += 1;
            log_msg(&format!(
                "    清理残留签名文件 {}/{}（分离签名会让 iOS 忽略新嵌入的签名）",
                bundle
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default(),
                name
            ));
        }
    }
    removed
}

/// 从 Mach-O 字节里读回 CodeDirectory 的标识（`code_directory_identifier` 自证用）。
///
/// 结构：Mach-O 头 → 加载命令里的 `LC_CODE_SIGNATURE`(0x1d) 给出签名数据偏移 →
/// 该处是**大端**的超级块（magic `0xfade0cc0`）→ 索引表里 type=0 即 CodeDirectory
/// （magic `0xfade0c02`）→ 其 `identOffset` 处是 C 字符串形式的标识。
/// 自己解析的原因：apple-codesign 没有公开「读标识」的接口，
/// 而这是唯一能自证「新签名是否真的生效」的办法。
fn code_directory_identifier(macho: &[u8]) -> Option<String> {
    fn be(b: &[u8], off: usize) -> Option<u32> {
        let s = b.get(off..off + 4)?;
        Some(u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
    }
    fn le(b: &[u8], off: usize) -> Option<u32> {
        let s = b.get(off..off + 4)?;
        Some(u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }
    // 只处理 64 位、小端的单架构 Mach-O（本项目签的都是这种）。
    if le(macho, 0)? != 0xfeed_facf {
        return None;
    }
    let ncmds = le(macho, 16)? as usize;
    let mut off = 32usize;
    for _ in 0..ncmds {
        let cmd = le(macho, off)?;
        let cmdsize = le(macho, off + 4)? as usize;
        if cmd == 0x1d {
            // LC_CODE_SIGNATURE
            let dataoff = le(macho, off + 8)? as usize;
            let datasize = le(macho, off + 12)? as usize;
            let blob = macho.get(dataoff..dataoff.checked_add(datasize)?)?;
            if be(blob, 0)? != 0xfade_0cc0 {
                return None;
            }
            let count = be(blob, 8)? as usize;
            for i in 0..count {
                let entry = 12 + i * 8;
                if be(blob, entry)? != 0 {
                    continue; // 0 = CSSLOT_CODEDIRECTORY
                }
                let cd_off = be(blob, entry + 4)? as usize;
                let cd = blob.get(cd_off..)?;
                if be(cd, 0)? != 0xfade_0c02 {
                    return None;
                }
                // magic/length/version/flags/hashOffset 之后就是 identOffset。
                let ident_off = be(cd, 20)? as usize;
                let bytes = cd.get(ident_off..)?;
                let end = bytes.iter().position(|&b| b == 0)?;
                return String::from_utf8(bytes[..end].to_vec()).ok();
            }
            return None;
        }
        if cmdsize < 8 {
            return None;
        }
        off = off.checked_add(cmdsize)?;
    }
    None
}

/// 就地把一个代码项（bundle 或 dylib）重签：签进临时目录，成功后再整体替换回去。
fn sign_in_place(path: &Path, settings: &SigningSettings) -> Result<()> {
    if path.is_dir() {
        // 同样清掉分离签名残留（理由见 sign_nested_executable）。
        clean_stale_signature_files(path);
    }
    let parent = path
        .parent()
        .ok_or_else(|| anyhow::anyhow!("无法取得父目录：{}", path.display()))?;
    let name = path
        .file_name()
        .and_then(|s| s.to_str())
        .ok_or_else(|| anyhow::anyhow!("非法名称：{}", path.display()))?;

    let out_root = parent.join(".si_nested");
    let _ = fs::remove_dir_all(&out_root);
    fs::create_dir_all(&out_root)
        .with_context(|| format!("创建临时输出目录失败：{}", out_root.display()))?;
    let out = out_root.join(name);

    let attempt = (|| -> Result<()> {
        let signer = UnifiedSigner::new(settings.clone());
        signer
            .sign_path(path, &out)
            .with_context(|| format!("签名失败：{}", path.display()))?;
        if path.is_dir() {
            fs::remove_dir_all(path).with_context(|| format!("移除原项失败：{}", path.display()))?;
        } else {
            fs::remove_file(path).with_context(|| format!("移除原项失败：{}", path.display()))?;
        }
        fs::rename(&out, path).with_context(|| format!("替换回原路径失败：{}", path.display()))?;
        Ok(())
    })();
    // 无论成败都清掉临时目录，避免残留被后面主 App 的签名给封进去。
    let _ = fs::remove_dir_all(&out_root);
    attempt
}

/// 签名前诊断：apple-codesign / apple-bundles 抛出的 IO 错误**不带路径**，
/// 这里镜像 apple-bundles 0.21 的 bundle 判定规则，把它「将会看到的结构」打出来：
///
/// - 顶层结构（顶层文件数 + 各子目录及其文件数）——一眼看出目录树是否完整
/// - 主 bundle 与每个「嵌套 bundle 候选目录」的判定结果（类型 / Info.plist 路径 / shallow）
/// - 每个 bundle 依 CFBundleExecutable 解析出的主可执行文件是否存在
///
/// apple-bundles 的判定规则（0.21 源码）：
///   shallow      = 根目录下**没有** Contents 目录
///   info_plist   = 若 `<根>/Resources/Info.plist` 是文件 → 判为 Framework，用它；
///                  否则若 `(<shallow ? 根 : 根/Contents>)/Info.plist` 是文件 → App / Bundle，用它
///   嵌套候选      = 任意子目录（Framework 自身会跳过其 Resources / Versions 两个候选）
/// 它一旦把某目录误判成 bundle，就会按上面这条路径去 `fs::read`，路径不存在即
/// `ENOENT (os error 2)` —— 这正是签名失败的成因，所以每条读路径都在这里验一遍。
fn diagnose_bundle(app: &Path) {
    report_top_level(app);
    report_bundle(app, "主 bundle");
    let mut candidates = 0usize;
    find_bundle_candidates(app, app, &mut candidates, 0);
    log_msg(&format!("bundle 诊断：嵌套 bundle 候选 {candidates} 个"));

    let mut files = 0usize;
    let mut links = 0usize;
    let mut broken: Vec<String> = Vec::new();
    walk_bundle(app, &mut files, &mut links, &mut broken);
    log_msg(&format!(
        "bundle 诊断：文件 {files}，符号链接 {links}，断链 {}",
        broken.len()
    ));
    for b in broken.iter().take(50) {
        log_msg(&format!("bundle 诊断：断链 {b}"));
    }
}

/// 打印 .app 顶层结构：顶层文件数 + 各子目录（含其文件数）。
/// 若子目录为 0，说明 IPA 是「扁平」的（解压丢了目录层级），apple-codesign 会立刻异常。
fn report_top_level(app: &Path) {
    let Ok(rd) = fs::read_dir(app) else {
        log_msg(&format!("bundle 诊断：无法列出目录 {}", app.display()));
        return;
    };
    let mut dirs: Vec<(String, usize)> = Vec::new();
    let mut top_files = 0usize;
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().to_string();
        match fs::symlink_metadata(&p) {
            Ok(md) if md.is_dir() => dirs.push((name, count_files(&p, 5000))),
            Ok(md) if md.file_type().is_symlink() => dirs.push((format!("{name}[链接]"), 0)),
            _ => top_files += 1,
        }
    }
    dirs.sort();
    log_msg(&format!(
        "bundle 诊断：顶层文件 {top_files} 个；子目录 {} 个：{}",
        dirs.len(),
        dirs.iter()
            .map(|(n, c)| format!("{n}({c})"))
            .collect::<Vec<_>>()
            .join(", ")
    ));
}

/// 递归统计目录内文件数（符号链接按文件计，与 apple-bundles 的 files() 一致）。
fn count_files(dir: &Path, cap: usize) -> usize {
    let mut n = 0usize;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            match fs::symlink_metadata(e.path()) {
                Ok(md) if md.is_dir() => stack.push(e.path()),
                Ok(_) => n += 1,
                Err(_) => {}
            }
            if n >= cap {
                return n;
            }
        }
    }
    n
}

/// 按 apple-bundles 的规则判定目录能否作为 bundle，返回 (类型, Info.plist 路径)。
fn classify_bundle(dir: &Path) -> Option<(&'static str, std::path::PathBuf)> {
    let name = dir.file_name()?.to_string_lossy().to_string();
    let contents = dir.join("Contents");
    let shallow = !contents.is_dir();
    let app_plist = if shallow {
        dir.join("Info.plist")
    } else {
        contents.join("Info.plist")
    };
    let fw_deep = dir.join("Resources").join("Info.plist");
    let fw_shallow = dir.join("Info.plist");
    let fw = if !fw_deep.exists() && name.ends_with(".framework") && fw_shallow.exists() {
        fw_shallow
    } else {
        fw_deep
    };
    if fw.is_file() {
        return Some(("Framework", fw));
    }
    if app_plist.is_file() {
        let t = if name.ends_with(".app") { "App" } else { "Bundle" };
        return Some((t, app_plist));
    }
    None
}

/// 打印某个 bundle 的判定结果与主可执行文件存在性。
fn report_bundle(dir: &Path, tag: &str) {
    let Some((kind, plist)) = classify_bundle(dir) else {
        log_msg(&format!("bundle 诊断：{tag} 不可判定为 bundle"));
        return;
    };
    let contents = dir.join("Contents");
    let shallow = !contents.is_dir();
    let raw = fs::read(&plist).ok();
    let exe = raw
        .as_ref()
        .and_then(|b| plist::from_bytes::<plist::Value>(b).ok())
        .as_ref()
        .and_then(|v| v.as_dictionary())
        .and_then(|d| d.get("CFBundleExecutable"))
        .and_then(|x| x.as_string())
        .unwrap_or("")
        .to_string();
    let exe_path = if shallow {
        dir.join(&exe)
    } else {
        contents.join(&exe)
    };
    log_msg(&format!(
        "bundle 诊断：{tag} 类型={kind} shallow={shallow} Info.plist={} 可读={} 主可执行={} 存在={}",
        plist.display(),
        raw.is_some(),
        if exe.is_empty() { "(无)" } else { exe.as_str() },
        !exe.is_empty() && exe_path.exists()
    ));
    if kind == "Framework" && dir.join("Versions").exists() {
        log_msg(&format!("bundle 诊断：{tag} 含 Versions 目录（会被逐个版本签名）"));
    }
}

/// 枚举所有「能被判定为 bundle」的子目录（命中后不再深入其内部，
/// 与 apple-bundles 的 poisoned_prefixes 行为一致）。
fn find_bundle_candidates(root: &Path, dir: &Path, count: &mut usize, depth: usize) {
    if depth > 8 {
        return;
    }
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut subs: Vec<std::path::PathBuf> = Vec::new();
    for e in rd.flatten() {
        let p = e.path();
        if let Ok(md) = fs::symlink_metadata(&p) {
            if md.is_dir() && !md.file_type().is_symlink() {
                subs.push(p);
            }
        }
    }
    subs.sort();
    for p in subs {
        if classify_bundle(&p).is_some() {
            *count += 1;
            let rel = p
                .strip_prefix(root)
                .unwrap_or(&p)
                .to_string_lossy()
                .to_string();
            report_bundle(&p, &format!("嵌套 {rel}"));
            continue;
        }
        find_bundle_candidates(root, &p, count, depth + 1);
    }
}

fn walk_bundle(dir: &Path, files: &mut usize, links: &mut usize, broken: &mut Vec<String>) {
    let rd = match fs::read_dir(dir) {
        Ok(r) => r,
        Err(_) => return,
    };
    for e in rd.flatten() {
        let p = e.path();
        let md = match fs::symlink_metadata(&p) {
            Ok(m) => m,
            Err(_) => continue,
        };
        let ft = md.file_type();
        if ft.is_symlink() {
            *links += 1;
            // 跟随链接看目标是否真的存在；不存在即断链（apple-codesign 会 ENOENT）。
            if fs::metadata(&p).is_err() {
                let t = fs::read_link(&p)
                    .map(|x| x.to_string_lossy().to_string())
                    .unwrap_or_default();
                broken.push(format!("{} -> {}", p.display(), t));
            }
        } else if ft.is_dir() {
            walk_bundle(&p, files, links, broken);
        } else {
            *files += 1;
        }
    }
}

/// 签名失败后统计输出目录里已产出的内容，并按**写入顺序**（unix ctime）列出最后几个文件。
///
/// apple-codesign 是按 walkdir 排序逐个复制/签名的，所以「最后写入的那个文件」的
/// 后继就是出错点；若一个文件都没产出，说明失败发生在最开始的 bundle 判定阶段
/// （例如某个目录被误判成 bundle、按不存在的路径去读 Info.plist）。
fn report_partial_output(out_root: &Path) {
    let mut entries: Vec<(i64, i64, String, u64)> = Vec::new();
    let mut dirs = 0usize;
    let mut stack = vec![out_root.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            let Ok(md) = fs::symlink_metadata(&p) else { continue };
            if md.is_dir() {
                dirs += 1;
                stack.push(p);
            } else {
                #[cfg(unix)]
                let stamp = {
                    use std::os::unix::fs::MetadataExt;
                    (md.ctime(), md.ctime_nsec())
                };
                #[cfg(not(unix))]
                let stamp = (0i64, 0i64);
                entries.push((stamp.0, stamp.1, p.display().to_string(), md.len()));
            }
        }
    }
    log_msg(&format!(
        "签名中断：输出目录已产出文件 {} 个，子目录 {dirs} 个（{}）",
        entries.len(),
        out_root.display()
    ));
    entries.sort();
    for (_, _, p, n) in entries.iter().rev().take(5) {
        log_msg(&format!("签名中断：最后写入 {p}（{n} 字节）"));
    }
}

/// 从 .mobileprovision（CMS/DER 包裹的 XML plist）提取 Entitlements 字典，
/// 并序列化为完整 plist XML 供 `set_entitlements_xml` 使用。
fn extract_profile_entitlements(data: &[u8]) -> Result<String> {
    let plist = extract_embedded_plist(data)?;
    let value: plist::Value = plist::from_bytes(&plist)?;
    let dict = value
        .as_dictionary()
        .ok_or_else(|| anyhow::anyhow!("mobileprovision 顶层不是字典"))?;
    let ents = dict
        .get("Entitlements")
        .ok_or_else(|| anyhow::anyhow!("mobileprovision 缺少 Entitlements"))?;
    let mut out = Vec::new();
    plist::to_writer_xml(&mut out, ents)?;
    Ok(String::from_utf8(out)?)
}

/// 在 DER 编码的 mobileprovision 中定位连续存放的 XML plist 字节。
fn extract_embedded_plist(data: &[u8]) -> Result<Vec<u8>> {
    let start_marker: &[u8] = b"<?xml";
    let end_marker: &[u8] = b"</plist>";
    let start = data
        .windows(start_marker.len())
        .position(|w| w == start_marker)
        .ok_or_else(|| anyhow::anyhow!("mobileprovision 中未找到 plist"))?;
    let rest = &data[start..];
    let end = rest
        .windows(end_marker.len())
        .position(|w| w == end_marker)
        .ok_or_else(|| anyhow::anyhow!("mobileprovision 中 plist 未闭合"))?;
    Ok(data[start..start + end + end_marker.len()].to_vec())
}
