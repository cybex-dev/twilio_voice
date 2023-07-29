import Foundation

public class TVOriginalError {
    var code: Int = -1
    var message: String = ""
    var twilioError: [String:Any] = [:]

    init (dict: [String: Any]) {
        if(dict["originalError"] == nil) {
            return
        }
        let dict = dict["originalError"] as! [String:Any]
        self.code = dict["code"] as? Int ?? -1
        self.message = dict["message"] as? String ?? ""
        self.twilioError = dict["twilioError"] as? [String:Any] ?? [:]
    }
}

public class TVError {
    var causes: [String] = []
    var code: Int = -1
    var explanation: String = ""
    var description: String = ""
    var message: String = ""
    var name: String = ""
    var originalError: TVOriginalError
    var solutions: [String] = []

    init (dict: [String: Any]) {
        self.code = dict["code"] as? Int ?? -1
        self.message = dict["message"] as? String ?? ""
        self.name = dict["name"] as? String ?? ""
        self.explanation = dict["explanation"] as? String ?? ""
        self.description = dict["description"] as? String ?? ""
        self.causes = dict["causes"] as? [String] ?? []
        self.solutions = dict["solutions"] as? [String] ?? []
        let originalError = dict["originalError"] as? [String: Any]
        self.originalError = TVOriginalError(dict: originalError ?? [:])
    }
}
