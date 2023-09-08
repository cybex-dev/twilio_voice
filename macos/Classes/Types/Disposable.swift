import Foundation

/// Handler cleaning up an object
public protocol Disposable {

    /// Destroy and dispose of the object and associated handles
    func dispose() -> Void
}
