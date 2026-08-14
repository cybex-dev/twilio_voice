import FlutterMacOS
import Foundation
import WebKit

public class TVWebView: WKWebView, WKUIDelegate {

    var loggingEnabled: Bool = false

    init(messageHandler: String, loggingEnabled: Bool = false) {
        super.init(frame: CGRect.zero, configuration: WKWebViewConfiguration())
        self.loggingEnabled = loggingEnabled

        // User scripts must be registered before the page is loaded so they are injected into it.
        overrideLogging()
        injectTwilioVoiceSDK()

        if let url = TVWebView.indexPageURL() {
            loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            NSLog("""

                  WARNING! - Unable to load index.html from bundle. This will prevent proper functionality of this plugin.
                    Please ensure the index.html & associated resources files are included in the plugin bundle.
                  See Twilio Voice Plugin README for more information regarding loading these resources.

                  """)
        }
    }

    /// Locates `index.html`, the page this webview hosts.
    ///
    /// Where it lives depends on how the plugin was integrated. Under Swift Package Manager the
    /// file is declared as a package resource and lands in the package's generated resource
    /// bundle, reachable only through `Bundle.module`. Under CocoaPods it is copied into the
    /// plugin framework's own `Resources` directory instead.
    private static func indexPageURL() -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "index", withExtension: "html")
        #else
        return Bundle(for: TwilioVoicePlugin.self).url(forResource: "Resources/index", withExtension: "html")
        #endif
    }

    /// Asset path of the bundled Twilio Voice JS SDK, as declared in the plugin's `pubspec.yaml`.
    private static let sdkAsset = "assets/twilio.min.js"
    private static let sdkPackage = "twilio_voice"

    /// Injects the bundled Twilio Voice JS SDK into the webview at document start, so
    /// `window.Twilio` is defined before `index.html` runs.
    ///
    /// The SDK ships **once**, as a Flutter asset (`assets/twilio.min.js`) shared with the web
    /// implementation, rather than being duplicated into this plugin's macOS `Resources/` bundle.
    /// Injecting it as a `WKUserScript` (rather than a `<script src=...>` in `index.html`) also
    /// avoids `file://` cross-directory read restrictions, since the Flutter assets live in a
    /// different bundle to `index.html`.
    private func injectTwilioVoiceSDK() {
        guard let source = TVWebView.loadBundledSDKSource() else {
            NSLog("""

                  WARNING! - Unable to load the bundled Twilio Voice JS SDK asset '\(TVWebView.sdkAsset)'
                    from package '\(TVWebView.sdkPackage)'. VoIP functionality will be unavailable.
                    Ensure the twilio_voice package's assets are included in your macOS build.

                  """)
            return
        }
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    /// Resolves and reads the bundled Twilio Voice JS SDK from the Flutter asset bundle.
    ///
    /// On macOS the Flutter assets are packaged inside `App.framework`, not directly in the main
    /// bundle, and the key returned by [FlutterDartProject.lookupKey] may or may not already carry
    /// a `flutter_assets/` prefix depending on the Flutter version. Rather than depending on any
    /// one of those, this tries each known layout in turn and uses the first that resolves.
    private static func loadBundledSDKSource() -> String? {
        let key = FlutterDartProject.lookupKey(forAsset: sdkAsset, fromPackage: sdkPackage)
        // Location of the asset within `flutter_assets`, independent of the key format above.
        let relativeAssetPath = "packages/\(sdkPackage)/\(sdkAsset)"

        var candidates: [URL] = []

        // 1. Flutter's asset key resolved against the application's main bundle.
        if let path = Bundle.main.path(forResource: key, ofType: nil) {
            candidates.append(URL(fileURLWithPath: path))
        }

        // 2. `flutter_assets` inside App.framework - the macOS layout.
        if let frameworks = Bundle.main.privateFrameworksURL {
            let resources = frameworks.appendingPathComponent("App.framework/Resources")
            let flutterAssets = resources.appendingPathComponent("flutter_assets")
            candidates.append(flutterAssets.appendingPathComponent(relativeAssetPath))
            // Cover both key shapes: with and without the `flutter_assets/` prefix.
            candidates.append(flutterAssets.appendingPathComponent(key))
            candidates.append(resources.appendingPathComponent(key))
        }

        for url in candidates {
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                return source
            }
        }

        NSLog("[TwilioVoice] Unable to locate the bundled Twilio Voice JS SDK. lookupKey='\(key)'; tried: \(candidates.map { $0.path }.joined(separator: ", "))")
        return nil
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// Runs [completionHandler] once the Twilio JS SDK is available in the webview (i.e.
    /// `Twilio.Device` is defined).
    ///
    /// The SDK itself is bundled and injected as a `WKUserScript` at document start (see
    /// [injectTwilioVoiceSDK]), so there is no network fetch to wait on - but the webview still
    /// loads `index.html` **asynchronously**. A call made shortly after launch can therefore
    /// arrive before the document exists, when `evaluateJavaScript` has nothing to evaluate
    /// against. This polls until the SDK is reachable, or the retry budget is exhausted.
    ///
    /// Completes with `false` if the SDK never becomes available (e.g. the webview failed to
    /// attach, or the bundled asset could not be loaded) so callers can fail cleanly instead of
    /// operating against an undefined `Twilio.Device`. The check re-runs on every call, so a
    /// later attempt still succeeds once the webview is ready.
    func whenSDKReady(retries: Int = 30, interval: TimeInterval = 0.5, completionHandler: @escaping (Bool) -> Void) {
        evaluateJavaScript("typeof Twilio !== 'undefined' && typeof Twilio.Device !== 'undefined'") { [weak self] result, _ in
            if (result as? Bool) == true {
                completionHandler(true)
            } else if retries > 0, let self = self {
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                    self.whenSDKReady(retries: retries - 1, interval: interval, completionHandler: completionHandler)
                }
            } else {
                completionHandler(false)
            }
        }
    }

    private func overrideLogging() {
        configuration.userContentController.addUserScript(WKUserScript(source: LoggingMessageHandler.js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(LoggingMessageHandler(), name: LoggingMessageHandler.handlerName)
    }

    /// Request microphone permissions via `getUserMedia`. This will first request app microphone permissions, followed by webview permissions.
    /// App microphone permissions can be checked, however Safari (Webkit Webview) does not allow checking webview permissions though Safari does via `navigator.permissions.query` (https://developer.mozilla.org/en-US/docs/Web/API/Permissions/query)
    /// Thus, we assume if we have app microphone permissions, the webview also has these same permissions.
    /// Note: If the user denies app microphone permissions, we will not request webview permissions and will need to rely on the user to manually enable them.
    ///
    /// - Parameter: completionHandler: completion handler: true if successfully executed, false otherwise. Permissions are not guaranteed, the return value does not indicate whether the user granted permissions.
    public func getUserMedia(_ audio: Bool = true, _ video: Bool = false, completionHandler: @escaping OnCompletionHandler<Bool>) -> Void {
        let JS = """
                  var _mediaStream = undefined;
                  if (typeof navigator.mediaDevices !== "undefined" && typeof navigator.mediaDevices.getUserMedia === "function") {
                    var _ = navigator.mediaDevices.getUserMedia({audio: \(audio), video: \(video)}).then(function (stream) {
                        log('Got user media stream');
                        _mediaStream = stream;
                    }).catch(function (err) {
                        log('Failed to get user media stream: ' + err);
                    });
                  } else {
                    log('navigator.mediaDevices or navigator.mediaDevices.getUserMedia not supported. Are you running this in a secure context?');
                  }
                 """
        self.evaluateJavaScript(javascript: JS, sourceURL: "getUserMedia") { (result, error) in
            if let error = error {
                print("Error requesting user media permissions: \(error)")
                completionHandler(false, error)
            } else {
                completionHandler(true, nil)
            }
        }
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

        if (javascript.last(where: { !$0.isWhitespace }) != ";" && javascript.last(where: { !$0.isWhitespace }) != "}") {
            if self.loggingEnabled {
                NSLog("[JS] WARNING: [sourceURL: \(sourceURL ?? "?")] evaluateJavascript does not end with a semicolon or a closing bracket, adding a semicolon.")
            }
            javascript += ";"
        }
//        NSLog("[JS] exec: \(javascript)")

        evaluateJavaScript(javascript) { (any, error) in
            if (error != nil) {
                if self.loggingEnabled {
                    NSLog("[JS] ERROR: evaluateJavascript error: \(String(describing: error))")
                    NSLog("[JS] ERROR: evaluateJavascript javascript: \(javascript)")
                    NSLog("[JS] ERROR: evaluateJavascript sourceURL: \(sourceURL ?? "?")")
                }
                completionHandler(nil, String(describing: error))
            } else {
                completionHandler(any, nil)
            }
        }
    }

    deinit {
        if self.loggingEnabled {
            NSLog("TVWebView deinit")
        }
    }

}
