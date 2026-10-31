import AppKit
import SwiftUI
import WebKit

/// A notebook output rendered as HTML (tables, IPython.display.HTML), LaTeX (via KaTeX) or SVG.
/// Sizes itself to its content; tall outputs are capped and scroll internally.
struct RichOutputView: View {
    let content: String
    /// MIME type: text/html, text/latex or image/svg+xml.
    let kind: String
    @State private var height: CGFloat = 24

    static let maxHeight: CGFloat = 640

    var body: some View {
        OutputWebView(document: Self.document(content, kind: kind), allowsScripts: kind == "text/latex",
                      height: $height)
            .frame(height: min(height, Self.maxHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func document(_ content: String, kind: String) -> String {
        var head = ""
        var body = content
        switch kind {
        case "text/latex":
            // Fixed version: katex@0.16.11. Offline, the source is shown as-is.
            let cdn = "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist"
            head = """
                <link rel="stylesheet" href="\(cdn)/katex.min.css">
                <script defer src="\(cdn)/katex.min.js"></script>
                <script defer src="\(cdn)/contrib/auto-render.min.js"
                  onload="renderMathInElement(document.body, {delimiters: [
                    {left: '$$', right: '$$', display: true}, {left: '\\\\[', right: '\\\\]', display: true},
                    {left: '$', right: '$', display: false}, {left: '\\\\(', right: '\\\\)', display: false}],
                    throwOnError: false})"></script>
                """
            body = "<div class=\"latex\">\(escapeHTML(content))</div>"
        case "image/svg+xml":
            body = "<div class=\"svg\">\(content)</div>"
        default:
            break
        }
        return """
            <!doctype html><html><head><meta charset="utf-8">
            <style>
            :root { color-scheme: light dark; }
            html, body { margin: 0; background: transparent; }
            body { padding: 2px 8px; font: 13px -apple-system, system-ui, sans-serif; color: CanvasText;
                   overflow-wrap: anywhere; }
            table { border-collapse: collapse; border: none; font-size: 12px; font-variant-numeric: tabular-nums;
                    margin: 2px 0; }
            th, td { padding: 4px 10px; text-align: right; border: none; white-space: nowrap; }
            thead th { border-bottom: 1px solid rgba(128,128,128,.5); }
            tbody th { font-weight: 600; }
            tbody tr:nth-child(odd) { background: rgba(128,128,128,.08); }
            tbody tr:hover { background: rgba(0,122,255,.12); }
            pre, code { font: 12px ui-monospace, Menlo, monospace; }
            img, svg { max-width: 100%; height: auto; }
            a { color: LinkText; }
            .latex { font-size: 15px; white-space: pre-wrap; }
            </style>\(head)</head><body>\(body)</body></html>
            """
    }

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private struct OutputWebView: NSViewRepresentable {
    let document: String
    let allowsScripts: Bool
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PassThroughWebView {
        let configuration = WKWebViewConfiguration()
        // Output HTML comes from running code; it isn't given scripting (KaTeX output is ours).
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsScripts
        let view = PassThroughWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: PassThroughWebView, context: Context) {
        context.coordinator.parent = self
        view.scrollsInternally = height > RichOutputView.maxHeight
        if context.coordinator.loaded != document {
            context.coordinator.loaded = document
            view.loadHTMLString(document, baseURL: nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: OutputWebView
        var loaded: String?

        init(_ parent: OutputWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Measure now, and again once fonts, images or KaTeX have settled.
            for delay in [0.0, 0.3, 1.0, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.measure(webView)
                }
            }
        }

        private func measure(_ webView: WKWebView) {
            webView.evaluateJavaScript("Math.ceil(document.documentElement.scrollHeight)") { [weak self] value, _ in
                guard let self, let number = value as? NSNumber else { return }
                let height = CGFloat(truncating: number)
                Task { @MainActor in
                    if height > 0, abs(height - self.parent.height) > 0.5 { self.parent.height = height }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            // Links open in the browser; the output itself never navigates away.
            if action.navigationType == .linkActivated, let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(action.navigationType == .other ? .allow : .cancel)
        }
    }
}

/// Lets vertical scrolling reach the notebook's scroll view unless the output itself is taller
/// than its frame; horizontal scrolling (wide tables) stays in the output.
final class PassThroughWebView: WKWebView {
    var scrollsInternally = false

    override func scrollWheel(with event: NSEvent) {
        if scrollsInternally || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}
