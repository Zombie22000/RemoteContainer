import UIKit
import ReplayKit
import CoreMedia
import QuartzCore

final class FrameCapturer: NSObject {
    static let shared = FrameCapturer()

    private final class WeakView {
        weak var view: UIView?

        init(_ view: UIView) {
            self.view = view
        }
    }

    private static var viewsByProcessID: [Int32: WeakView] = [:]
    private let targetLock = NSLock()
    private var targetProcessID: Int32?
    private var processStates: [Int32: Bool] = [:]
    private var captureStartAttempted = false
    private var compressionQuality: CGFloat = 0.7
    private var capturedFrameCount = 0
    private var lastFailureLogTime: CFTimeInterval = 0
    private var lastFramePresentationTime = -Double.infinity
    private var activeGuestObserver: NSObjectProtocol?

    private override init() {
        super.init()
        activeGuestObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("RemoteActiveGuestChanged"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let processID = (notification.userInfo?["processID"] as? NSNumber)?.int32Value ?? 0
            self?.setActiveProcessID(processID)
        }
    }

    @objc(registerTargetView:processID:)
    class func registerTargetView(_ view: UIView, processID: Int32) {
        shared.targetLock.lock()
        viewsByProcessID[processID] = WeakView(view)
        if shared.processStates[processID] == nil {
            shared.processStates[processID] = false
        }
        shared.targetLock.unlock()
    }

    func startReplayKitCapture(compressionQuality: CGFloat = 0.7) {
        DispatchQueue.main.async { [weak self] in
            self?.beginReplayKitCapture(compressionQuality: compressionQuality)
        }
    }

    private func beginReplayKitCapture(compressionQuality: CGFloat) {
        targetLock.lock()
        guard !captureStartAttempted else {
            targetLock.unlock()
            return
        }
        captureStartAttempted = true
        self.compressionQuality = max(0.1, min(1.0, compressionQuality))
        targetLock.unlock()

        let recorder = RPScreenRecorder.shared()
        guard recorder.isAvailable else {
            NSLog("[RemoteContainer] ReplayKit capture is unavailable; capture will not be restarted during this launch")
            return
        }

        NSLog("[RemoteContainer] Starting the app-lifetime ReplayKit capture session")
        recorder.startCapture(
            handler: { [weak self] sampleBuffer, sampleType, error in
                if let error {
                    self?.logCaptureFailure("ReplayKit sample delivery failed: \(error.localizedDescription)")
                    return
                }
                guard sampleType == .video else { return }
                self?.processSampleBuffer(sampleBuffer)
            },
            completionHandler: { error in
                if let error {
                    NSLog("[RemoteContainer] ReplayKit capture could not start: %@", error.localizedDescription)
                } else {
                    NSLog("[RemoteContainer] ReplayKit capture started; the session will remain active across guest switches")
                }
            }
        )
    }

    @objc(setActiveProcessID:)
    func setActiveProcessID(_ processID: Int32) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.setActiveProcessID(processID)
            }
            return
        }

        targetLock.lock()
        let nextProcessID = processID > 0 ? processID : nil
        let previousProcessID = targetProcessID
        guard previousProcessID != nextProcessID else {
            targetLock.unlock()
            return
        }
        if let previousProcessID {
            processStates[previousProcessID] = false
        }
        targetProcessID = nextProcessID
        if let nextProcessID {
            processStates[nextProcessID] = true
        }
        let nextProcessHasView = nextProcessID.flatMap { Self.viewsByProcessID[$0]?.view } != nil
        targetLock.unlock()

        if let previousProcessID {
            NSLog("[RemoteContainer] Guest PID %d backgrounded; freezing its frame encoding and WebSocket stream",
                  previousProcessID)
        }
        if let nextProcessID {
            NSLog("[RemoteContainer] Guest PID %d activated; unfreezing its frame encoding and WebSocket stream",
                  nextProcessID)
            if !nextProcessHasView {
                NSLog("[RemoteContainer] No registered guest view found for active PID %d; ReplayKit will still capture the host window",
                      nextProcessID)
            }
        } else {
            NSLog("[RemoteContainer] No guest app is active; ReplayKit frames will be dropped")
        }
        NotificationCenter.default.post(
            name: .remoteGuestStreamStateChanged,
            object: self,
            userInfo: ["activeProcessID": NSNumber(value: nextProcessID ?? 0)]
        )
    }

    func isProcessActive(_ processID: Int32) -> Bool {
        targetLock.lock()
        defer { targetLock.unlock() }
        return processStates[processID] == true && targetProcessID == processID
    }

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
            logCaptureFailure("ReplayKit delivered an invalid or incomplete sample buffer")
            return
        }
        guard let processID = activeProcessID() else { return }

        let presentationTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if presentationTime.isFinite,
           lastFramePresentationTime.isFinite,
           presentationTime - lastFramePresentationTime < 1.0 / 30.0 {
            return
        }

        let startedAt = CACurrentMediaTime()
        guard let data = ReplayKitFrameEncoder.jpegData(from: sampleBuffer, quality: compressionQuality),
              !data.isEmpty else {
            logCaptureFailure("could not encode the ReplayKit video sample")
            return
        }
        guard isProcessActive(processID) else {
            NSLog("[RemoteContainer] Dropped a stale ReplayKit frame after guest PID %d switched out", processID)
            return
        }

        NotificationCenter.default.post(
            name: .remoteFrameCaptured,
            object: data,
            userInfo: ["processID": NSNumber(value: processID)]
        )
        if presentationTime.isFinite {
            lastFramePresentationTime = presentationTime
        }
        capturedFrameCount += 1
        if capturedFrameCount == 1 || capturedFrameCount.isMultiple(of: 120) {
            let elapsedMilliseconds = (CACurrentMediaTime() - startedAt) * 1_000
            NSLog("[RemoteContainer] ReplayKit frame %d encoded for PID %d in %.1f ms (%d bytes)",
                  capturedFrameCount, processID, elapsedMilliseconds, data.count)
        }
    }

    private func activeProcessID() -> Int32? {
        targetLock.lock()
        defer { targetLock.unlock() }
        return targetProcessID
    }

    private func logCaptureFailure(_ reason: String) {
        let now = CACurrentMediaTime()
        targetLock.lock()
        guard now - lastFailureLogTime >= 1 else {
            targetLock.unlock()
            return
        }
        lastFailureLogTime = now
        targetLock.unlock()
        NSLog("[RemoteContainer] ReplayKit frame capture failed: %@", reason)
    }

    deinit {
        if let activeGuestObserver {
            NotificationCenter.default.removeObserver(activeGuestObserver)
        }
    }
}

extension Notification.Name {
    static let remoteFrameCaptured = Notification.Name("RemoteFrameCaptured")
    static let remoteGuestStreamStateChanged = Notification.Name("RemoteGuestStreamStateChanged")
}
