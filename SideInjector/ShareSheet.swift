import SwiftUI
import UIKit

/// 把已签名的 IPA 分享/保存到「文件」App，供 AltStore / SideStore 手动安装。
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    var excludedTypes: [UIActivity.ActivityType] = []

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        vc.excludedActivityTypes = excludedTypes
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
