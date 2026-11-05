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

    static func jpegData(
        from sampleBuffer: CMSampleBuffer,
        contentRect: CGRect,
        windowBounds: CGRect,
        quality: CGFloat,
        maximumDimension: CGFloat = 1280
    ) -> Data? {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              !windowBounds.isEmpty,
              !contentRect.isEmpty else {
            return nil
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let scaleX = extent.width / windowBounds.width
        let scaleY = extent.height / windowBounds.height
        let topOffset = contentRect.minY - windowBounds.minY
        let cropRect = CGRect(
            x: extent.minX + (contentRect.minX - windowBounds.minX) * scaleX,
            y: extent.maxY - (topOffset + contentRect.height) * scaleY,
            width: contentRect.width * scaleX,
            height: contentRect.height * scaleY
        ).intersection(extent)
        guard !cropRect.isNull, !cropRect.isEmpty else { return nil }

        let croppedImage = image.cropped(to: cropRect).transformed(
            by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY)
        )
        let downscale = min(1, maximumDimension / max(cropRect.width, cropRect.height))
        let outputImage = croppedImage.transformed(by: CGAffineTransform(scaleX: downscale, y: downscale))
        let outputRect = CGRect(
            x: 0,
            y: 0,
            width: cropRect.width * downscale,
            height: cropRect.height * downscale
        ).integral

        guard let cgImage = ciContext.createCGImage(outputImage, from: outputRect),
              let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: quality),
              !data.isEmpty else {
            NSLog("[RemoteContainer] Could not crop and encode the active guest as JPEG")
            return nil
        }
        return data
    }
}
