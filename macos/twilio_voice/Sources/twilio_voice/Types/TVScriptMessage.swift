import Foundation
import WebKit

public protocol TVScriptMessageStruct: AnyObject {
    var handler: String { get }
    var type: String { get }
    var args: [Any] { get }
    var name: String { get }
    var body: Any { get }
}

// TODO (cybex-dev) : Temporary solution adding [name, body], inherit from WKScriptMessage in future
public class TVScriptMessage: TVScriptMessageStruct {
    public var name: String {
        get {
            originalMessage.name
        }
    }

    public var body: Any {
        get {
            originalMessage.body
        }
    }

    public let handler: String

    public let type: String

    public let args: [Any]

    public let originalMessage: WKScriptMessage

    init(message: WKScriptMessage) {
        self.originalMessage = message

        let body = message.body as? [String: Any] ?? [:]
        self.handler = message.name
        self.type = body["type"] as? String ?? ""
        let json = body["args"] as? String ?? "{}"
        do {
            if let data = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any] {
                self.args = data
            } else {
                self.args = []
            }
        } catch {
            self.args = []
        }
    }
}
