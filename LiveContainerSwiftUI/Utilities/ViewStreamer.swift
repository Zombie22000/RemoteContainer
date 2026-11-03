import UIKit
import QuartzCore

protocol ViewStreamerDelegate: AnyObject {
    func viewStreamer(_ viewStreamer: ViewStreamer, didCaptureFrame data: Data)
}

final class ViewStreamer: NSObject {
    weak var delegate: ViewStreamerDelegate?
    private weak var targetView: UIView?
    private var displayLink: CADisplayLink?
    private let renderer: UIGraphicsImageRenderer
    private let compressionQuality: CGFloat

    init(targetView: UIView? = nil, compressionQuality: CGFloat = 0.7) {
        // Try to find guest app window if targetView not provided
        let resolvedView: UIView
        if let targetView = targetView {
            resolvedView = targetView
        } else if let window = Self.findGuestAppWindow() {
            resolvedView = window
        } else {
            resolvedView = UIView(frame: .zero)
        }
        self.targetView = resolvedView
        self.compressionQuality = max(0.1, min(1.0, compressionQuality))
        let bounds = resolvedView.bounds.isEmpty ? UIScreen.main.bounds : resolvedView.bounds
        self.renderer = UIGraphicsImageRenderer(bounds: bounds)
        super.init()
    }

    private static func findGuestAppWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene {
                // Prefer windows that are not the main dashboard/multitask windows
                for window in windowScene.windows.reversed() {
                    let rootVC = window.rootViewController
                    // Skip if it's the main app's root or multitask dock
                    if rootVC?.nibName == nil && rootVC?.children.isEmpty == false {
                        // Could be guest app container
                    }
                    // Prefer windows that are not key window of main app in some cases
                    if !window.isHidden && window.frame != UIScreen.main.bounds {
                        return window
                    }
                }
                // Fallback to any visible window
                if let window = windowScene.windows.first(where: { !$0.isHidden && $0.rootViewController != nil }) {
                    return window
                }
            }
        }
        return UIApplication.shared.windows.first
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(captureFrame))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func captureFrame() {
        guard let targetView = targetView else {
            stop()
            return
        }
        let image = renderer.image { context in
            targetView.layer.render(in: context.cgContext)
        }
        guard let data = image.jpegData(compressionQuality: compressionQuality) else { return }
        delegate?.viewStreamer(self, didCaptureFrame: data)
    }

    deinit {
        stop()
    }
}
