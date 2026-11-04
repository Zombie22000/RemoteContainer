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
    private var previousValidFrame: Data?
    private var placeholderFrame: Data?
    private var placeholderPixelSize: CGSize = .zero
    private var lastFailureLogTime: CFTimeInterval = 0
    private var capturedFrameCount = 0
    
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

        stopCapturing()
        targetView = view
        targetProcessID = processID
        self.compressionQuality = max(0.1, min(1.0, compressionQuality))
        previousValidFrame = nil
        placeholderFrame = nil
        placeholderPixelSize = .zero
        capturedFrameCount = 0
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
        guard let window = targetView.window else {
            logCaptureFailure("target view is not attached to a window")
            return
        }
        guard let scene = window.windowScene, scene.activationState == .foregroundActive else {
            logCaptureFailure("target window is not attached to a foreground-active window scene")
            return
        }
        window.layoutIfNeeded()
        targetView.layoutIfNeeded()
        let bounds = targetView.bounds
        guard !bounds.isEmpty else {
            logCaptureFailure("target view has empty bounds")
            return
        }

        let startedAt = CACurrentMediaTime()
        let image = ViewFrameRenderer.capture(
            view: targetView,
            afterScreenUpdates: previousValidFrame == nil
        )
        if let image,
           let data = image.jpegData(compressionQuality: compressionQuality),
           !data.isEmpty {
            previousValidFrame = data
            NotificationCenter.default.post(name: .remoteFrameCaptured, object: data,
                                            userInfo: ["processID": NSNumber(value: targetProcessID)])
            capturedFrameCount += 1
            if capturedFrameCount == 1 || capturedFrameCount.isMultiple(of: 120) {
                let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
                NSLog("[RemoteContainer] Captured frame %d for PID %d in %.1f ms at %.0fx%.0f",
                      capturedFrameCount, targetProcessID, elapsedMilliseconds, image.size.width, image.size.height)
            }
            return
        }

        logCaptureFailure("rendered bitmap was empty, transparent, or uniformly white")
        let scale = max(1, window.screen.scale)
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if placeholderPixelSize != pixelSize || placeholderFrame == nil {
            let generatedPlaceholder = ViewFrameRenderer.placeholderFrame(
                bounds: CGRect(origin: .zero, size: bounds.size),
                scale: scale,
                compressionQuality: compressionQuality
            )
            if let generatedPlaceholder {
                placeholderFrame = generatedPlaceholder
                placeholderPixelSize = pixelSize
            } else {
                NSLog("[RemoteContainer] Could not encode the frame-capture placeholder for PID %d", targetProcessID)
            }
        }
        if let fallback = previousValidFrame ?? placeholderFrame {
            NotificationCenter.default.post(name: .remoteFrameCaptured, object: fallback,
                                            userInfo: ["processID": NSNumber(value: targetProcessID)])
        }
    }

    private func logCaptureFailure(_ reason: String) {
        let now = CACurrentMediaTime()
        guard now - lastFailureLogTime >= 1 else { return }
        lastFailureLogTime = now
        NSLog("[RemoteContainer] Frame capture for PID %d failed: %@; using the last valid frame or placeholder",
              targetProcessID ?? -1, reason)
    }
}

extension Notification.Name {
    static let remoteFrameCaptured = Notification.Name("RemoteFrameCaptured")
}
