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

@_silgen_name("si_install_ipa")
func si_install_ipa(_ ipa: UnsafePointer<CChar>) -> Int32

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
            (p12 ?? "").withCString { p in
                pw.withCString { w in
                    (prov ?? "").withCString { pr in
                        team.withCString { t in si_sign_bundle(a, p, w, pr, t) }
                    }
                }
            }
        }
    }

    func zip(dir: String, out: String) -> Int32 {
        dir.withCString { d in out.withCString { o in si_zip_ipa(d, o) } }
    }

    func install(ipa: String) -> Int32 {
        ipa.withCString { i in si_install_ipa(i) }
    }
}
