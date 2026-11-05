import Foundation
import Network
import UIKit
import Combine
import Darwin
import CryptoKit

private final class LatestFrameWebSocketSender: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RemoteContainer.LatestWebSocketFrame")
    private weak var connection: NWConnection?
    private let encodeFrame: (Data) -> Data
    private var latestFrame: Data?
    private var isActive: Bool
    private var isSending = false
    private var isStopped = false

    init(connection: NWConnection, isActive: Bool, encodeFrame: @escaping (Data) -> Data) {
        self.connection = connection
        self.isActive = isActive
        self.encodeFrame = encodeFrame
    }

    func setActive(_ active: Bool, processID: Int32) {
        queue.async {
            guard !self.isStopped, self.isActive != active else { return }
            self.isActive = active
            if !active {
                self.latestFrame = nil
            }
            NSLog("[RemoteContainer] WebSocket for PID %d %@; pending stale frame discarded",
                  processID, active ? "unfrozen" : "frozen")
            self.sendNextFrameIfNeeded()
        }
    }

    func offer(_ data: Data) {
        queue.async {
            guard !self.isStopped, self.isActive else { return }
            self.latestFrame = data
            self.sendNextFrameIfNeeded()
        }
    }

    func stop() {
        queue.async {
            self.isStopped = true
            self.latestFrame = nil
        }
    }

    private func sendNextFrameIfNeeded() {
        guard !isStopped, isActive, !isSending,
              let data = latestFrame,
              let connection else {
            return
        }

        latestFrame = nil
        isSending = true
        connection.send(content: encodeFrame(data), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                NSLog("[RemoteContainer] WebSocket frame send failed: %@", error.localizedDescription)
                self.connection?.cancel()
            }
            self.queue.async {
                self.isSending = false
                if error != nil {
                    self.isStopped = true
                    self.latestFrame = nil
                } else {
                    self.sendNextFrameIfNeeded()
                }
            }
        })
    }
}

/// A small LAN dashboard server for app metadata, launch requests, and IPA uploads.
final class RemoteServerManager: ObservableObject {
    static let shared = RemoteServerManager()
    private let queue = DispatchQueue(label: "RemoteContainer.HTTPServer")
    private var listener: NWListener?
    private var pathMonitor: NWPathMonitor?
    @Published private(set) var localIPv4Address: String?
    @Published private(set) var isRunning = false
    private let port: NWEndpoint.Port = 8080

    private init() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.refreshLocalIPv4Address()
        }
        self.pathMonitor = monitor
        monitor.start(queue: queue)
        refreshLocalIPv4Address()
    }

    func start() {
        guard listener == nil else { return }
        DispatchQueue.main.async { [weak self] in
            self?.startServer()
        }
    }

    private func startServer() {
        refreshLocalIPv4Address()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let server = try NWListener(using: parameters, on: port)
            server.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receiveRequest(on: connection, accumulated: Data())
            }
            server.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.refreshLocalIPv4Address()
                    DispatchQueue.main.async {
                        self?.isRunning = true
                    }
                    NSLog("[RemoteContainer] HTTP/WebSocket server listening on port %d", self?.port.rawValue ?? 8080)
                } else if case .failed(let error) = state {
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                    NSLog("[RemoteContainer] HTTP server failed: %@", error.localizedDescription)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                        self?.listener = nil
                        self?.start()
                    }
                } else if case .cancelled = state {
                    DispatchQueue.main.async {
                        self?.isRunning = false
                    }
                }
            }
            listener = server
            server.start(queue: queue)
        } catch {
            NSLog("[RemoteContainer] Could not start HTTP server: %@", error.localizedDescription)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.listener = nil
                self?.start()
            }
        }
    }

    private func refreshLocalIPv4Address() {
        let address = Self.findLocalIPv4Address()
        DispatchQueue.main.async {
            self.localIPv4Address = address
        }
    }

    private static func findLocalIPv4Address() -> String? {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let firstAddress = addresses else {
            return nil
        }
        defer { freeifaddrs(addresses) }

        var candidates: [(priority: Int, address: String)] = []
        var currentAddress: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let current = currentAddress {
            let interface = current.pointee
            currentAddress = interface.ifa_next
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0 else {
                continue
            }

            let name = String(cString: interface.ifa_name)
            guard name != "lo0", !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
                  !name.hasPrefix("utun") else {
                continue
            }

            let ipv4Address = unsafeBitCast(socketAddress.pointee, to: sockaddr_in.self).sin_addr
            var addressBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var mutableIPv4Address = ipv4Address
            guard inet_ntop(AF_INET, &mutableIPv4Address, &addressBuffer, socklen_t(addressBuffer.count)) != nil else {
                continue
            }
            let address = String(cString: addressBuffer)
            guard address != "0.0.0.0", !address.hasPrefix("127.") else {
                continue
            }

            let priority = name == "en0" ? 0 : name.hasPrefix("en") ? 1 : 2
            candidates.append((priority, address))
        }

        return candidates.min { $0.priority < $1.priority }?.address
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if let error {
                NSLog("[RemoteContainer] Could not receive HTTP request: %@", error.localizedDescription)
                self.respond(status: 400, type: "text/plain; charset=utf-8", body: Data("Bad Request".utf8), on: connection)
                return
            }
            if let headerRange = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: bytes[..<headerRange.lowerBound], as: UTF8.self)
                let bodyStart = headerRange.upperBound
                let requestLine = header.components(separatedBy: "\r\n").first ?? ""
                let requestParts = requestLine.split(separator: " ")
                if requestParts.count >= 2 {
                    let method = String(requestParts[0])
                    let path = String(requestParts[1].split(separator: "?", maxSplits: 1).first ?? "")
                    // WebSocket upgrade
                    if self.isWebSocketUpgrade(header: header) && (path == "/stream" || path == "/") {
                        self.upgradeToWebSocket(header: header, on: connection)
                        return
                    }
                    // HTTP GET requests
                    if method == "GET" {
                        if path == "/" || path == "/index.html" {
                            if let html = self.dashboardHTML() {
                                self.respond(status: 200, type: "text/html; charset=utf-8", body: html, on: connection)
                                return
                            } else {
                                self.respond(status: 500, type: "text/plain", body: Data("Dashboard asset missing".utf8), on: connection)
                                return
                            }
                        } else if path == "/stream" {
                            if let html = self.dashboardHTML() {
                                self.respond(status: 200, type: "text/html; charset=utf-8", body: html, on: connection)
                                return
                            } else {
                                self.respond(status: 404, type: "text/plain", body: Data(), on: connection)
                                return
                            }
                        } else if path.hasPrefix("/api/") {
                            // fall through to existing API handling
                        } else {
                            // Try to serve other static files or return 404
                            if let html = self.dashboardHTML() {
                                self.respond(status: 200, type: "text/html; charset=utf-8", body: html, on: connection)
                                return
                            }
                            self.respond(status: 404, type: "text/html; charset=utf-8", body: Data("<html><head><title>404</title></head><body><h1>404 Not Found</h1></body></html>".utf8), on: connection)
                            return
                        }
                    }
                } else {
                    self.respond(status: 400, type: "text/plain", body: Data("Bad Request".utf8), on: connection)
                    return
                }
                if requestParts.count >= 2,
                   requestParts[0] == "POST",
                   requestParts[1].split(separator: "?", maxSplits: 1).first == "/api/install" {
                    guard let contentLength = self.headerValue("content-length", in: header).flatMap(Int.init),
                          contentLength > 0 else {
                        self.respond(status: 400, type: "application/json", body: Data("{\"error\":\"A non-empty Content-Length is required\"}".utf8), on: connection)
                        return
                    }
                    guard contentLength <= 2 * 1_024 * 1_024 * 1_024 else {
                        self.respond(status: 413, type: "application/json", body: Data("{\"error\":\"IPA file is too large\"}".utf8), on: connection)
                        return
                    }
                    guard self.headerValue("content-type", in: header)?.lowercased().hasPrefix("application/octet-stream") == true else {
                        self.respond(status: 415, type: "application/json", body: Data("{\"error\":\"Expected an IPA file upload\"}".utf8), on: connection)
                        return
                    }
                    let uploadURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent("RemoteContainer-\(UUID().uuidString).ipa")
                    guard FileManager.default.createFile(atPath: uploadURL.path, contents: nil),
                          let fileHandle = try? FileHandle(forWritingTo: uploadURL) else {
                        self.respond(status: 500, type: "application/json", body: Data("{\"error\":\"Could not create temporary upload file\"}".utf8), on: connection)
                        return
                    }
                    let initialBody = Data(bytes[bodyStart...])
                    self.receiveUpload(on: connection, fileURL: uploadURL, fileHandle: fileHandle,
                                       remaining: contentLength, initialData: initialBody)
                    return
                }
                let contentLength = self.headerValue("content-length", in: header).flatMap(Int.init) ?? 0
                if bytes.count >= bodyStart + contentLength {
                    do {
                        try self.handle(header: header, body: Data(bytes[bodyStart..<(bodyStart + contentLength)]), on: connection)
                    } catch {
                        NSLog("[RemoteContainer] Could not process HTTP request: %@", error.localizedDescription)
                        self.respond(status: 500, type: "text/plain; charset=utf-8", body: Data("Internal Server Error".utf8), on: connection)
                    }
                } else {
                    self.receiveRequest(on: connection, accumulated: bytes)
                }
            } else if !complete && error == nil && bytes.count < 32_768 {
                self.receiveRequest(on: connection, accumulated: bytes)
            } else {
                NSLog("[RemoteContainer] Incomplete or oversized HTTP request (%d bytes)", bytes.count)
                self.respond(status: 400, type: "text/plain; charset=utf-8", body: Data("Bad Request".utf8), on: connection)
            }
        }
    }

    private func receiveUpload(on connection: NWConnection, fileURL: URL, fileHandle: FileHandle,
                               remaining: Int, initialData: Data = Data()) {
        do {
            let chunk = initialData.prefix(remaining)
            try fileHandle.write(contentsOf: chunk)
            let bytesRemaining = remaining - chunk.count
            guard bytesRemaining > 0 else {
                try fileHandle.close()
                respond(status: 202, type: "application/json", body: Data("{\"accepted\":true}".utf8), on: connection)
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .remoteContainerInstallIPA, object: fileURL)
                }
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: min(bytesRemaining, 65_536)) { [weak self] data, _, complete, error in
                guard let self else {
                    connection.cancel()
                    try? fileHandle.close()
                    try? FileManager.default.removeItem(at: fileURL)
                    return
                }
                guard let data, !data.isEmpty, error == nil else {
                    try? fileHandle.close()
                    try? FileManager.default.removeItem(at: fileURL)
                    self.respond(status: 400, type: "application/json", body: Data("{\"error\":\"IPA upload was interrupted\"}".utf8), on: connection)
                    return
                }
                if complete && data.count < bytesRemaining {
                    try? fileHandle.close()
                    try? FileManager.default.removeItem(at: fileURL)
                    self.respond(status: 400, type: "application/json", body: Data("{\"error\":\"IPA upload was interrupted\"}".utf8), on: connection)
                    return
                }
                self.receiveUpload(on: connection, fileURL: fileURL, fileHandle: fileHandle,
                                   remaining: bytesRemaining, initialData: data)
            }
        } catch {
            try? fileHandle.close()
            try? FileManager.default.removeItem(at: fileURL)
            NSLog("[RemoteContainer] Could not write IPA upload: %@", error.localizedDescription)
            respond(status: 500, type: "application/json", body: Data("{\"error\":\"Could not save IPA upload\"}".utf8), on: connection)
        }
    }

    private func headerValue(_ name: String, in header: String) -> String? {
        header.components(separatedBy: "\r\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == name else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }.first
    }

    private func isWebSocketUpgrade(header: String) -> Bool {
        let lower = header.lowercased()
        return lower.contains("upgrade: websocket") && lower.contains("sec-websocket-key")
    }

    private func requestedProcessID(in header: String) -> Int32? {
        guard let requestLine = header.components(separatedBy: "\r\n").first,
              let target = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(target)"),
              let pidValue = components.queryItems?.first(where: { $0.name == "pid" })?.value,
              let processID = Int32(pidValue), processID > 0 else {
            return nil
        }
        return processID
    }

    private func upgradeToWebSocket(header: String, on connection: NWConnection) {
        guard let key = self.headerValue("sec-websocket-key", in: header),
              let processID = requestedProcessID(in: header) else {
            respond(status: 400, type: "text/plain", body: Data(), on: connection)
            return
        }
        let accept = computeWebSocketAccept(key: key)
        let responseHeader = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let response = Data(responseHeader.utf8)
        connection.send(content: response, completion: .contentProcessed { [weak self, connection] error in
            if let error {
                NSLog("[RemoteContainer] Could not send WebSocket upgrade response: %@", error.localizedDescription)
                connection.cancel()
                return
            }
            guard let self else { return }
            self.setupWebSocket(on: connection, processID: processID)
        })
    }

    private func computeWebSocketAccept(key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = (key + magic).data(using: .utf8) ?? Data()
        let digest = Insecure.SHA1.hash(data: combined)
        return Data(digest).base64EncodedString()
    }

    private func setupWebSocket(on connection: NWConnection, processID: Int32) {
        let isStreamActive = FrameCapturer.shared.isProcessActive(processID)
        NSLog("[RemoteContainer] WebSocket for PID %d connected (%@)",
              processID, isStreamActive ? "unfrozen" : "frozen")

        let sender = LatestFrameWebSocketSender(
            connection: connection,
            isActive: isStreamActive
        ) { [weak self] data in
            self?.webSocketBinaryFrame(payload: data) ?? Data()
        }
        let streamID = FrameCapturer.shared.beginStreaming(processID: processID)
        let stateObserver = NotificationCenter.default.addObserver(
            forName: .remoteGuestStreamStateChanged,
            object: nil,
            queue: .main
        ) { notification in
            let activeProcessID = (notification.userInfo?["activeProcessID"] as? NSNumber)?.int32Value ?? 0
            sender.setActive(activeProcessID == processID, processID: processID)
        }

        let frameObserver = NotificationCenter.default.addObserver(
            forName: .remoteFrameCaptured,
            object: nil,
            queue: nil
        ) { [weak connection] notification in
            guard let connection = connection,
                  let frameProcessID = (notification.userInfo?["processID"] as? NSNumber)?.int32Value,
                  frameProcessID == processID,
                  FrameCapturer.shared.isProcessActive(processID),
                  let data = notification.object as? Data else { return }
            sender.offer(data)
        }

        connection.stateUpdateHandler = { state in
            if case .cancelled = state {
                NotificationCenter.default.removeObserver(stateObserver)
                NotificationCenter.default.removeObserver(frameObserver)
                sender.stop()
                FrameCapturer.shared.endStreaming(processID: processID, streamID: streamID)
                NSLog("[RemoteContainer] WebSocket for PID %d disconnected", processID)
            } else if case .failed(let error) = state {
                NotificationCenter.default.removeObserver(stateObserver)
                NotificationCenter.default.removeObserver(frameObserver)
                sender.stop()
                FrameCapturer.shared.endStreaming(processID: processID, streamID: streamID)
                NSLog("[RemoteContainer] WebSocket for PID %d failed: %@", processID, error.localizedDescription)
            }
        }
        receiveWebSocketFrame(on: connection)
    }

    private func webSocketBinaryFrame(payload: Data) -> Data {
        var frame = Data([0x82])
        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xff))
            frame.append(UInt8(payload.count & 0xff))
        } else {
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xff))
            }
        }
        frame.append(payload)
        return frame
    }

    private func receiveWebSocketFrame(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] headerData, _, _, error in
            guard let self, let headerData, headerData.count >= 2, error == nil else { return }
            let bytes = [UInt8](headerData)
            let payloadLen = Int(bytes[1] & 0x7F)
            var maskOffset = 2
            if payloadLen == 126 { maskOffset += 2 } else if payloadLen == 127 { maskOffset += 8 }
            // simplified receive
            self.receiveWebSocketFrame(on: connection)
        }
    }

    private func handle(header: String, body: Data, on connection: NWConnection) throws {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { respond(status: 400, type: "text/plain", body: Data(), on: connection); return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { respond(status: 400, type: "text/plain", body: Data(), on: connection); return }
        let method = String(parts[0]), path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")

        // WebSocket upgrade for /stream
        if self.isWebSocketUpgrade(header: header) && path == "/stream" {
            self.upgradeToWebSocket(header: header, on: connection)
            return
        } else if self.isWebSocketUpgrade(header: header), path == "/" {
            self.upgradeToWebSocket(header: header, on: connection)
            return
        }

        if method == "GET" && path == "/" {
            guard let html = dashboardHTML() else {
                respond(status: 500, type: "text/plain", body: Data("Dashboard asset missing".utf8), on: connection); return
            }
            respond(status: 200, type: "text/html; charset=utf-8", body: html, on: connection)
        } else if method == "GET" && (path == "/AppIcon1024.png" || path == "/app-icon.png") {
            let frameworkBundle = Bundle(for: RemoteServerManager.self)
            guard let iconURL = frameworkBundle.url(forResource: "AppIcon1024", withExtension: "png")
                    ?? Bundle.main.url(forResource: "AppIcon1024", withExtension: "png")
                    ?? resourceURL(named: "AppIcon1024", extension: "png", subdirectory: "Remote")
                    ?? resourceURL(named: "AppIcon1024", extension: "png") else {
                NSLog("[RemoteContainer] AppIcon1024.png was not found in the app or framework bundle")
                respond(status: 404, type: "text/plain", body: Data("App icon missing".utf8), on: connection)
                return
            }
            do {
                let source = try Data(contentsOf: iconURL)
                guard let png = UIImage(data: source)?.pngData() else {
                    NSLog("[RemoteContainer] Could not decode AppIcon1024.png at %@", iconURL.path)
                    respond(status: 500, type: "text/plain", body: Data("App icon could not be decoded".utf8), on: connection)
                    return
                }
                respond(status: 200, type: "image/png", body: png, on: connection)
            } catch {
                NSLog("[RemoteContainer] Could not read AppIcon1024.png at %@: %@", iconURL.path, error.localizedDescription)
                respond(status: 500, type: "text/plain", body: Data("App icon could not be read".utf8), on: connection)
            }
        } else if method == "GET" && path == "/api/apps" {
            let apps = DataManager.shared.model.apps.map { app -> [String: Any] in
                let iconData = app.appInfo.iconIsDarkIcon(false).jpegData(compressionQuality: 0.78)
                return ["name": app.displayName, "bundleId": app.bundleIdentifier,
                        "appId": app.appInfo.relativeBundlePath ?? app.bundleIdentifier, "version": app.version,
                        "pid": app.processID.map { NSNumber(value: $0) as Any } ?? NSNull(),
                        "running": app.isAppRunning, "canDelete": !app.appInfo.isShared && !app.isAppRunning,
                        "dataCount": app.appInfo.containers.count,
                        "icon": iconData.map { "data:image/jpeg;base64," + $0.base64EncodedString() } ?? ""]
            }
            let result = try JSONSerialization.data(withJSONObject: ["apps": apps])
            respond(status: 200, type: "application/json", body: result, on: connection)
        } else if method == "POST" && path == "/api/delete" {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let requestedId = json["appId"] as? String, !requestedId.isEmpty,
                  let app = DataManager.shared.model.apps.first(where: {
                      $0.appInfo.relativeBundlePath == requestedId
                  }) else {
                respond(status: 400, type: "application/json", body: Data("{\"error\":\"Unknown app\"}".utf8), on: connection); return
            }
            let deleteData = json["deleteData"] as? Bool ?? false
            guard !app.appInfo.isShared, !app.isAppRunning else {
                respond(status: 409, type: "application/json", body: Data("{\"error\":\"Shared or running apps cannot be deleted from the dashboard\"}".utf8), on: connection); return
            }
            guard let bundlePath = app.appInfo.bundlePath() else {
                respond(status: 404, type: "application/json", body: Data("{\"error\":\"App bundle not found\"}".utf8), on: connection); return
            }
            let bundleURL = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let appsDirectory = LCPath.bundlePath.standardizedFileURL
            guard bundleURL.pathExtension == "app",
                  bundleURL.path.hasPrefix(appsDirectory.path + "/") else {
                respond(status: 400, type: "application/json", body: Data("{\"error\":\"Invalid app bundle path\"}".utf8), on: connection); return
            }
            let dataURLs: [URL]
            if deleteData {
                let dataRoot = LCPath.dataPath.standardizedFileURL
                dataURLs = app.appInfo.containers.map {
                    dataRoot.appendingPathComponent($0.folderName).standardizedFileURL
                }
                guard dataURLs.allSatisfy({ $0.path.hasPrefix(dataRoot.path + "/") }) else {
                    respond(status: 400, type: "application/json", body: Data("{\"error\":\"Invalid app data path\"}".utf8), on: connection); return
                }
            } else {
                dataURLs = []
            }
            do {
                if deleteData {
                    for (container, dataURL) in zip(app.appInfo.containers, dataURLs) {
                        if FileManager.default.fileExists(atPath: dataURL.path) {
                            try FileManager.default.removeItem(at: dataURL)
                        }
                        LCUtils.removeAppKeychain(dataUUID: container.folderName)
                    }
                }
                try FileManager.default.removeItem(at: bundleURL)
                DispatchQueue.main.async {
                    DataManager.shared.model.apps.removeAll { $0 === app }
                    if deleteData {
                        let deletedDataUUIDs = Set(app.appInfo.containers.map(\.folderName))
                        DataManager.shared.model.appDataFolderNames.removeAll { deletedDataUUIDs.contains($0) }
                    }
                    self.respond(status: 200, type: "application/json", body: Data("{\"deleted\":true}".utf8), on: connection)
                }
            } catch {
                NSLog("[RemoteContainer] Could not delete app %@ or its data: %@", requestedId, error.localizedDescription)
                respond(status: 500, type: "application/json", body: Data("{\"error\":\"Could not delete app or its data\"}".utf8), on: connection)
            }
        } else if method == "POST" && path == "/api/stream/size" {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let processID = (json["pid"] as? NSNumber)?.int32Value,
                  let width = (json["width"] as? NSNumber)?.doubleValue,
                  let height = (json["height"] as? NSNumber)?.doubleValue,
                  processID > 0,
                  width.isFinite,
                  height.isFinite,
                  (1...10_000).contains(width),
                  (1...10_000).contains(height) else {
                respond(status: 400, type: "application/json",
                        body: Data("{\"error\":\"A valid PID and stream width/height are required\"}".utf8),
                        on: connection)
                return
            }
            DispatchQueue.main.async {
                guard #available(iOS 16.0, *) else {
                    self.respond(status: 409, type: "application/json",
                                 body: Data("{\"error\":\"Remote stream resizing requires virtual windows on iOS 16 or later\"}".utf8),
                                 on: connection)
                    return
                }
                let didResize = MultitaskDockManager.shared.resizeGuestWindowForStream(
                    processID: processID,
                    width: CGFloat(width),
                    height: CGFloat(height)
                )
                guard didResize else {
                    self.respond(status: 404, type: "application/json",
                                 body: Data("{\"error\":\"No multitasked guest window found for this PID\"}".utf8),
                                 on: connection)
                    return
                }
                self.respond(status: 200, type: "application/json",
                             body: Data("{\"resized\":true}".utf8),
                             on: connection)
            }
            return
        } else if method == "POST" && path == "/api/launch" {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  let requestedId = json["appId"] ?? json["bundleId"], !requestedId.isEmpty,
                  let app = DataManager.shared.model.apps.first(where: {
                      $0.appInfo.relativeBundlePath == requestedId || $0.bundleIdentifier == requestedId
                  }),
                  let appId = app.appInfo.relativeBundlePath else {
                respond(status: 400, type: "application/json", body: Data("{\"error\":\"Unknown app\"}".utf8), on: connection); return
            }
            Task { @MainActor in
                do {
                    try await app.runApp(multitask: true, containerFolderName: nil, urlStr: nil, forceJIT: nil)
                    guard let pid = app.processID else {
                        throw "LiveProcess did not return the multitasked app PID"
                    }
                    let result = try JSONSerialization.data(withJSONObject: ["accepted": true, "pid": pid])
                    self.respond(status: 202, type: "application/json", body: result, on: connection)
                } catch {
                    NSLog("[RemoteContainer] Remote dashboard launch failed for %@: %@", appId, error.localizedDescription)
                    let result = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription])
                    self.respond(status: 500, type: "application/json",
                                 body: result ?? Data("{\"error\":\"Launch failed\"}".utf8), on: connection)
                }
            }
            return
        } else if method == "GET" && path == "/stream" {
            if self.isWebSocketUpgrade(header: header) {
                self.upgradeToWebSocket(header: header, on: connection)
                return
            }
            if let html = dashboardHTML() {
                respond(status: 200, type: "text/html; charset=utf-8", body: html, on: connection)
                return
            } else {
                respond(status: 404, type: "text/plain", body: Data(), on: connection)
                return
            }
        } else {
            respond(status: 404, type: "application/json", body: Data("{\"error\":\"Not found\"}".utf8), on: connection)
            return
        }
    }

    private func dashboardHTML() -> Data? {
        let frameworkBundle = Bundle(for: RemoteServerManager.self)
        let urls = [
            resourceURL(named: "RemoteDashboard", extension: "html", subdirectory: "Remote"),
            resourceURL(named: "RemoteDashboard", extension: "html"),
            Bundle.main.url(forResource: "RemoteDashboard", withExtension: "html", subdirectory: "Remote"),
            frameworkBundle.url(forResource: "RemoteDashboard", withExtension: "html", subdirectory: "Remote"),
            Bundle.main.url(forResource: "RemoteDashboard", withExtension: "html"),
            frameworkBundle.url(forResource: "RemoteDashboard", withExtension: "html")
        ].compactMap { $0 }
        for url in urls {
            if let data = try? Data(contentsOf: url) { return data }
        }
        NSLog("[RemoteContainer] RemoteDashboard.html not found in %@ or %@", Bundle.main.bundleURL.path, frameworkBundle.bundleURL.path)
        return nil
    }

    private func resourceURL(named name: String, extension ext: String, subdirectory: String? = nil) -> URL? {
        let bundle = Bundle(for: RemoteServerManager.self)
        let candidates: [URL?] = [
            Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
            bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
            Bundle.main.url(forResource: name, withExtension: ext),
            bundle.url(forResource: name, withExtension: ext)
        ]
        return candidates.compactMap { $0 }.first
    }

    private func respond(status: Int, type: String, body: Data, on connection: NWConnection) {
        let phrase = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : status == 409 ? "Conflict" : status == 413 ? "Payload Too Large" : status == 415 ? "Unsupported Media Type" : "Internal Server Error"
        let header = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [connection] error in
            if let error {
                NSLog("[RemoteContainer] Could not send HTTP response headers: %@", error.localizedDescription)
                connection.cancel()
                return
            }
            guard !body.isEmpty else {
                connection.cancel()
                return
            }
            connection.send(content: body, completion: .contentProcessed { [connection] error in
                if let error {
                    NSLog("[RemoteContainer] Could not send HTTP response body: %@", error.localizedDescription)
                }
                connection.cancel()
            })
        })
    }
}

extension Notification.Name {
    static let remoteContainerLaunchApp = Notification.Name("RemoteContainerLaunchApp")
    static let remoteContainerInstallIPA = Notification.Name("RemoteContainerInstallIPA")
}
