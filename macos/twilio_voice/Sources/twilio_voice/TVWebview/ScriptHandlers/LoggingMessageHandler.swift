import Foundation
import WebKit

/// Console override logging handler to add to [WKWebViewConfiguration]
public class LoggingMessageHandler: NSObject, WKScriptMessageHandler {
    static var handlerName: String = "logging"
    static var js: String = """
                         function log(emoji, type, args) {
                           if(!args && !type) {
                               let message = emoji
                               window.webkit.messageHandlers.logging.postMessage(`${message}`)
                           } else if(!args) {
                                let message = type
                                window.webkit.messageHandlers.logging.postMessage(`${emoji} ${message}`)
                           } else {
                              window.webkit.messageHandlers.logging.postMessage(
                                `${emoji} JS ${type}: ${Object.values(args)
                                  .map(v => typeof(v) === "undefined" ? "undefined" : typeof(v) === "object" ? JSON.stringify(v) : v.toString())
                                  .map(v => v.substring(0, 3000)) // Limit msg to 3000 chars
                                  .join(", ")}`
                               )
                           }
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

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("[WebView:\(message.name)] \(message.body)")
    }
}
