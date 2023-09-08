import Foundation
import WebKit

/// Javascript library loader from stored Bundle
class JSLibLoader: JSLoader {
    var bundle: Bundle

    init(fromBundle: AnyClass, library: String) {
        bundle = Bundle(for: fromBundle)
        super.init(sourceURL: library)
    }

    /// Given a file name, loads and returns the content of that file
    /// - Parameter fromBundle: bundle class
    /// - Parameter file: file name
    /// - Parameter ofType: file extension
    /// - Parameter completionHandler: completion handler
    /// - Returns: content of file
    func loadFile(file: String, ofType: String, completionHandler: OnCompletionHandler<String>) -> Void {
        if let filePath = bundle.path(forResource: file, ofType: ofType) {
            let content: String? = try? String(contentsOfFile: filePath)
            completionHandler(content, nil)
        } else {
            completionHandler(nil, "Error loading \(file).\(ofType) (\(sourceURL))")
        }
    }
}
