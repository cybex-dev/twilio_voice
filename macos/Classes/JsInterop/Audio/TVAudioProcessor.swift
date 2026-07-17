import Foundation
import WebKit

/// Object describing a Twilio [AudioProcessor](https://twilio.github.io/twilio-voice.js/interfaces/AudioProcessor.html)
/// used for local call holding: [createProcessedStream] replaces the outbound (mic) stream with
/// hold audio (or silence if no [holdAudioUrl] is provided) built via the Web Audio API.
///
/// The `createProcessedStream`/`destroyProcessedStream` members must be implemented in JS since
/// the Twilio Voice JS SDK invokes them directly inside the webview; everything else (creation,
/// registration, lifecycle) is driven natively - see [TVDevice.addAudioProcessor] and
/// [TwilioVoicePlugin.holdCall].
public class TVAudioProcessor: JSObject {

    required init(overrideJSObjectName: String = "_tvHoldProcessor", webView: TVWebView) {
        super.init(jsObjectName: overrideJSObjectName, webView: webView, initialize: true)
    }

    /// (Re)creates the JS AudioProcessor object, baking in the hold audio URL and repeat delay
    /// for the next hold.
    ///
    /// - Parameter holdAudioUrl: URL of hold audio played to the remote party, silence if nil
    /// - Parameter holdAudioDelayMs: silence in milliseconds between hold audio repetitions, 0 loops seamlessly
    /// - Parameter completionHandler: completion handler
    func create(holdAudioUrl: String?, holdAudioDelayMs: Int = 0, completionHandler: @escaping OnCompletionErrorHandler) {
        let audioUrlJS = TVAudioProcessor.toJSStringLiteral(holdAudioUrl)
        let JS = """
                 \(jsObjectName) = {
                    audioEl: null,
                    audioCtx: null,
                    replayTimer: null,
                    holdAudioUrl: \(audioUrlJS),
                    holdAudioDelayMs: \(max(holdAudioDelayMs, 0)),
                    createProcessedStream: async function (stream) {
                        \(jsObjectName).audioCtx = new AudioContext();
                        const destination = \(jsObjectName).audioCtx.createMediaStreamDestination();
                        if (\(jsObjectName).holdAudioUrl) {
                            const audioEl = new Audio(\(jsObjectName).holdAudioUrl);
                            \(jsObjectName).audioEl = audioEl;
                            audioEl.crossOrigin = "anonymous";
                            if (\(jsObjectName).holdAudioDelayMs > 0) {
                                // play -> delay of silence -> replay, instead of a seamless loop
                                audioEl.onended = () => {
                                    clearTimeout(\(jsObjectName).replayTimer);
                                    \(jsObjectName).replayTimer = setTimeout(() => {
                                        if (\(jsObjectName).audioEl === audioEl) {
                                            audioEl.play().catch((e) => console.error("Failed to replay hold audio: " + e));
                                        }
                                    }, \(jsObjectName).holdAudioDelayMs);
                                };
                            } else {
                                audioEl.loop = true;
                            }
                            \(jsObjectName).audioCtx.createMediaElementSource(audioEl).connect(destination);
                            audioEl.play().catch((e) => console.error("Failed to play hold audio: " + e));
                        }
                        // with no source attached, the destination yields a silent stream
                        return destination.stream;
                    },
                    destroyProcessedStream: async function (stream) {
                        clearTimeout(\(jsObjectName).replayTimer);
                        \(jsObjectName).replayTimer = null;
                        if (\(jsObjectName).audioEl) {
                            \(jsObjectName).audioEl.pause();
                            \(jsObjectName).audioEl = null;
                        }
                        if (\(jsObjectName).audioCtx) {
                            await \(jsObjectName).audioCtx.close().catch(() => {});
                            \(jsObjectName).audioCtx = null;
                        }
                        if (stream) {
                            stream.getTracks().forEach((t) => t.stop());
                        }
                    }
                 }; true;
                 """
        webView.evaluateJavaScript(javascript: JS, sourceURL: "\(jsObjectName)_create") { (_, error) in
            completionHandler(error)
        }
    }

    /// Escapes a Swift string into a quoted JS string literal, or `null` if nil.
    private static func toJSStringLiteral(_ value: String?) -> String {
        guard let value = value else {
            return "null"
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - Disposable

    public override func dispose() {
        // detach webkit message handler before super removes it from the active list, else a
        // future TVAudioProcessor with the same name would double-register and crash
        detachMessageHandler()
        super.dispose()
    }

    deinit {
        print("TVAudioProcessor deinit")
    }
}
