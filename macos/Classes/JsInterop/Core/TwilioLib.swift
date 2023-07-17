import Foundation
import WebKit

public class TwilioLibLoader {
    let userContentController: WKUserContentController
    
    init(userContentController: WKUserContentController) {
        self.userContentController = userContentController
        load(controller: userContentController)
    }
    
    public func load(controller: WKUserContentController) {
        // load twilio library
        //
    }
    
    public func unload(controller: WKUserContentController) {
        
    }
}
