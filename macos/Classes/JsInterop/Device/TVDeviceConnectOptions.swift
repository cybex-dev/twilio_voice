import Foundation

/// Device Connect options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connectoptions
public class TVDeviceConnectOptions: JSONArgumentSerializer {
    let to: String
    let from: String
    let customParameters: Dictionary<String, Any>

    init(to: String, from: String, customParameters: Dictionary<String, Any>) {
        self.to = to
        self.from = from
        self.customParameters = customParameters
    }

    public override func toDictionary() -> [String:Any] {
        [Constants.PARAM_TO: to, Constants.PARAM_FROM: from].merging(customParameters) { (_, new) in
            new
        }
    }
}
