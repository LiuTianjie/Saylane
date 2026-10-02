import AppKit
import WebKit

/// Render a page off screen and save the picture together with the truth the
/// page itself knows: every visible text run with its line rectangles, font
/// size, weight, family, colour and alignment.
///
///   snapshot <url> <css-width> <css-height> <scale> <out-prefix>
///
/// `scale` is the device scale to imitate (1 or 2). Output: <out-prefix>.png
/// and <out-prefix>.json; rectangles are in picture pixels, top-left origin.
@MainActor
final class Shooter: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    private var loaded: CheckedContinuation<Void, Error>?

    /// `scale` 1 or 2. A real 2x picture needs a window on a 2x display (never
    /// shown); without such a display the page is zoomed instead, which draws
    /// type at twice the size rather than at twice the resolution.
    init(width: CGFloat, height: CGFloat, zoom scale: CGFloat) {
        let wanted = NSScreen.screens.first { $0.backingScaleFactor == scale }
        let zoom = wanted == nil ? scale / (NSScreen.main?.backingScaleFactor ?? 1) : 1
        let frame = CGRect(x: 0, y: 0, width: width * zoom, height: height * zoom)
        // Nothing carried over between pages: a language cookie from one site's
        // Chinese edition must not turn its English edition Chinese.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: frame, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        webView.pageZoom = zoom
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: wanted)
        window.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            if url.isFileURL {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                components.query = nil
                webView.loadFileURL(url, allowingReadAccessTo: components.url!.deletingLastPathComponent())
            } else {
                var request = URLRequest(url: url, timeoutInterval: 40)
                // Ask for the language the address names, whatever this Mac prefers.
                let chinese = url.absoluteString.range(of: "zh|cn\\.", options: [.regularExpression, .caseInsensitive]) != nil
                request.setValue(chinese ? "zh-CN,zh;q=0.9" : "en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
                webView.load(request)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error); loaded = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error); loaded = nil
    }

    static let truthScript = """
    (() => {
      const out = [];
      const vw = innerWidth, vh = innerHeight;
      const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      let node;
      while ((node = walker.nextNode())) {
        const text = node.nodeValue.replace(/\\s+/g, ' ').trim();
        if (!text) continue;
        const el = node.parentElement;
        if (!el || ['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(el.tagName)) continue;
        const cs = getComputedStyle(el);
        if (cs.visibility === 'hidden' || cs.display === 'none' || parseFloat(cs.opacity) === 0) continue;
        const range = document.createRange();
        range.selectNodeContents(node);
        const rects = [...range.getClientRects()].filter(r =>
          r.width > 1 && r.height > 1 && r.top >= 0 && r.bottom <= vh && r.left >= 0 && r.right <= vw);
        if (!rects.length) continue;
        // Skip text covered by something else (menus, banners).
        const r0 = rects[0];
        const hit = document.elementFromPoint(r0.left + r0.width / 2, r0.top + r0.height / 2);
        if (hit && hit !== el && !el.contains(hit) && !hit.contains(el)) continue;
        out.push({ text, tag: el.tagName, size: parseFloat(cs.fontSize), weight: parseInt(cs.fontWeight) || 400,
          family: cs.fontFamily, color: cs.color, lineHeight: cs.lineHeight, align: cs.textAlign,
          lang: (el.closest('[lang]') || document.documentElement).lang || '',
          rects: rects.map(r => [r.left, r.top, r.width, r.height]) });
      }
      return JSON.stringify({ cssWidth: vw, cssHeight: vh, title: document.title, items: out });
    })()
    """

    func shoot(prefix: String, zoom: CGFloat) async throws {
        try await Task.sleep(for: .seconds(3))
        let truth = try await webView.evaluateJavaScript(Self.truthScript) as! String
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: config)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("no picture") }
        try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: prefix + ".png"))
        var object = try JSONSerialization.jsonObject(with: Data(truth.utf8)) as! [String: Any]
        let cssWidth = object["cssWidth"] as! Double
        // Pixels per CSS pixel: page zoom times the backing scale of the off-screen window.
        let scale = Double(cg.width) / cssWidth
        object["pixelWidth"] = cg.width
        object["pixelHeight"] = cg.height
        object["scale"] = scale
        object["url"] = webView.url?.absoluteString ?? ""
        var items = object["items"] as! [[String: Any]]
        for index in items.indices {
            let rects = items[index]["rects"] as! [[Double]]
            items[index]["rects"] = rects.map { $0.map { $0 * scale } }
        }
        object["items"] = items
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: prefix + ".json"))
        print("\(prefix).png \(cg.width)x\(cg.height) scale=\(scale) texts=\(items.count)")
    }
}

@main struct Snapshot {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let width = Double(args[2]), let height = Double(args[3]), let zoom = Double(args[4]) else {
            fatalError("usage: snapshot <url> <css-width> <css-height> <scale> <out-prefix>")
        }
        let url = args[1].contains("://") ? URL(string: args[1])! : URL(fileURLWithPath: args[1])
        NSApplication.shared.setActivationPolicy(.prohibited)
        let shooter = Shooter(width: width, height: height, zoom: zoom)
        try await shooter.load(url)
        try await shooter.shoot(prefix: args[5], zoom: zoom)
    }
}
