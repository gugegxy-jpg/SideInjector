import Foundation

// 与 Rust core 的 FFI 对应（函数名即 Rust 的 #[no_mangle] 符号）
@_silgen_name("si_set_log_callback")
func si_set_log_callback(_ cb: @escaping @convention(c) (UnsafePointer<CChar>) -> Void)

@_silgen_name("si_unzip_ipa")
func si_unzip_ipa(_ ipa: UnsafePointer<CChar>, _ out: UnsafePointer<CChar>) -> Int32

@_silgen_name("si_inject_dylib")
func si_inject_dylib(_ app: UnsafePointer<CChar>, _ src: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>) -> Int32

@_silgen_name("si_sign_bundle")
func si_sign_bundle(_ app: UnsafePointer<CChar>, _ p12: UnsafePointer<CChar>?, _ pw: UnsafePointer<CChar>, _ prov: UnsafePointer<CChar>?, _ team: UnsafePointer<CChar>?) -> Int32

@_silgen_name("si_zip_ipa")
func si_zip_ipa(_ dir: UnsafePointer<CChar>, _ out: UnsafePointer<CChar>) -> Int32

@_silgen_name("si_set_bundle_info")
func si_set_bundle_info(_ app: UnsafePointer<CChar>, _ bundleId: UnsafePointer<CChar>?, _ displayName: UnsafePointer<CChar>?) -> Int32

@_silgen_name("si_install_ipa")
func si_install_ipa(_ ipa: UnsafePointer<CChar>) -> Int32

@_silgen_name("si_install_progress")
func si_install_progress() -> Int32

@_silgen_name("si_pairing_start")
func si_pairing_start(_ outPath: UnsafePointer<CChar>) -> Int32

@_silgen_name("si_pairing_status")
func si_pairing_status() -> Int32

@_silgen_name("si_pairing_service_port")
func si_pairing_service_port() -> Int32

@_silgen_name("si_pairing_service_identifier")
func si_pairing_service_identifier() -> UnsafePointer<CChar>?

@_silgen_name("si_pairing_txt_json")
func si_pairing_txt_json() -> UnsafePointer<CChar>?

@_silgen_name("si_pairing_pin")
func si_pairing_pin() -> UnsafePointer<CChar>?

@_silgen_name("si_pairing_device_name")
func si_pairing_device_name() -> UnsafePointer<CChar>?

@_silgen_name("si_pairing_error")
func si_pairing_error() -> UnsafePointer<CChar>?

@_silgen_name("si_string_free")
func si_string_free(_ p: UnsafeMutablePointer<CChar>?)

final class RustBridge {
    static let shared = RustBridge()
    private var logCb: (@convention(c) (UnsafePointer<CChar>) -> Void)?

    private init() {
        let cb: @convention(c) (UnsafePointer<CChar>) -> Void = { ptr in
            if let s = String(validatingUTF8: ptr) {
                LogStore.shared.append(s)
            }
        }
        logCb = cb
        si_set_log_callback(cb)
    }

    func unzip(ipa: String, out: String) -> Int32 {
        ipa.withCString { a in out.withCString { o in si_unzip_ipa(a, o) } }
    }

    func inject(app: String, dylib src: String, name: String) -> Int32 {
        app.withCString { a in src.withCString { s in name.withCString { n in si_inject_dylib(a, s, n) } } }
    }

    func sign(app: String, p12: String?, pw: String, prov: String?, team: String) -> Int32 {
        app.withCString { a in
            pw.withCString { w in
                team.withCString { t in
                    // 空字符串视为未选择，传 NULL 让 Rust 给出明确的「缺少证书/描述文件」报错，
                    // 而不是 fs::read("") 报出误导性的 “no such file or directory”。
                    if let p = p12, !p.isEmpty {
                        return p.withCString { pc in
                            if let pr = prov, !pr.isEmpty {
                                return pr.withCString { prc in si_sign_bundle(a, pc, w, prc, t) }
                            }
                            return si_sign_bundle(a, pc, w, nil, t)
                        }
                    } else if let pr = prov, !pr.isEmpty {
                        return pr.withCString { prc in si_sign_bundle(a, nil, w, prc, t) }
                    } else {
                        return si_sign_bundle(a, nil, w, nil, t)
                    }
                }
            }
        }
    }

    func zip(dir: String, out: String) -> Int32 {
        dir.withCString { d in out.withCString { o in si_zip_ipa(d, o) } }
    }

    func setBundleInfo(app: String, bundleId: String, displayName: String) -> Int32 {
        app.withCString { a in
            bundleId.withCString { b in
                displayName.withCString { d in si_set_bundle_info(a, b, d) }
            }
        }
    }

    func install(ipa: String) -> Int32 {
        ipa.withCString { i in si_install_ipa(i) }
    }

    /// 安装进度（-1=未开始/失败，0…100）。设备端安装由 Rust 走 RSD 链路，进度靠轮询。
    func installProgress() -> Int32 { si_install_progress() }

    // MARK: - 设备端自配对

    func pairingStart(outPath: String) -> Int32 {
        outPath.withCString { si_pairing_start($0) }
    }

    func pairingStatus() -> Int32 { si_pairing_status() }

    func pairingServicePort() -> Int32 { si_pairing_service_port() }

    private func pairingString(_ f: () -> UnsafePointer<CChar>?) -> String? {
        guard let p = f() else { return nil }
        defer { si_string_free(UnsafeMutablePointer(mutating: p)) }
        return String(cString: p)
    }

    func pairingServiceIdentifier() -> String? { pairingString { si_pairing_service_identifier() } }
    func pairingTxtJSON() -> String? { pairingString { si_pairing_txt_json() } }
    func pairingPIN() -> String? { pairingString { si_pairing_pin() } }
    func pairingDeviceName() -> String? { pairingString { si_pairing_device_name() } }
    func pairingError() -> String? { pairingString { si_pairing_error() } }
}
