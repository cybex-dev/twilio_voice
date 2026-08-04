import Foundation

/// Parameters for an active call, resolves:
// - caller,
// - recipient,
// - CallSid, and
// - additional custom parameters provided by TWIML app
public class TVCallParams: JSONArgumentSerializer {
    let to: String?
    let from: String?
    let callSid: String?
    let customParameters: [String: Any]

    init(parameters: [String: Any]) {
        customParameters = parameters
        to = parameters[Constants.PARAM_TO] as? String
        from = parameters[Constants.PARAM_FROM] as? String
        callSid = parameters[Constants.PARAM_CALL_SID] as? String
    }

    init(parameters: [String: Any], customParameters: [String: Any]) {
        self.customParameters = customParameters.merging(parameters) { (first, _) in
            first
        }
        to = parameters[Constants.PARAM_TO] as? String
        from = parameters[Constants.PARAM_FROM] as? String
        callSid = parameters[Constants.PARAM_CALL_SID] as? String
    }

    public override func toDictionary() -> [String: Any] {
        customParameters
    }
}
