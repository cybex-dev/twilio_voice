import Foundation

/// Device Connect options
/// Documentation: https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#connectoptions
public class TVDeviceConnectOptions: JSONArgumentSerializer {
    // TODO(cybex-dev) - add region, edge information, etc.
    var params: [String: String] = [:]

    init(to: String, from: String, customParameters: [String:Any]) {
        params[Constants.PARAM_TO] = to
        params[Constants.PARAM_FROM] = from
        let stringMap = customParameters.map({ (key, value) -> (String, String) in
            (key, String(describing: value))
        });
        params.merge(stringMap) { (_, new) in new }
    }

    public override func toDictionary() -> [String:Any] {
        [Constants.PARAM_CONNECT_PARAMS: params]
    }
}
