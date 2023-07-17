import FlutterMacOS
import Foundation
import WebKit

class LoggingMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print(message.body)
    }
}

public class TVWebView: WKWebView, WKUIDelegate, WKScriptMessageHandler {

    private func overrideConsole() {

        let overrideConsole = """
                                  function log(emoji, type, args) {
                                    window.webkit.messageHandlers.logging.postMessage(
                                      `${emoji} JS ${type}: ${Object.values(args)
                                        .map(v => typeof(v) === "undefined" ? "undefined" : typeof(v) === "object" ? JSON.stringify(v) : v.toString())
                                        .map(v => v.substring(0, 3000)) // Limit msg to 3000 chars
                                        .join(", ")}`
                                    )
                                  }

                                  let originalLog = console.log
                                  let originalWarn = console.warn
                                  let originalError = console.error
                                  let originalDebug = console.debug

                                  console.log = function() { log("📗", "log", arguments); originalLog.apply(null, arguments) }
                                  console.warn = function() { log("📙", "warning", arguments); originalWarn.apply(null, arguments) }
                                  console.error = function() { log("📕", "error", arguments); originalError.apply(null, arguments) }
                                  console.debug = function() { log("📘", "debug", arguments); originalDebug.apply(null, arguments) }

                                  window.addEventListener("error", function(e) {
                                     log("💥", "Uncaught", [`${e.message} at ${e.filename}:${e.lineno}:${e.colno}`])
                                  })
                              """

        configuration.userContentController.add(LoggingMessageHandler(), name: "logging")
        configuration.userContentController.addUserScript(WKUserScript(source: overrideConsole, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    init(messageHandler: String) {
        super.init(frame: CGRect.zero, configuration: WKWebViewConfiguration())
        configuration.userContentController.add(self, name: messageHandler)
        overrideConsole()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("userContentController didReceive message: \(message)")
    }

    public func evaluateJavaScript<T>(ofType: T.Type = T.self, javascript: String, sourceURL: String? = "", completionHandler: @escaping (_ result: T?, _ error: String?) -> Void) -> Void {
        var javascript = javascript

        // Adding a sourceURL comment makes the javascript source visible when debugging the simulator via Safari in Mac OS
        if let sourceURL = sourceURL {
            javascript = "//# sourceURL=\(sourceURL).js\n" + javascript
        }

        evaluateJavaScript(javascript) { any, error in
            if (error != nil) {
                print("evaluateJavascript error: \(String(describing: error))")
                completionHandler(nil, error?.localizedDescription)
            } else {
                completionHandler(any as? T ?? nil, nil)
            }
        }
    }

    deinit {
        print("deinit");
    }

}