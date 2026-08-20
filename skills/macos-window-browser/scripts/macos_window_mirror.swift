import AppKit
import ApplicationServices
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import Security

enum MirrorError: LocalizedError {
    case invalidArguments(String)
    case noMatchingWindow(String)
    case listener(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message), .noMatchingWindow(let message), .listener(let message):
            return message
        }
    }
}

struct Configuration {
    let applicationName: String
    let title: String?
    let port: UInt16
    let checkOnly: Bool

    init(arguments: [String]) throws {
        func value(for option: String) -> String? {
            guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        checkOnly = arguments.contains("--check")
        applicationName = value(for: "--app-name") ?? ""
        title = value(for: "--title")
        let portValue = value(for: "--port") ?? "41731"
        guard let parsedPort = UInt16(portValue), parsedPort > 0 else {
            throw MirrorError.invalidArguments("--port must be a number from 1 through 65535.")
        }
        port = parsedPort
        guard checkOnly || !applicationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MirrorError.invalidArguments("Usage: macos_window_browser.sh --app-name <process-name> [--title <window-title>] [--port <1-65535>] | --check")
        }
    }
}

private func json(_ object: Any) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
    return bytes.map { String(format: "%02x", $0) }.joined()
}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func displayName(forAccessibilityIdentifier identifier: String) -> String {
    identifier
        .replacingOccurrences(of: ".", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

struct Annotation: Codable {
    let id: String
    let kind: String
    let role: String
    let label: String
    let identifier: String?
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

struct WindowBounds: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

struct AnnotationPayload: Codable {
    let window: WindowBounds
    let elements: [Annotation]
}

struct SelectionPayload: Codable {
    let selection: Annotation?
}

final class WindowMirror: NSObject, SCStreamOutput {
    private let configuration: Configuration
    private let token = randomToken()
    private let serverQueue = DispatchQueue(label: "com.macos-window-browser.server")
    private let captureQueue = DispatchQueue(label: "com.macos-window-browser.capture")
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var listener: NWListener?
    private var stream: SCStream?
    private var subscribers: [UUID: NWConnection] = [:]
    private var capturedWindow: SCWindow?
    private var annotationsByID: [String: Annotation] = [:]
    private var selectedAnnotation: Annotation?

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init()
    }

    func start() async throws {
        let selectedWindow = try await resolveWindow()
        capturedWindow = selectedWindow
        try startHTTPServer()

        let filter = SCContentFilter(desktopIndependentWindow: selectedWindow)
        let streamConfiguration = streamConfiguration(for: selectedWindow)
        let screenStream = SCStream(filter: filter, configuration: streamConfiguration, delegate: nil)
        try screenStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        stream = screenStream
        try await screenStream.startCapture()

        let readyURL = "http://127.0.0.1:\(configuration.port)/\(token)/\n"
        FileHandle.standardOutput.write(Data(readyURL.utf8))
    }

    private func resolveWindow() async throws -> SCWindow {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let requestedApp = configuration.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedTitle = configuration.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = content.windows.filter { window in
            guard let ownerName = window.owningApplication?.applicationName else { return false }
            let appMatches = ownerName.localizedCaseInsensitiveContains(requestedApp) || requestedApp.localizedCaseInsensitiveContains(ownerName)
            let titleMatches: Bool
            if let requestedTitle, !requestedTitle.isEmpty {
                titleMatches = window.title?.localizedCaseInsensitiveContains(requestedTitle) ?? false
            } else {
                titleMatches = true
            }
            return appMatches && titleMatches && window.frame.width > 1 && window.frame.height > 1
        }
        guard let selectedWindow = matches.max(by: { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }) else {
            throw MirrorError.noMatchingWindow("No visible window was found for \(requestedApp). Launch the app first and use its process name.")
        }
        return selectedWindow
    }

    private func streamConfiguration(for window: SCWindow) -> SCStreamConfiguration {
        // SCWindow frames are measured in points. Request a Retina-density
        // buffer so text remains crisp when the browser fits the window into
        // its preview canvas, while still putting a ceiling on local CPU and
        // bandwidth usage for very large desktop windows.
        let sourceScale: CGFloat = 2
        let maxWidth: CGFloat = 2560
        let requestedWidth = window.frame.width * sourceScale
        let requestedHeight = window.frame.height * sourceScale
        let scale = min(1, maxWidth / max(requestedWidth, 1))
        let result = SCStreamConfiguration()
        result.width = max(1, Int(requestedWidth * scale))
        result.height = max(1, Int(requestedHeight * scale))
        result.minimumFrameInterval = CMTime(value: 1, timescale: 8)
        result.queueDepth = 3
        result.showsCursor = true
        return result
    }

    private func accessibilitySnapshot() throws -> [Annotation] {
        guard AXIsProcessTrusted() else {
            throw MirrorError.listener("Accessibility permission is required to inspect native controls. Enable it for Codex or the terminal in System Settings → Privacy & Security → Accessibility.")
        }
        guard let capturedWindow, let processID = capturedWindow.owningApplication?.processID else {
            throw MirrorError.listener("The selected app window is no longer available for inspection.")
        }

        let application = AXUIElementCreateApplication(processID)
        let candidates = axChildren(application, attribute: kAXWindowsAttribute)
        let root = candidates.max { overlapArea(axFrame($0), capturedWindow.frame) < overlapArea(axFrame($1), capturedWindow.frame) } ?? application
        let controlRoles: Set<String> = [
            "AXButton", "AXCheckBox", "AXLink", "AXMenuButton", "AXPopUpButton",
            "AXRadioButton", "AXSlider", "AXTab", "AXTextArea", "AXTextField",
        ]
        let structuralRoles: Set<String> = [
            "AXGroup", "AXLayoutArea", "AXList", "AXRow", "AXScrollArea", "AXSplitter", "AXSplitGroup",
        ]
        var results: [Annotation] = []

        func walk(_ element: AXUIElement, path: [Int], depth: Int) {
            guard depth <= 10, results.count < 250 else { return }
            let role = axString(element, attribute: kAXRoleAttribute) ?? "AXUnknown"
            let frame = axFrame(element)
            let title = axString(element, attribute: kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = axString(element, attribute: kAXDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let roleDescription = axString(element, attribute: kAXRoleDescriptionAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let identifier = axString(element, attribute: kAXIdentifierAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let explicitLabel: String? = [title, description].compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.first
            let normalizedName = [explicitLabel, identifier].compactMap { $0?.lowercased() }.joined(separator: " ")
            let kind: String?
            if normalizedName.contains("divider") || normalizedName.contains("separator") {
                kind = "separator"
            } else if controlRoles.contains(role) {
                kind = "control"
            } else if role == "AXStaticText" {
                kind = "text"
            } else if structuralRoles.contains(role), explicitLabel != nil || !(identifier?.isEmpty ?? true) {
                kind = frame.height <= 4 || frame.width <= 4
                    ? "separator"
                    : "structure"
            } else {
                kind = nil
            }
            if let kind, !frame.isNull, frame.intersects(capturedWindow.frame) {
                let label = explicitLabel ?? identifier.map(displayName(forAccessibilityIdentifier:)) ?? roleDescription ?? role
                results.append(Annotation(
                    id: "ax-\(path.map(String.init).joined(separator: "-"))",
                    kind: kind,
                    role: role,
                    label: String(label.prefix(160)),
                    identifier: identifier?.isEmpty == false ? String(identifier!.prefix(160)) : nil,
                    x: frame.origin.x,
                    y: frame.origin.y,
                    width: frame.width,
                    height: frame.height
                ))
            }
            for (index, child) in axChildren(element, attribute: kAXChildrenAttribute).enumerated() {
                walk(child, path: path + [index], depth: depth + 1)
            }
        }

        walk(root, path: [0], depth: 0)
        annotationsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        if let selectedAnnotation, annotationsByID[selectedAnnotation.id] == nil {
            self.selectedAnnotation = nil
        }
        return results
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func axChildren(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func axFrame(_ element: AXUIElement) -> CGRect {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return .null }
        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(positionAXValue) == .cgPoint,
              AXValueGetType(sizeAXValue) == .cgSize,
              AXValueGetValue(positionAXValue, .cgPoint, &position),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else { return .null }
        return CGRect(origin: position, size: size)
    }

    private func overlapArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }

    private func startHTTPServer() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: configuration.port)!)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                fputs("macOS window mirror listener failed: \(error)\n", stderr)
            }
        }
        self.listener = listener
        listener.start(queue: serverQueue)
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.serverQueue.async { self?.subscribers[id] = nil }
            default:
                break
            }
        }
        connection.start(queue: serverQueue)
        receiveRequest(connection, id: id, data: Data())
    }

    private func receiveRequest(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var buffered = data
            if let chunk { buffered.append(chunk) }
            if buffered.count > 16_384 {
                self.sendError(connection, status: "413 Payload Too Large")
                return
            }
            if buffered.range(of: Data("\r\n\r\n".utf8)) == nil, !complete, error == nil {
                self.receiveRequest(connection, id: id, data: buffered)
                return
            }
            guard error == nil, let request = String(data: buffered, encoding: .utf8) else {
                connection.cancel()
                return
            }
            self.handle(request: request, connection: connection, id: id)
        }
    }

    private func handle(request: String, connection: NWConnection, id: UUID) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first?.split(separator: " "), firstLine.count >= 2,
              firstLine[0] == "GET", isLoopbackHost(lines) else {
            sendError(connection, status: "403 Forbidden")
            return
        }
        let requestPath = String(firstLine[1])
        let basePath = "/\(token)/"
        if requestPath == basePath {
            send(connection, status: "200 OK", headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(viewerHTML().utf8), close: true)
        } else if requestPath == "\(basePath)stream.mjpeg" {
            let headers = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: keep-alive\r\n\r\n"
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                guard error == nil else { connection.cancel(); return }
                self?.serverQueue.async { self?.subscribers[id] = connection }
            })
        } else if requestPath == "\(basePath)elements.json" {
            do {
                let annotations = try accessibilitySnapshot()
                let frame = capturedWindow?.frame ?? .zero
                sendJSON(connection, status: "200 OK", payload: AnnotationPayload(window: WindowBounds(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height), elements: annotations))
            } catch {
                sendError(connection, status: "503 Inspector unavailable: \(error.localizedDescription)")
            }
        } else if requestPath == "\(basePath)selection.json" {
            sendJSON(connection, status: "200 OK", payload: SelectionPayload(selection: selectedAnnotation))
        } else if requestPath.hasPrefix("\(basePath)select/") {
            let id = String(requestPath.dropFirst("\(basePath)select/".count))
            guard let annotation = annotationsByID[id] else {
                sendError(connection, status: "404 Annotation not found")
                return
            }
            selectedAnnotation = annotation
            sendJSON(connection, status: "200 OK", payload: SelectionPayload(selection: annotation))
        } else {
            sendError(connection, status: "404 Not Found")
        }
    }

    private func isLoopbackHost(_ lines: [String]) -> Bool {
        guard let rawHost = lines.first(where: { $0.lowercased().hasPrefix("host:") })?.dropFirst(5).trimmingCharacters(in: .whitespaces) else {
            return false
        }
        return rawHost.hasPrefix("127.0.0.1:") || rawHost == "127.0.0.1" || rawHost.hasPrefix("localhost:") || rawHost == "localhost"
    }

    private func viewerHTML() -> String {
        let safeName = escapeHTML(configuration.applicationName)
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(safeName) — macOS preview</title><style>
        :root{color-scheme:dark;background:#0c1018;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#eef3fb}*{box-sizing:border-box}body{margin:0;min-height:100vh;display:grid;grid-template-rows:auto 1fr;background:radial-gradient(circle at 50% -30%,#203659 0,#0c1018 48%,#080b11 100%)}header{display:flex;align-items:center;gap:12px;min-height:58px;padding:9px 16px;background:#121925e8;border-bottom:1px solid #2a374a;backdrop-filter:blur(18px);font-size:13px;line-height:1.2;z-index:2}.brand{display:flex;align-items:center;gap:8px;white-space:nowrap}.brand strong{font-size:14px;letter-spacing:-.01em}.native,.muted{color:#9eafc7;font-size:12px}.muted{margin-left:auto;white-space:nowrap}.live{width:8px;height:8px;border-radius:50%;background:#4fdd9b;box-shadow:0 0 0 3px #4fdd9b1f}main{min-height:0;display:grid;place-items:center;padding:20px;overflow:auto}#stage{display:inline-block;line-height:0;background:#05070a;border:1px solid #253247;border-radius:14px;box-shadow:0 24px 80px #000a;overflow:hidden}#frame{display:block;max-width:100%;max-height:calc(100vh - 100px)}@media(max-width:760px){header{gap:8px;padding:8px 10px}.native{display:none}main{padding:10px}#frame{max-height:calc(100vh - 90px)}}
        </style></head><body><header><div class="brand"><span class="live" aria-hidden="true"></span><strong>\(safeName)</strong><span class="native">Native macOS window</span></div><span class="muted">Live, read-only window</span></header><main><div id="stage"><img id="frame" src="/\(token)/stream.mjpeg" alt="Live native macOS app window"></div></main></body></html>
        """
    }

    private func sendError(_ connection: NWConnection, status: String) {
        send(connection, status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data("\(status)\n".utf8), close: true)
    }

    private func sendJSON<T: Encodable>(_ connection: NWConnection, status: String, payload: T) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            send(connection, status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: try encoder.encode(payload), close: true)
        } catch {
            sendError(connection, status: "500 JSON encoding failed")
        }
    }

    private func send(_ connection: NWConnection, status: String, headers: [String: String], body: Data, close: Bool) {
        var response = "HTTP/1.1 \(status)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Length: \(body.count)\r\n"
        for (name, value) in headers { response += "\(name): \(value)\r\n" }
        response += close ? "Connection: close\r\n\r\n" : "\r\n"
        connection.send(content: Data(response.utf8) + body, completion: .contentProcessed { _ in
            if close { connection.cancel() }
        })
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent),
              let jpeg = NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.86]) else { return }
        serverQueue.async { [weak self] in self?.broadcast(jpeg) }
    }

    private func broadcast(_ jpeg: Data) {
        guard !subscribers.isEmpty else { return }
        let header = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        let payload = header + jpeg + Data("\r\n".utf8)
        for (id, connection) in subscribers {
            connection.send(content: payload, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.serverQueue.async { self?.subscribers[id] = nil } }
            })
        }
    }
}

do {
    let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
    if configuration.checkOnly {
        print(json(["screenCaptureGranted": CGPreflightScreenCaptureAccess()]))
    } else if !CGPreflightScreenCaptureAccess() {
        fputs("Screen Recording permission is required. Enable it for Codex or the terminal in System Settings → Privacy & Security → Screen & System Audio Recording, then run again.\n", stderr)
        exit(77)
    } else {
        let mirror = WindowMirror(configuration: configuration)
        Task {
            do {
                try await mirror.start()
            } catch {
                fputs("macOS window mirror failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        dispatchMain()
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(64)
}
