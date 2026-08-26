import SwiftUI
import SafariServices

// MARK: - In-App Browser

/// Presents a URL inside the app using SFSafariViewController — the same
/// Twitter/Reddit-style in-app browser that gives a full Safari experience
/// without leaving the app. Users can tap "Open in Safari" from the share
/// sheet to switch to the system browser at any time.
struct InAppBrowserView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true
        let vc = SFSafariViewController(url: url, configuration: config)
        vc.dismissButtonStyle = .close
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - URL Open Helper

/// Opens `url` respecting the user's in-app browser preference.
///
/// - If `useInAppBrowser` is `true` (default): presents `SFSafariViewController`
///   directly over the topmost `UIViewController` via UIKit. This works even
///   when other sheets are already on screen (sources sheet, settings, etc.)
///   because UIKit stacks on top of everything, bypassing SwiftUI's single-sheet
///   limitation. The full-screen slide-up gives the clean Twitter-style look with
///   no SwiftUI drag handle at the top.
/// - If `false`: opens in the system browser (Safari) directly.
func openURL(_ url: URL) {
    let useInApp = UserDefaults.standard.object(forKey: "useInAppBrowser") as? Bool ?? true
    guard useInApp, url.scheme == "http" || url.scheme == "https" else {
        UIApplication.shared.open(url)
        return
    }

    // Find the topmost presented UIViewController so we can present
    // SFSafariViewController on top of whatever is currently showing,
    // including any SwiftUI sheets (SourcesDetailSheet, etc.).
    guard let rootVC = UIApplication.shared.connectedScenes
        .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
        .first?.rootViewController else {
        // Fallback to system browser if no window found
        UIApplication.shared.open(url)
        return
    }

    // Walk up the presentation stack to find the topmost VC
    var topVC = rootVC
    while let presented = topVC.presentedViewController {
        topVC = presented
    }

    let config = SFSafariViewController.Configuration()
    config.entersReaderIfAvailable = false
    config.barCollapsingEnabled = true
    let vc = SFSafariViewController(url: url, configuration: config)
    vc.dismissButtonStyle = .close
    // .overFullScreen gives the clean full-screen slide-up (Twitter-style)
    // with no drag handle or rounded corners at the top.
    vc.modalPresentationStyle = .overFullScreen

    topVC.present(vc, animated: true)
}
