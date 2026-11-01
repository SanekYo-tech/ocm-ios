import Foundation
import Network

/// Serves the bundled web UI from http://127.0.0.1:<port>.
/// A real HTTP origin (instead of file://) gives WKWebView working localStorage,
/// IndexedDB and fetch(), exactly like the Android WebViewAssetLoader did.
final class StaticServer {
    private let root: URL
    private let queue = DispatchQueue(label: "app.opencodemob.static-server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func start() throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        _ = ready.wait(timeout: .now() + 5)
        guard port != 0 else {
            listener.cancel()
            throw NSError(domain: "StaticServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось запустить локальный сервер"])
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }

            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = buf[..<end.lowerBound]
                let text = String(decoding: head, as: UTF8.self)
                self.respond(connection, request: text)
                return
            }
            if error != nil || isComplete || buf.count > 128 * 1024 {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buf)
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        guard let first = request.split(separator: "\r\n").first else {
            send(connection, status: "400 Bad Request", mime: "text/plain", body: Data("bad request".utf8))
            return
        }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else {
            send(connection, status: "400 Bad Request", mime: "text/plain", body: Data("bad request".utf8))
            return
        }
        let method = String(parts[0]).uppercased()
        guard method == "GET" || method == "HEAD" else {
            send(connection, status: "405 Method Not Allowed", mime: "text/plain", body: Data("method not allowed".utf8))
            return
        }

        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        let decoded = path.removingPercentEncoding ?? path

        var rel = decoded
        if rel == "/" || rel.isEmpty { rel = "/index.html" }
        let candidate = root.appendingPathComponent(String(rel.dropFirst())).standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else {
            send(connection, status: "403 Forbidden", mime: "text/plain", body: Data("forbidden".utf8))
            return
        }

        var fileURL = candidate
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            send(connection, status: "404 Not Found", mime: "text/plain", body: Data("not found".utf8))
            return
        }
        if isDir.boolValue {
            fileURL = fileURL.appendingPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            send(connection, status: "500 Internal Server Error", mime: "text/plain", body: Data("read error".utf8))
            return
        }
        let mime = StaticServer.mimeType(for: fileURL.pathExtension.lowercased())
        if method == "HEAD" {
            send(connection, status: "200 OK", mime: mime, body: Data(), extraHeaders: ["Content-Length: \(data.count)"])
        } else {
            send(connection, status: "200 OK", mime: mime, body: data)
        }
    }

    private func send(_ connection: NWConnection, status: String, mime: String, body: Data, extraHeaders: [String] = []) {
        var headers = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(mime)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
            "Access-Control-Allow-Origin: *"
        ]
        headers.append(contentsOf: extraHeaders)
        var packet = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        packet.append(body)
        connection.send(content: packet, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func mimeType(for ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff", "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "map": return "application/json"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}