import FlutterMacOS
import Foundation
import WebKit

/// [TVWebViewConfiguration] providing a [WKUserContentController] with a default message handler and custom evaluateJavaScript function.
public class TVWebView: WKWebView, WKUIDelegate, WKScriptMessageHandler {

    init(messageHandler: String) {
        super.init(frame: CGRect.zero, configuration: WKWebViewConfiguration())

        let bundle = Bundle(for: TwilioVoicePlugin.self)
        if let url = bundle.url(forResource: "Resources/index", withExtension: "html") {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        overrideLogging()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func overrideLogging() {
        configuration.userContentController.addUserScript(WKUserScript(source: LoggingMessageHandler.js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(LoggingMessageHandler(), name: LoggingMessageHandler.handlerName)
    }

    /// Default script message handler
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("userContentController didReceive message: \(message)")
    }

    /// Evaluate javascript in the WKWebView, with debug sourceURL
    ///
    /// - Parameters:
    ///   - javascript: string representing native javascript code
    ///   - sourceURL: string representing the source URL of the javascript code used for debugging
    ///   - completionHandler: completion handler
    public func evaluateJavaScript(javascript: String, sourceURL: String? = "", completionHandler: @escaping (_ result: Any?, _ error: String?) -> Void) -> Void {
        var javascript = javascript

        // Adding a sourceURL comment makes the javascript source visible when debugging the simulator via Safari in Mac OS
        if let sourceURL = sourceURL {
            javascript = "//# sourceURL=\(sourceURL).js\n" + javascript
        }

        if(javascript.last(where: { !$0.isWhitespace }) != ";" && javascript.last(where: { !$0.isWhitespace }) != "}") {
            NSLog("[JS] WARNING: [sourceURL: \(sourceURL ?? "?")] evaluateJavascript does not end with a semicolon or a closing bracket, adding a semicolon.")
            javascript += ";"
        }
//        NSLog("[JS] exec: \(javascript)")

        evaluateJavaScript(javascript) { (any, error) in
            if (error != nil) {
                NSLog("[JS] ERROR: evaluateJavascript error: \(String(describing: error))")
                NSLog("[JS] ERROR: evaluateJavascript javascript: \(javascript)")
                NSLog("[JS] ERROR: evaluateJavascript sourceURL: \(sourceURL ?? "?")")
                completionHandler(nil, String(describing: error))
            } else {
                completionHandler(any, nil)
            }
        }
    }

    deinit {
        print("deinit");
    }

}