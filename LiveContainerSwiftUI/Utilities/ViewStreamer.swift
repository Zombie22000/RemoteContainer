import UIKit
import ReplayKit
import CoreImage
import CoreMedia
import CoreVideo

protocol ViewStreamerDelegate: AnyObject {
    func viewStreamer(_ viewStreamer: ViewStreamer, didCaptureFrame data: Data)
}

final class ViewStreamer: NSObject {
    weak var delegate: ViewStreamerDelegate?
    private let compressionQuality: CGFloat
    private var frameObserver: NSObjectProtocol?

    init(compressionQuality: CGFloat = 0.7) {
        self.compressionQuality = max(0.1, min(1.0, compressionQuality))
        super.init()
    }

    func start() {
        guard frameObserver == nil else { return }
        frameObserver = NotificationCenter.default.addObserver(
            forName: .remoteFrameCaptured,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let data = notification.object as? Data,
                  !data.isEmpty else { return }
            self.delegate?.viewStreamer(self, didCaptureFrame: data)
        }
        FrameCapturer.shared.startReplayKitCapture(compressionQuality: compressionQuality)
    }

    func stop() {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }
    }

    deinit {
        stop()
    }
}

enum ReplayKitFrameEncoder {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func jpegData(from sampleBuffer: CMSampleBuffer, quality: CGFloat) -> Data? {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(pixelBuffer) > 0,
              CVPixelBufferGetHeight(pixelBuffer) > 0 else {
            return nil
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        do {
            return try ciContext.jpegRepresentation(
                of: image,
                colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [.lossyCompressionQuality: quality]
            )
        } catch {
            NSLog("[RemoteContainer] Could not encode ReplayKit sample as JPEG: %@", error.localizedDescription)
            return nil
        }
    }
}
