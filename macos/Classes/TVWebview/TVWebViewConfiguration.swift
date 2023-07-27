import Foundation
import WebKit

/// Web configuration for TVWebView, providing console override logging
class TVWebViewConfiguration: WKWebViewConfiguration {
    init(enableConsoleLogging: Bool = false) {
        super.init()
        if enableConsoleLogging {
            overrideConsole()
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func overrideConsole() {
        userContentController.add(LoggingMessageHandler(), name: LoggingMessageHandler.handlerName)
        userContentController.addUserScript(WKUserScript(source: LoggingMessageHandler.js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
}
