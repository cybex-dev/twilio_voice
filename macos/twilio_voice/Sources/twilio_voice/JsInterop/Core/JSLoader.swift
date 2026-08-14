import Foundation
import WebKit

/// Object describing a JS Object and associated script
class JSLoader {
    var jsObjectName: String?
    var script: String?
    var sourceURL: String

    init(sourceURL: String) {
        self.sourceURL = sourceURL
    }

    init(script: String?, sourceURL: String) {
        self.script = script
        self.sourceURL = sourceURL
    }

    init(jsObjectName: String?, script: String?, sourceURL: String) {
        self.jsObjectName = jsObjectName
        self.script = script
        self.sourceURL = sourceURL
    }
}
