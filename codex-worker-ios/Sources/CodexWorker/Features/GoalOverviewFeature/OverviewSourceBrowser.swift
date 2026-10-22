import SafariServices
import SwiftUI

/// Presents Safari modally; it is never embedded as a child controller.
struct OverviewSourcePresenter: UIViewControllerRepresentable {
    let url: URL?
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> SourcePresenterController {
        let controller = SourcePresenterController()
        controller.sourceURL = url
        controller.onDismiss = onDismiss
        return controller
    }

    func updateUIViewController(_ controller: SourcePresenterController, context: Context) {
        controller.sourceURL = url
        controller.onDismiss = onDismiss
        controller.presentSourceIfNeeded()
    }
}

@MainActor
final class SourcePresenterController: UIViewController, @preconcurrency SFSafariViewControllerDelegate {
    var sourceURL: URL?
    var onDismiss: (() -> Void)?
    private var browser: SFSafariViewController?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentSourceIfNeeded()
    }

    func presentSourceIfNeeded() {
        guard let url = sourceURL, viewIfLoaded?.window != nil,
              browser == nil, presentedViewController == nil else { return }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            let alert = UIAlertController(title: "无法打开链接", message: "来源地址无效。", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .cancel) { [weak self] _ in self?.onDismiss?() })
            present(alert, animated: true)
            return
        }
        let controller = SFSafariViewController(url: url)
        controller.delegate = self
        controller.dismissButtonStyle = .done
        controller.modalPresentationStyle = .fullScreen
        browser = controller
        present(controller, animated: true)
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        // Clear SwiftUI's destination before UIKit dismisses, so an update cannot reopen it.
        sourceURL = nil
        onDismiss?()
        controller.dismiss(animated: true) { [weak self] in self?.browser = nil }
    }

    func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
        guard !didLoadSuccessfully, controller.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "来源页面未能加载", message: "请重试，或交由浏览器打开。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "重试", style: .default) { [weak self, weak controller] _ in
            controller?.dismiss(animated: false) {
                self?.browser = nil
                self?.presentSourceIfNeeded()
            }
        })
        alert.addAction(UIAlertAction(title: "在浏览器中打开", style: .default) { [weak self] _ in
            guard let self, let url = self.sourceURL else { return }
            UIApplication.shared.open(url) { [weak self] accepted in
                guard !accepted else { return }
                Task { @MainActor [weak self] in self?.showSystemOpenFailure() }
            }
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        controller.present(alert, animated: true)
    }

    private func showSystemOpenFailure() {
        guard let browser, browser.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "无法打开链接", message: "系统未接受打开请求，请稍后重试。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .cancel))
        browser.present(alert, animated: true)
    }
}
