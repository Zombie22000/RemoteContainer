import UIKit
import QuartzCore

class FrameCapturer {
    static let shared = FrameCapturer()
    private var displayLink: CADisplayLink?
    private var targetWindow: UIWindow?
    private var compressionQuality: CGFloat = 0.7
    
    private init() {}
    
    func startCapturing(compressionQuality: CGFloat = 0.7) {
        self.compressionQuality = compressionQuality
        stopCapturing()
        targetWindow = findGuestAppWindow()
        displayLink = CADisplayLink(target: self, selector: #selector(captureFrame))
        displayLink?.preferredFramesPerSecond = 30
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stopCapturing() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    private func findGuestAppWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            if let windowScene = scene as? UIWindowScene {
                for window in windowScene.windows {
                    if window.isHidden { continue }
                    if let rootVC = window.rootViewController {
                        let className = String(describing: type(of: rootVC))
                        if className.contains("LCTabView") {
                            continue
                        }
                    }
                    if window.bounds.size != UIScreen.main.bounds.size {
                        return window
                    }
                }
                if let window = windowScene.windows.first(where: { !$0.isHidden }) {
                    return window
                }
            }
        }
        for window in UIApplication.shared.windows {
            if !window.isHidden && window.rootViewController != nil {
                return window
            }
        }
        return nil
    }
    
    @objc private func captureFrame() {
        guard let window = targetWindow ?? findGuestAppWindow() else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            window.layer.render(in: context.cgContext)
        }
        guard let data = image.jpegData(compressionQuality: compressionQuality) else { return }
        NotificationCenter.default.post(name: .remoteFrameCaptured, object: data)
    }
}

extension Notification.Name {
    static let remoteFrameCaptured = Notification.Name("RemoteFrameCaptured")
}
