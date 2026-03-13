import AppKit
import Foundation

class ClipboardManager {
    weak var server: WebSocketServer?
    private var timer: DispatchSourceTimer?
    private var lastContent: String = ""
    private let queue = DispatchQueue(label: "airdesk.clipboard")

    func start() {
        // Seed with current clipboard content so we don't broadcast stale content on start
        lastContent = NSPasteboard.general.string(forType: .string) ?? ""

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.checkClipboard() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func writeToClipboard(_ text: String) {
        queue.async { [weak self] in
            self?.lastContent = text
        }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func checkClipboard() {
        guard let content = NSPasteboard.general.string(forType: .string),
              content != lastContent else { return }
        lastContent = content
        let msg = ClipboardMessage(type: "clipboard_changed", content: content)
        if let data = try? JSONEncoder().encode(msg),
           let text = String(data: data, encoding: .utf8) {
            server?.broadcastText(text)
        }
    }
}
