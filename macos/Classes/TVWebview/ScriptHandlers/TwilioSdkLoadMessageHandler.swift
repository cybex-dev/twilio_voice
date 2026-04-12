import Foundation
import WebKit

/// Receives postMessage from injected Twilio SDK loader script in the WKWebView.
final class TwilioSdkLoadMessageHandler: NSObject, WKScriptMessageHandler {
    static let handlerName = "TwilioVoiceSdk"

    weak var owner: TVWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handleSdkLoadScriptMessage(message)
    }
}
