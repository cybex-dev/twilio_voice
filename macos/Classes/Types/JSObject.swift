import Foundation
import WebKit

/// Receives and broadcasts messages from webkit message handler's postMessage call
/// - SeeAlso: Webkit [postMessage](https://developer.apple.com/documentation/webkit/wkscriptmessagehandler#overview)
protocol JSMessageHandlerDelegate: AnyObject {

    /// Called when a message is received from a webkit message handler's postMessage call. Received message conforms to format: {handlerName: String, args: [Any]}
    /// - Parameters:
    ///   - jsObject: object handler that received the message
    ///   - message: raw message
    func onJSMessageReceived(_ jsObject: JSObject, message: TVScriptMessage)
}

/// Javascript interface object, providing access to native functionality:
/// - Assign: Create new object (static)
/// - Call: method calls on object
/// - Property: getter of object members
///

// TODO(cybex-dev) - add callaAsyncJavascript for true promise resolve/reject w/ return values in `call` functions

public class JSObject: NSObject, WKScriptMessageHandler {

    private let handlerName: String = "handlerName"
    private let type: String = "type"
    private let args: String = "args"
    // message handler flag (since no check function exists) in webkit library
    var handlerAttached: Bool = false

    public var jsObjectName: String
    var webView: TVWebView
    weak var jsObjectDelegate: JSMessageHandlerDelegate?

    /// Post message result from JSObject messageHandlers
    /// - Parameters:
    ///   - userContentController: content controller
    ///   - message: raw message
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let message = TVScriptMessage.init(message: message)
        jsObjectDelegate?.onJSMessageReceived(self, message: message)
    }

    /// Constructor
    /// - Parameters:
    ///   - jsObjectName: object name
    ///   - webView: webview
    ///   - initialize: initialize object with `let x;` if true
    init(jsObjectName: String, webView: TVWebView, initialize: Bool = false) {
        self.jsObjectName = jsObjectName
        self.webView = webView
        super.init()
        handlerAttached = false
        if initialize {
            let JS = "var \(jsObjectName);"
            webView.evaluateJavaScript(javascript: JS, sourceURL: "\(jsObjectName)_init") { result, error in
                if let error = error {
                    print("Error initializing JSObject: \(error)")
                }
            }
        }
        attachMessageHandler()
    }

    func attachMessageHandler() -> Void {
        if !handlerAttached {
            print("[\(jsObjectName)] Attaching message handler")
            handlerAttached = true
            webView.configuration.userContentController.add(self, name: jsObjectName)
        }
    }

    func detachMessageHandler() -> Void {
        if handlerAttached {
            print("[\(jsObjectName)] Detaching message handler")
            handlerAttached = false
            webView.configuration.userContentController.removeScriptMessageHandler(forName: jsObjectName)
        }
    }

    /// Add event listener to JSObject
    /// - Parameters:
    ///   - event: event name
    ///   - onTriggeredAction: javascript to run when event is triggered
    ///   - completionHandler: completion handler: true if event listener was added
    ///
    /// - Example:
    /// ```
    /// var _on_event__device_ready = function(..args) {
    ///    // onTriggeredAction
    ///    log("🔹", 'Hey, new call');
    ///    window.webkit.messageHandlers._device_ready.postMessage({handlerName: '_device_ready', args: JSON.stringify(args)});
    /// }
    /// _device.on('ready', _on_event__device_ready);
    /// ```
    func addEventListener(_ event: String, onTriggeredAction: String? = nil, completionHandler: OnCompletionHandler<Bool>? = nil) {
        print("[\(jsObjectName)] Adding event listener: \(event)")
        let JS = """
                    var _on_event_\(jsObjectName)_\(event) = function(...args) {
                        log("🔹", `triggering event: \(event) with argsLength: ${args.length}: ${JSON.stringify(args)}`);
                        \(onTriggeredAction != nil ? "\(onTriggeredAction!);" : "");
                        if(args.length === 1 && args[0] === undefined) {
                            log('args is undefined, setting to empty array');
                            args = [];
                        }
                        window.webkit.messageHandlers.\(jsObjectName).postMessage({'\(handlerName)': '\(jsObjectName)', '\(type)': '\(event)', '\(args)': JSON.stringify(args)});
                    }
                    \(jsObjectName).on('\(event)', _on_event_\(jsObjectName)_\(event)); true;
                 """
        webView.evaluateJavaScript(javascript: JS, sourceURL: "\(jsObjectName)_addEventListener(\(event))") { result, error in
            if let error = error {
                completionHandler?(false, error)
            } else {
                self.attachMessageHandler()
                completionHandler?(result as? Bool, nil)
            }
        }
    }

    /// Remove event listener from JSObject
    /// - Parameters:
    ///   - event: event name
    ///   - completionHandler: completion handler: true if event listener was removed, false otherwise
    ///
    /// - Example:
    /// ```
    /// if (typeof _on_event__device_ready !== 'undefined') {
    ///    device.off('ready', _on_event__device_ready);
    /// }
    /// delete _on_event__device_ready;
    /// ```
    func removeEventListener(_ event: String, completionHandler: OnCompletionHandler<Bool>? = nil) {
        print("[\(jsObjectName)] Removing event listener: \(event)")
        let JS = """
                    log("🔹", 'removeEventListener: \(event)');
                    if (typeof _on_event_\(jsObjectName)_\(event) !== 'undefined') {
                        \(jsObjectName).off('\(event)', _on_event_\(jsObjectName)_\(event));
                        delete _on_event_\(jsObjectName)_\(event); true;
                    }
                 """
        webView.evaluateJavaScript(javascript: JS, sourceURL: "\(jsObjectName)_removeEventListener(\(event))") { result, error in
            self.detachMessageHandler()

            if let error = error {
                print("Error removing event listener: \(error)")
                completionHandler?(false, error)
            } else {
                completionHandler?(result as? Bool, nil)
            }
        }
    }

    /// Check if has an associated javascript object
    /// - Parameter name: member name, defaults to [self.jsObjectName]
    /// - Parameter completionHandler: <#completionHandler description#>
    ///
    /// - Example:
    /// ```
    /// typeof _device !== 'undefined';
    /// ```

    func defined(_ name: String? = nil, completionHandler: @escaping (_ result: Bool) -> Void) {
        let js = "typeof \(name ?? jsObjectName) !== 'undefined';"
        webView.evaluateJavaScript(javascript: js, sourceURL: "\(jsObjectName)_defined") { result, error in
            if let error = error {
                print("Error checking if defined: \(error)")
            }
            completionHandler(result as? Bool ?? false)
        }
    }

    /// Call a method on the javascript object
    /// - Parameters:
    ///   - method: javascript method name
    ///   - ignoreResult: ignore result by adding a true callback
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// _device.doSomething();
    /// ```
    func call(method: String, ignoreResult: Bool = false, completionHandler: @escaping OnCompletionHandler<Any>) -> Void {
        let JS = """
                 if(!!\(jsObjectName) && typeof \(jsObjectName).\(method) === 'function') {
                    \(jsObjectName).\(method)(); \(ignoreResult ? "true;" : "")
                 } else {
                    throw new Error('\(jsObjectName).\(method) is not a function');
                 }
                 """
        webView.evaluateJavaScript(javascript: JS, sourceURL: "\(jsObjectName)_\(method)", completionHandler: completionHandler)
    }

    /// Call a method on the javascript object with arguments
    /// - Parameters:
    ///   - method: javascript method name
    ///   - withArgs: arguments to pass to the method (must be JSON encodable)
    ///   - ignoreResult: ignore result by adding a true callback
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// _device.doSomething("123");
    /// ```
    func call(method: String, withArgs: [Any], ignoreResult: Bool = false, completionHandler: @escaping (_ result: Any?, _ error: String?) -> Void) {
        let argsString = JSObject.toArgString(withArgs)
        let JS = """
                 if(!!\(jsObjectName) && typeof \(jsObjectName).\(method) === 'function') {
                    \(jsObjectName).\(method)(\(argsString)); \(ignoreResult ? "true;" : "")
                 } else {
                    throw new Error('\(jsObjectName).\(method) is not a function');
                 }
                 """

        webView.evaluateJavaScript(javascript: JS, sourceURL: "\(jsObjectName)_\(method)(args)", completionHandler: completionHandler)
    }

    /// Call a method on the javascript object and assign the result to a JS variable
    /// - Parameters:
    ///   - method: javascript method name
    ///   - assignTo: assign to JS variable
    ///   - wait: await for result
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// _test = await _device.doSomething();
    /// ```
    func call(method: String, assignTo: String, wait: Bool = false, completionHandler: @escaping (_ result: Any?, _ error: String?) -> Void) {
        assert(!(assignTo.isEmpty && wait), "Cannot await on a method call without assigning to a variable. Use call(method:assignTo:completionHandler:) instead.")
        let JS = """
                 if(!!\(jsObjectName) && typeof \(jsObjectName).\(method) === 'function') {
                    \(assignTo) = \(wait ? "await" : "") \(jsObjectName).\(method)();
                 } else {
                    throw new Error('\(jsObjectName).\(method) is not a function');
                 }
                 """
        webView.evaluateJavaScript(javascript: JS, sourceURL: "assign_\(jsObjectName)_\(method)", completionHandler: completionHandler)
    }

    /// Call a method on the javascript object with arguments and assign the result to a JS variable
    /// - Parameters:
    ///   - method: javascript method name
    ///   - withArgs: arguments to pass to the method (must be JSON encodable)
    ///   - assignTo: assign to JS variable
    ///   - wait: await for result
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// _test = await _device.doSomething("123");
    /// ```
    func call(method: String, withArgs: [Any], assignTo: String, wait: Bool = false, completionHandler: @escaping (_ result: Any?, _ error: String?) -> Void) {
        assert(!(assignTo.isEmpty && wait), "Cannot await on a method call without assigning to a variable. Use call(method:assignTo:completionHandler:) instead.")
        let argsString = JSObject.toArgString(withArgs)
        let JS = """
                 if(!!\(jsObjectName) && typeof \(jsObjectName).\(method) === 'function') {
                    \(assignTo) = \(wait ? "await" : "") \(jsObjectName).\(method)(\(argsString));
                 } else {
                    throw new Error('\(jsObjectName).\(method) is not a function');
                 }
                 """
        webView.evaluateJavaScript(javascript: JS, sourceURL: "assign_\(jsObjectName)_\(method)_args", completionHandler: completionHandler)
    }

    /// Create a new javascript object
    /// - Parameters:
    ///   - webView: webview
    ///   - objectName: object name e.g. Twilio.Device
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// new Twilio.Device();
    /// ```
    static func assign(webView: TVWebView, objectName: String, completionHandler: @escaping (_ result: Any?, _ error: String?) -> Void) {
        let JS = "new \(objectName)();"
        webView.evaluateJavaScript(javascript: JS, sourceURL: "new_\(objectName)", completionHandler: completionHandler)
    }

    /// Create a new javascript object and assign to a JS variable
    /// - Parameters:
    ///   - webView: webview
    ///   - objectName: object name e.g. Twilio.Device
    ///   - assignTo: assign to JS variable
    ///   - mutatable: if true, the object can be mutated by the JS side i.e. var instead of const
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// var device = new Twilio.Device();
    /// ```
    static func assign(webView: TVWebView, objectName: String, assignTo: String, mutatable: Bool = false, completionHandler: @escaping (_ result: Any?, _ error: String?) -> Void) {
        let JS = "\(mutatable ? "var" : "const") \(assignTo) = new \(objectName)()';"
        webView.evaluateJavaScript(javascript: JS, sourceURL: "new_\(objectName)", completionHandler: completionHandler)
    }

    /// Call a method on the javascript object with arguments and assign the result to a JS variable
    /// - Parameters:
    ///   - webView: webview
    ///   - objectName: object name e.g. Twilio.Device
    ///   - withArgs: arguments to pass to the method (must be JSON encodable)
    ///   - assignTo: assign to JS variable
    ///   - mutatable: if true, the object can be mutated by the JS side i.e. var instead of const
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// var device = new Twilio.Device("123");
    /// ```
    static func assign(webView: TVWebView, objectName: String, withArgs: [Any], assignTo: String, mutatable: Bool = false, completionHandler: @escaping (_ result: Any?, _ error: String?) -> Void) {
        let argsString = toArgString(withArgs)
        let JS = "\(mutatable ? "var" : "const") \(assignTo) = new \(objectName)(\(argsString));"
        webView.evaluateJavaScript(javascript: JS, sourceURL: "new_\(objectName)", completionHandler: completionHandler)
    }

    /// Get a member property value of the javascript object
    /// - Parameters:
    ///   - name: javascript member name
    ///   - ofType: Type
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// _device.status;
    /// ```
    func property<T>(ofType: T.Type, name: String, completionHandler: @escaping OnCompletionHandler<T>) {
        let JS = """
                 if(\(jsObjectName) && typeof \(jsObjectName).\(name) !== 'undefined') {
                    \(jsObjectName).\(name);
                 } else {
                    throw new Error('\(jsObjectName).\(name) is not a property');
                 }
                 """
        webView.evaluateJavaScript(javascript: JS, sourceURL: "\(jsObjectName)_\(name)") { result, error in
            if let error = error {
                completionHandler(nil, error)
            } else {
                completionHandler(result as? T, nil)
            }
        }
    }

    /// Delete a javascript object
    /// - Parameters:
    ///   - objectName: javascript member name
    ///   - completionHandler: completion handler
    ///
    /// - Example:
    /// ```
    /// delete _device;
    /// ```
    func delete(objectName: String, completionHandler: @escaping OnCompletionErrorHandler) {
        let JS = """
                 if(\(jsObjectName)) {
                    delete \(jsObjectName);
                 } else {
                    throw new Error('\(jsObjectName) is not defined');
                 }
                 """
        webView.evaluateJavaScript(javascript: JS, sourceURL: "dispose_\(objectName)") { result, error in
            if let error = error {
                completionHandler(error)
            } else {
                completionHandler(nil)
            }
        }
    }

    static private func toArgString(_ args: [Any]) -> String {
        args.map {
                    if let arg = $0 as? String {
                        return "\"\(arg)\""
                    } else if let arg = $0 as? Bool {
                        return arg ? "true" : "false"
                    } else if let arg = $0 as? Int {
                        return "\(arg)"
                    } else if let arg = $0 as? Double {
                        return "\(arg)"
                    } else if let arg = $0 as? [String: Any] {
                        return arg.map {
                                    "\"\($0.key)\": \($0.value)"
                                }
                                .joined(separator: ", ")
                    } else if let arg = $0 as? JSONArgumentSerializer {
                        return arg.toObjectArgs()
                    } else {
                        return "\($0)"
                    }
                }
                .joined(separator: ", ")
    }
}
