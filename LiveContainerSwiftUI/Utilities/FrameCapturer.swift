import UIKit
import QuartzCore

class FrameCapturer: NSObject {
    static let shared = FrameCapturer()
    private final class WeakView {
        weak var view: UIView?

        init(_ view: UIView) {
            self.view = view
        }
    }

    private static var viewsByProcessID: [Int32: WeakView] = [:]
    private var displayLink: CADisplayLink?
    private let targetLock = NSLock()
    private var targetView: UIView?
    private var targetProcessID: Int32?
    private var compressionQuality: CGFloat = 0.7
    
    private override init() {
        super.init()
    }

    @objc(registerTargetView:processID:)
    class func registerTargetView(_ view: UIView, processID: Int32) {
        shared.targetLock.lock()
        viewsByProcessID[processID] = WeakView(view)
        shared.targetLock.unlock()
    }

    func startCapturing(processID: Int32, compressionQuality: CGFloat = 0.7) -> Bool {
        targetLock.lock()
        let view = Self.viewsByProcessID[processID]?.view
        targetLock.unlock()
        guard let view else {
            NSLog("[RemoteContainer] No multitask scene view registered for PID %d", processID)
            return false
        }

        self.compressionQuality = compressionQuality
        stopCapturing()
        targetView = view
        targetProcessID = processID
        displayLink = CADisplayLink(target: self, selector: #selector(captureFrame))
        displayLink?.preferredFramesPerSecond = 30
        displayLink?.add(to: .main, forMode: .common)
        return true
    }
    
    func stopCapturing() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func captureFrame() {
        guard let targetView, let targetProcessID else { return }
        let renderer = UIGraphicsImageRenderer(bounds: targetView.bounds)
        let image = renderer.image { context in
            targetView.layer.render(in: context.cgContext)
        }
        guard let data = image.jpegData(compressionQuality: compressionQuality) else { return }
        NotificationCenter.default.post(name: .remoteFrameCaptured, object: data,
                                        userInfo: ["processID": NSNumber(value: targetProcessID)])
    }
}

extension Notification.Name {
    static let remoteFrameCaptured = Notification.Name("RemoteFrameCaptured")
}
