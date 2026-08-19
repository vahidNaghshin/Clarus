import SwiftUI
import WebKit

/// Renders Markdown text with embedded LaTeX equations using KaTeX.
/// Inline equations: $...$   Block equations: $$...$$
/// Markdown (bold, italic, code, headings, lists) is also rendered.
///
/// Sizing: the view auto-sizes to the height of the rendered HTML by
/// reading `document.body.scrollHeight` from JavaScript after layout.
/// Pass `fixedHeight` when you already know the height (avoids flash).
// MARK: - Scroll-forwarding WKWebView

/// `RenderedContentView` is always sized to exactly match its rendered
/// HTML content's height (via the height-reporting JS bridge above), so
/// it never needs to scroll internally. However, WKWebView owns its own
/// internal NSScrollView and — by default — captures scroll-wheel events
/// rather than letting them bubble up to an enclosing SwiftUI `ScrollView`.
/// That made long chat replies / notes containing a `MarkdownLatexView`
/// effectively freeze scrolling (and made trailing UI like "Add to note"
/// unreachable) whenever the cursor was hovering over the rendered content.
/// Forwarding scroll-wheel events to the next responder fixes this without
/// any loss of functionality, since there's no internal scrolling to
/// preserve.
final class ScrollForwardingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}

struct RenderedContentView: NSViewRepresentable {
    let text: String
    var font: RenderedFont = .body
    var colorScheme: ColorScheme = .light
    var fixedHeight: CGFloat? = nil

    enum RenderedFont {
        case caption, body, headline
        var sizePx: Int {
            switch self {
            case .caption:  return 12
            case .body:     return 14
            case .headline: return 16
            }
        }
    }

    // Height is reported back via a binding so parent can size a frame.
    @Binding var contentHeight: CGFloat

    init(text: String, font: RenderedFont = .body, colorScheme: ColorScheme = .light, contentHeight: Binding<CGFloat> = .constant(100)) {
        self.text = text
        self.font = font
        self.colorScheme = colorScheme
        self._contentHeight = contentHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "heightBridge")

        let webView = ScrollForwardingWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.load(html: html(for: text))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastText != text || context.coordinator.lastScheme != colorScheme {
            context.coordinator.lastText = text
            context.coordinator.lastScheme = colorScheme
            context.coordinator.load(html: html(for: text))
        }
    }

    // MARK: – HTML generation

    private func html(for markdown: String) -> String {
        let bg       = colorScheme == .dark ? "#1e1e1e" : "#ffffff"
        let fg       = colorScheme == .dark ? "#e8e8e8" : "#1a1a1a"
        let codeBg   = colorScheme == .dark ? "#2d2d2d" : "#f4f4f4"
        let quoteBg  = colorScheme == .dark ? "#2a2a2a" : "#f9f9f9"
        let quoteBar = colorScheme == .dark ? "#555555" : "#cccccc"
        let linkFg   = colorScheme == .dark ? "#6caaee" : "#0066cc"

        let katexCSSContent = Self.loadBundleText("katex.min", ext: "css",
                                                    subdir: "katex") ?? katexCSS
        let katexJSContent   = Self.loadBundleText("katex.min", ext: "js",
                                                    subdir: "katex") ?? katexJS
        let autoRenderContent = Self.loadBundleText("auto-render.min", ext: "js",
                                                     subdir: "katex") ?? katexAutoRenderJS

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(katexCSSContent)
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body {
            font-family: -apple-system, 'Helvetica Neue', sans-serif;
            font-size: \(font.sizePx)px;
            line-height: 1.6;
            color: \(fg);
            background: \(bg);
            padding: 4px 2px;
            word-wrap: break-word;
          }
          h1 { font-size: 1.45em; margin: 12px 0 6px; }
          h2 { font-size: 1.25em; margin: 10px 0 5px; }
          h3 { font-size: 1.1em;  margin: 8px 0 4px; }
          p  { margin: 6px 0; }
          ul, ol { margin: 4px 0 4px 20px; }
          li { margin: 2px 0; }
          a  { color: \(linkFg); text-decoration: none; }
          code {
            font-family: 'SF Mono', 'Menlo', monospace;
            font-size: 0.88em;
            background: \(codeBg);
            padding: 1px 5px;
            border-radius: 4px;
          }
          pre code {
            display: block;
            padding: 10px 12px;
            overflow-x: auto;
            border-radius: 6px;
          }
          blockquote {
            border-left: 3px solid \(quoteBar);
            background: \(quoteBg);
            padding: 6px 12px;
            margin: 6px 0;
            color: \(fg);
            opacity: 0.85;
          }
          hr { border: none; border-top: 1px solid \(quoteBar); margin: 8px 0; }
          table { border-collapse: collapse; width: 100%; margin: 6px 0; }
          th, td { border: 1px solid \(quoteBar); padding: 4px 8px; text-align: left; }
          .katex-display { overflow-x: auto; }
        </style>
        </head>
        <body>
        <div id="content"></div>
        <script>
        \(katexJSContent)
        \(autoRenderContent)
        \(markdownJS)

        var raw = \(jsString(markdown));
        document.getElementById('content').innerHTML = mdToHTML(raw);

        // Render LaTeX
        renderMathInElement(document.getElementById('content'), {
          delimiters: [
            {left: '$$', right: '$$', display: true},
            {left: '$',  right: '$',  display: false},
            {left: '\\\\[', right: '\\\\]', display: true},
            {left: '\\\\(', right: '\\\\)', display: false}
          ],
          throwOnError: false
        });

        // Report rendered height back to Swift
        function reportHeight() {
          var h = document.body.scrollHeight;
          window.webkit.messageHandlers.heightBridge.postMessage(h);
        }
        window.onload = reportHeight;
        setTimeout(reportHeight, 200);
        </script>
        </body>
        </html>
        """
    }

    /// Escapes a Swift string for safe embedding as a JS string literal.
    private func jsString(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "`", with: "\\`")
        out = out.replacingOccurrences(of: "$", with: "\\$")
        // Use JS template literal
        return "`\(out)`"
    }

    // MARK: – Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: RenderedContentView
        weak var webView: WKWebView?
        var lastText: String = ""
        var lastScheme: ColorScheme = .light

        init(_ parent: RenderedContentView) { self.parent = parent }

        func load(html: String) {
            let baseURL = RenderedContentView.katexBundleResourceURL
            webView?.loadHTMLString(html, baseURL: baseURL)
        }

        // WKScriptMessageHandler: receives rendered height from JS
        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "heightBridge",
                  let h = message.body as? Double else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.contentHeight = CGFloat(h)
            }
        }
    }
    // MARK: – Bundle helper

    static func loadBundleText(_ name: String, ext: String, subdir: String) -> String? {
        // Files live inside katex.bundle, an opaque bundle Xcode copies as-is.
        let katexBundleURL = Bundle.main.url(forResource: "katex", withExtension: "bundle")
        let resolvedBundle = katexBundleURL.flatMap { Bundle(url: $0) } ?? Bundle.main
        guard let url = resolvedBundle.url(forResource: name, withExtension: ext),
              let src = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return src
    }

    /// URL of the katex.bundle directory — used as baseURL so @font-face
    /// rules in katex.min.css can find fonts/ via relative paths.
    static var katexBundleResourceURL: URL? {
        Bundle.main.url(forResource: "katex", withExtension: "bundle")
    }
}

// MARK: - Height-aware wrapper

/// Drop-in replacement for `Text(someMarkdownAndLatex)`.
/// Sizes itself to fit the rendered content.
struct MarkdownLatexView: View {
    let text: String
    var font: RenderedContentView.RenderedFont = .body
    @State private var height: CGFloat = 60
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RenderedContentView(text: text, font: font, colorScheme: colorScheme, contentHeight: $height)
            .frame(height: height)
    }
}

// MARK: - Bundled JS/CSS fallbacks (used only when bundle assets are missing)

private let katexCSS: String = ".katex{font:normal 1.21em KaTeX_Main,Times New Roman,serif}"

private let katexJS: String = """
var katex={renderToString:function(s){return'<span style="font-family:monospace">'+s+'</span>';}};
"""

private let katexAutoRenderJS: String = """
function renderMathInElement(el,opts){}
"""

private let markdownJS: String = """
function mdToHTML(md) {
  var s = md
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/```([\\s\\S]*?)```/g, function(_,c){return '<pre><code>'+c+'</code></pre>';})
    .replace(/`([^`]+)`/g,'<code>$1</code>')
    .replace(/^######\\s+(.+)$/gm,'<h6>$1</h6>')
    .replace(/^#####\\s+(.+)$/gm,'<h5>$1</h5>')
    .replace(/^####\\s+(.+)$/gm,'<h4>$1</h4>')
    .replace(/^###\\s+(.+)$/gm,'<h3>$1</h3>')
    .replace(/^##\\s+(.+)$/gm,'<h2>$1</h2>')
    .replace(/^#\\s+(.+)$/gm,'<h1>$1</h1>')
    .replace(/^---+$/gm,'<hr>')
    .replace(/\\*\\*\\*(.+?)\\*\\*\\*/g,'<strong><em>$1</em></strong>')
    .replace(/\\*\\*(.+?)\\*\\*/g,'<strong>$1</strong>')
    .replace(/\\*(.+?)\\*/g,'<em>$1</em>')
    .replace(/_(.+?)_/g,'<em>$1</em>')
    .replace(/^>\\s*(.+)$/gm,'<blockquote>$1</blockquote>')
    .replace(/((?:^[-*]\\s+.+$\\n?)+)/gm,function(_,b){
      return '<ul>'+b.trim().split(/\\n/).map(function(l){return '<li>'+l.replace(/^[-*]\\s+/,'')+'</li>';}).join('')+'</ul>';
    })
    .replace(/((?:^\\d+\\.\\s+.+$\\n?)+)/gm,function(_,b){
      return '<ol>'+b.trim().split(/\\n/).map(function(l){return '<li>'+l.replace(/^\\d+\\.\\s+/,'')+'</li>';}).join('')+'</ol>';
    })
    .replace(/\\n\\n+/g,'</p><p>')
    .replace(/\\n/g,'<br>');
  return '<p>'+s+'</p>';
}
"""
