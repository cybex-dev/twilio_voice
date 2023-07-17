import Foundation
import WebKit

protocol JSObject {
    var jsObjectName: String { get set }
    var webView: TVWebView { get set }
}
