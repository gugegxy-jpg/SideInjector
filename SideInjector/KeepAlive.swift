import AVFoundation

/// 配对期间的后台保活。
///
/// 为什么需要：设备端自配对要求 App 在本机广播 Bonjour（`_remotepairing-pairable-host._tcp`），
/// 而用户必须切到「设置 → 开发者 → 配对」去选择本 App。App 一旦退到后台，系统会在数秒内
/// 将其挂起，mDNS 注册随之失效，于是「设置」里搜不到本 App、无法配对。
///
/// 做法：声明后台音频模式（`UIBackgroundModes: audio`）并循环播放一段**静音** PCM，
/// 使 AVAudioSession 处于「正在播放」状态，进程得以在后台存活，广播持续有效。
/// 仅在配对流程期间启用，结束即停（见 PairingController）。
///
/// 注意：这是为侧载场景准备的手段；上架 App Store 时后台音频必须用于真实播放，勿沿用。
final class KeepAlive {
    static let shared = KeepAlive()
    private var player: AVAudioPlayer?

    private init() {}

    var isActive: Bool { player != nil }

    func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: Self.silentWav(seconds: 1))
            p.numberOfLoops = -1      // 无限循环
            p.volume = 0              // 静音
            p.prepareToPlay()
            guard p.play() else {
                LogStore.shared.append("KeepAlive：静音播放启动失败")
                return
            }
            player = p
            LogStore.shared.append("KeepAlive 已启动（配对期间保持后台广播）")
        } catch {
            LogStore.shared.append("KeepAlive 启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        LogStore.shared.append("KeepAlive 已停止")
    }

    /// 生成一段 16-bit PCM 的单声道静音 WAV（内容全 0）。
    private static func silentWav(seconds: Int) -> Data {
        let sampleRate = 8000
        let channels = 1
        let bitsPerSample = 16
        let dataSize = sampleRate * seconds * channels * bitsPerSample / 8

        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

        d.append(contentsOf: Array("RIFF".utf8))
        le32(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        le32(16)                                                            // fmt chunk size
        le16(1)                                                             // PCM
        le16(UInt16(channels))
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * channels * bitsPerSample / 8))             // byte rate
        le16(UInt16(channels * bitsPerSample / 8))                          // block align
        le16(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        le32(UInt32(dataSize))
        d.append(Data(count: dataSize))                                     // 静音样本
        return d
    }
}
