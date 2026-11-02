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

    init(targetView: UIView, compressionQuality: CGFloat = 0.7) {
        self.targetView = targetView
        self.compressionQuality = max(0.1, min(1.0, compressionQuality))
        let bounds = targetView.bounds
        self.renderer = UIGraphicsImageRenderer(bounds: bounds)
        super.init()
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
