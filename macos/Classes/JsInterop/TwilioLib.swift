import Foundation
import WebKit

/// Twilio library loader from Bundle resources:
/// i.e. `Resources/twilio.min.js`
class TwilioLib: JSLibLoader {
    var webview: TVWebView

    init(webview: TVWebView) {
        self.webview = webview
        super.init(fromBundle: TwilioVoicePlugin.self, library: "twilio.min.js")

        loadTwilio { content, error in
            if let error = error {
                print("Error loading twilio library: \(error)")
            } else if let content = content {
                self.webview.evaluateJavaScript(content) { (any: Any?, error: Error?) in
                    if let error = error {
                        print("Error loading twilio library: \(error)")
                    }
                }
            }
        }
    }

    private func loadTwilio(completionHandler: OnCompletionHandler<String>) {
        loadFile(file: "Resources/twilio.min", ofType: "js") { content, error in
            if let error = error {
                print("Error loading twilio library: \(error)")
                completionHandler(nil, error)
            } else if let content = content {
                completionHandler(content, nil)
            }
        }
    }
}
