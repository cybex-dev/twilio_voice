import Foundation

/// The `TVDeviceDelegate` delegate. Describes the events that can be triggered by a [TVDevice]
/// - SeeAlso Twilio [Device.events](https://www.twilio.com/docs/voice/sdks/javascript/device#events)
protocol TVDeviceDelegate: AnyObject {
    /// The [TVDevice] has received an incoming call [TVCall].
    ///
    /// - Parameter call: [TVCall] instance
    /// - SeeAlso: Twilio [Device.incoming](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#incoming-event)
    func onDeviceIncoming(_ call: TVCall)

    /// The [TVDevice] is ready to receive incoming calls.
    /// - SeeAlso: Twilio [Device.registered](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#registered-event)
    func onDeviceRegistered()

    /// The [TVDevice] is registering to receive incoming calls.
    /// - SeeAlso: Twilio [Device.registering](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#registering-event)
    func onDeviceRegistering()

    /// The [TVDevice] has been unregistered and will no longer receive incoming calls.
    /// - SeeAlso: Twilio [Device.unregistered](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#unregistered-event)
    func onDeviceUnregistered()

    /// The [TVDevice] access token will expire in 3 minutes.
    /// - Parameter device: [TVDevice] instance
    /// - SeeAlso: Twilio [Device.tokenAboutToExpire](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#tokenwillexpire-event)
    func onDeviceTokenWillExpire(_ device: TVDevice)

    /// The [TVDevice] has encountered an error.
    ///
    /// - Parameter error: [TVError] instance
    /// - SeeAlso: Twilio [Device.error](https://www.twilio.com/docs/voice/sdks/javascript/twiliodevice#error-event)
    func onDeviceError(_ error: TVError)
}
