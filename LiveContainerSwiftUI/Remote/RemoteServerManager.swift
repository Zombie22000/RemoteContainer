import Foundation
import Network
import UIKit

/// A small LAN dashboard server. It intentionally exposes only app metadata and launch requests.
final class RemoteServerManager {
    static let shared = RemoteServerManager()
    private let queue = DispatchQueue(label: "RemoteContainer.HTTPServer")
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8080

    private init() {}

    func start() {
        guard listener == nil else { return }
        do {
            let server = try NWListener(using: .tcp, on: port)
            server.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receiveRequest(on: connection, accumulated: Data())
            }
            server.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("[RemoteContainer] HTTP server failed: %@", error.localizedDescription)
                }
            }
            listener = server
            server.start(queue: queue)
        } catch {
            NSLog("[RemoteContainer] Could not start HTTP server: %@", error.localizedDescription)
        }
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            if let data { bytes.append(data) }
            if let headerRange = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: bytes[..<headerRange.lowerBound], as: UTF8.self)
                let bodyStart = headerRange.upperBound
                let contentLength = header.components(separatedBy: "\r\n").compactMap { line -> Int? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return Int(parts[1].trimmingCharacters(in: .whitespaces))
                }.first ?? 0
                if bytes.count >= bodyStart + contentLength {
                    self.handle(header: header, body: Data(bytes[bodyStart..<(bodyStart + contentLength)]), on: connection)
                } else {
                    self.receiveRequest(on: connection, accumulated: bytes)
                }
            } else if !complete && error == nil && bytes.count < 32_768 {
                self.receiveRequest(on: connection, accumulated: bytes)
            } else {
                self.respond(status: 400, type: "application/json", body: Data("{\"error\":\"Invalid request\"}".utf8), on: connection)
            }
        }
    }

    private func handle(header: String, body: Data, on connection: NWConnection) {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { respond(status: 400, type: "text/plain", body: Data(), on: connection); return }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { respond(status: 400, type: "text/plain", body: Data(), on: connection); return }
        let method = String(parts[0]), path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")

        if method == "GET" && path == "/" {
            guard let html = dashboardHTML() else {
                respond(status: 500, type: "text/plain", body: Data("Dashboard asset missing".utf8), on: connection); return
            }
            respond(status: 200, type: "text/html; charset=utf-8", body: html, on: connection)
        } else if method == "GET" && path == "/api/apps" {
            let apps = DataManager.shared.model.apps.map { app -> [String: Any] in
                let iconData = app.appInfo.iconIsDarkIcon(false).jpegData(compressionQuality: 0.78)
                return ["name": app.displayName, "bundleId": app.bundleIdentifier, "version": app.version,
                        "running": app.isAppRunning, "icon": iconData.map { "data:image/jpeg;base64," + $0.base64EncodedString() } ?? ""]
            }
            guard let result = try? JSONSerialization.data(withJSONObject: ["apps": apps]) else {
                respond(status: 500, type: "application/json", body: Data("{\"error\":\"Could not encode app list\"}".utf8), on: connection); return
            }
            respond(status: 200, type: "application/json", body: result, on: connection)
        } else if method == "POST" && path == "/api/launch" {
            guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: String],
                  let bundleId = json["bundleId"], !bundleId.isEmpty,
                  DataManager.shared.model.apps.contains(where: { $0.appInfo.relativeBundlePath == bundleId }) else {
                respond(status: 400, type: "application/json", body: Data("{\"error\":\"Unknown app\"}".utf8), on: connection); return
            }
            respond(status: 202, type: "application/json", body: Data("{\"accepted\":true}".utf8), on: connection)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .remoteContainerLaunchApp, object: bundleId)
            }
        } else if method == "GET" && path == "/stream" {
            if let html = dashboardHTML() {
                respond(status: 200, type: "text/html; charset=utf-8", body: html, on: connection)
            } else { respond(status: 404, type: "text/plain", body: Data(), on: connection) }
        } else {
            respond(status: 404, type: "application/json", body: Data("{\"error\":\"Not found\"}".utf8), on: connection)
        }
    }

    private func dashboardHTML() -> Data? {
        let frameworkBundle = Bundle(for: RemoteServerManager.self)
        let urls = [
            Bundle.main.url(forResource: "RemoteDashboard", withExtension: "html"),
            frameworkBundle.url(forResource: "RemoteDashboard", withExtension: "html"),
            Bundle.main.url(forResource: "RemoteDashboard", withExtension: "html", subdirectory: "Remote"),
            frameworkBundle.url(forResource: "RemoteDashboard", withExtension: "html", subdirectory: "Remote")
        ].compactMap { $0 }
        for url in urls {
            if let data = try? Data(contentsOf: url) { return data }
        }
        NSLog("[RemoteContainer] RemoteDashboard.html not found in %@ or %@", Bundle.main.bundleURL.path, frameworkBundle.bundleURL.path)
        return nil
    }

    private func respond(status: Int, type: String, body: Data, on connection: NWConnection) {
        let phrase = status == 200 ? "OK" : status == 202 ? "Accepted" : status == 400 ? "Bad Request" : status == 404 ? "Not Found" : "Internal Server Error"
        let header = "HTTP/1.1 \(status) \(phrase)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

extension Notification.Name {
    static let remoteContainerLaunchApp = Notification.Name("RemoteContainerLaunchApp")
}
