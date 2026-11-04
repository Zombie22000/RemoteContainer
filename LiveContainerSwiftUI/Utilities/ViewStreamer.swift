import UIKit
import QuartzCore

protocol ViewStreamerDelegate: AnyObject {
    func viewStreamer(_ viewStreamer: ViewStreamer, didCaptureFrame data: Data)
}

final class ViewStreamer: NSObject {
    weak var delegate: ViewStreamerDelegate?
    private weak var targetView: UIView?
    private var displayLink: CADisplayLink?
    private let compressionQuality: CGFloat
    private var previousValidFrame: Data?
    private var placeholderFrame: Data?
    private var placeholderPixelSize: CGSize = .zero
    private var capturedFrameCount = 0
    private var lastFailureLogTime: CFTimeInterval = 0
    private var lastReadinessState: String?

    init(targetView: UIView? = nil, compressionQuality: CGFloat = 0.7) {
        let resolvedView = targetView ?? Self.findGuestAppWindow() ?? UIView(frame: .zero)
        self.targetView = resolvedView
        self.compressionQuality = max(0.1, min(1.0, compressionQuality))
        super.init()
    }

    private static func findGuestAppWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }

        for scene in scenes {
            for window in scene.windows.reversed()
            where !window.isHidden && window != scene.keyWindow {
                return window
            }
            if let window = scene.windows.first(where: { !$0.isHidden && $0.rootViewController != nil }) {
                return window
            }
        }
        return nil
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(captureFrame))
        link.preferredFramesPerSecond = 30
        link.add(to: .main, forMode: .common)
        displayLink = link
        NSLog("[RemoteContainer] View stream started; waiting for an active, laid-out target view")
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        lastReadinessState = nil
        NSLog("[RemoteContainer] View stream stopped after %d valid frames", capturedFrameCount)
    }

    @objc private func captureFrame() {
        guard let targetView else {
            logReadiness("target view was released")
            stop()
            return
        }
        guard let window = targetView.window else {
            logReadiness("target view is not attached to a window")
            return
        }
        guard let scene = window.windowScene, scene.activationState == .foregroundActive else {
            logReadiness("target window is not attached to a foreground-active window scene")
            return
        }
        window.layoutIfNeeded()
        targetView.layoutIfNeeded()
        guard !targetView.bounds.isEmpty else {
            logReadiness("target view has empty bounds")
            return
        }
        if #available(iOS 16.0, *),
           let hostView = targetView as? VirtualWindowsHostView,
           !hostView.readyForStreaming {
            logReadiness("virtual window host has not completed its initial layout")
            return
        }
        logReadiness("ready")

        let startedAt = CACurrentMediaTime()
        let bounds = CGRect(origin: .zero, size: targetView.bounds.size)
        let scale = max(1, window.screen.scale)
        let image = ViewFrameRenderer.capture(
            view: targetView,
            afterScreenUpdates: previousValidFrame == nil
        )

        if let image, let data = image.jpegData(compressionQuality: compressionQuality), !data.isEmpty {
            previousValidFrame = data
            delegate?.viewStreamer(self, didCaptureFrame: data)
            capturedFrameCount += 1
            if capturedFrameCount == 1 || capturedFrameCount.isMultiple(of: 120) {
                let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
                NSLog("[RemoteContainer] View frame %d rendered in %.1f ms at %.0fx%.0f (scale %.2f)",
                      capturedFrameCount, elapsedMilliseconds, image.size.width, image.size.height, scale)
            }
        } else {
            logCaptureFailure("rendered bitmap was empty, transparent, or uniformly white")
            let fallback = previousValidFrame ?? placeholderFrameFor(bounds: bounds, scale: scale)
            if let fallback {
                delegate?.viewStreamer(self, didCaptureFrame: fallback)
            }
        }
    }

    private func placeholderFrameFor(bounds: CGRect, scale: CGFloat) -> Data? {
        let pixelSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if placeholderPixelSize == pixelSize, let placeholderFrame {
            return placeholderFrame
        }
        guard let data = ViewFrameRenderer.placeholderFrame(
            bounds: bounds,
            scale: scale,
            compressionQuality: compressionQuality
        ) else {
            NSLog("[RemoteContainer] Could not encode the view-stream placeholder frame")
            return nil
        }
        placeholderPixelSize = pixelSize
        placeholderFrame = data
        return data
    }

    private func logReadiness(_ state: String) {
        guard lastReadinessState != state else { return }
        lastReadinessState = state
        NSLog("[RemoteContainer] View stream waiting: %@", state)
    }

    private func logCaptureFailure(_ reason: String) {
        let now = CACurrentMediaTime()
        guard now - lastFailureLogTime >= 1 else { return }
        lastFailureLogTime = now
        NSLog("[RemoteContainer] View frame capture failed: %@; using the last valid frame or placeholder", reason)
    }

    deinit {
        displayLink?.invalidate()
    }
}

enum ViewFrameRenderer {
    static func capture(view: UIView, afterScreenUpdates: Bool) -> UIImage? {
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        guard !bounds.isEmpty, let window = view.window else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, window.screen.scale)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)

        var hierarchyRendered = false
        let hierarchyImage = renderer.image { _ in
            hierarchyRendered = view.drawHierarchy(in: bounds, afterScreenUpdates: afterScreenUpdates)
        }
        if hierarchyRendered, isUsableFrame(hierarchyImage) {
            return hierarchyImage
        }

        let layerImage = renderer.image { context in
            view.layer.render(in: context.cgContext)
        }
        return isUsableFrame(layerImage) ? layerImage : nil
    }

    static func placeholderFrame(bounds: CGRect, scale: CGFloat, compressionQuality: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { context in
            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(bounds)
            let message = "Waiting for app content"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14),
                .foregroundColor: UIColor(white: 0.8, alpha: 1)
            ]
            let messageSize = (message as NSString).size(withAttributes: attributes)
            let messageRect = CGRect(
                x: bounds.midX - messageSize.width / 2,
                y: bounds.midY - messageSize.height / 2,
                width: messageSize.width,
                height: messageSize.height
            )
            (message as NSString).draw(in: messageRect, withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: compressionQuality)
    }

    static func isUsableFrame(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else {
            return false
        }

        let sampleWidth = min(cgImage.width, 16)
        let sampleHeight = min(cgImage.height, 16)
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let renderedPixels = pixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let baseAddress = pixelBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: sampleWidth,
                    height: sampleHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: sampleWidth * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard renderedPixels else {
            return false
        }

        var allTransparent = true
        var uniformlyWhite = true
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = pixels[offset]
            let green = pixels[offset + 1]
            let blue = pixels[offset + 2]
            let alpha = pixels[offset + 3]
            if alpha > 8 {
                allTransparent = false
            }
            if red < 245 || green < 245 || blue < 245 || alpha < 245 {
                uniformlyWhite = false
            }
        }
        return !allTransparent && !uniformlyWhite
    }
}
