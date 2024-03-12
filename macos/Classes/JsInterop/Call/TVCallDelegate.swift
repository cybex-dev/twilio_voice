import Foundation

/// The [TVCall] delegate. Describes the events that can be triggered by a [TVCall]
/// - SeeAlso Twilio [Call.events](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#events)
public protocol TVCallDelegate: AnyObject {

    /// The [TVCall] is accepted.
    ///
    /// - Parameter call: the [TVCall] that was accepted
    /// - SeeAlso: Twilio [Call.accept](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#callacceptacceptoptions)
    func onCallAccept(_ call: TVCall) -> Void

    /// The [TVCall] is canceled.
    ///
    /// - Parameter call: the [TVCall] that was canceled
    /// - SeeAlso: Twilio [Call.reject](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#reject-event)
    func onCallCancel(_ call: TVCall) -> Void

    /// The [TVCall] is disconnected.
    ///
    /// - Parameter call: the [TVCall] that was disconnected
    /// - SeeAlso: Twilio [Call.disconnect](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#disconnect-event)
    func onCallDisconnect(_ call: TVCall) -> Void

    /// [TVCall] encountered an error
    ///
    /// - Parameter error: [TVError] that was encountered
    /// - SeeAlso: Twilio [Call.error](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#error-event)
    func onCallError(_ error: TVError) -> Void

    /// Ongoing [TVCall] RTC is reconnecting
    ///
    /// - Parameter error: [TVError] that was encountered
    /// - SeeAlso: Twilio [Call.reconnecting](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#reconnecting-event)
    func onCallReconnecting(_ error: TVError) -> Void

    /// Ongoing [TVCall] RTC has reconnected
    ///
    /// - SeeAlso: Twilio [Call.reconnecting](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#reconnected-event
    func onCallReconnected() -> Void

    /// The [TVCall] was rejected.
    ///
    /// - SeeAlso: Twilio [Call.reject](https://www.twilio.com/docs/voice/sdks/javascript/twiliocall#reject-event)
    func onCallReject() -> Void

    /// The [TVCall] status has changed.
    ///
    /// - Parameter status: [TVCallStatus] status change
    /// - SeeAlso: Undocumented change awaiting internal review & integration
    func onCallStatus(_ status: TVCallStatus) -> Void

}
