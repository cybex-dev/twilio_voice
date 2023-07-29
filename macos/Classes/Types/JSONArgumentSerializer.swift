import Foundation

public class JSONArgumentSerializer {

    open func toDictionary() -> [String: Any] {
        [:]
    }

    /// Returns a string representation of the object in the form of a comma separated string
    ///  e.g. "to: 'client:alice',from: 'client:bob'"
    ///
    /// - Returns: String representation of the object
    func toArgs() -> String {
        let dict = toDictionary()
        let args = toArgParameters(params: dict)
        return args
    }

    /// Returns a string representation of the object in the form of a comma separated string encapsulated in curly braces
    /// e.g. "{to:'client:alice',from:'client:bob'}"
    ///
    /// - Returns: String representation of the object
    func toObjectArgs() -> String {
        "{\(toArgs())}"
    }

    /// Returns a string representation of the object in the form of a JSON string
    /// e.g. "{"to":"client:alice","from":"client:bob"}"
    ///
    /// - Returns: String representation of the object
    func toJSON() -> String {
        let dict = toDictionary()
        let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: jsonData!, encoding: .utf8)!
    }

    /// Returns a string representation of the object in the form of a comma separated string, transforming the values of the dictionary to the appropriate type argument for the function call
    ///
    /// - Parameter params: Dictionary of values
    /// - Returns: Commas separated argument string e.g. `"hello", 1, true, ["test1"], {key: "value"}`
    private func toArgParameters(params: [String: Any]) -> String {
        let p = params.map { (key, value) in
            if let arg = value as? String {
                return "\(key): '\(arg)'"
            } else if let arg = value as? Int {
                return "\(key): \(arg)"
            } else if let arg = value as? Bool {
                return "\(key): \(arg)"
            } else if let arg = value as? Double {
                return "\(key): \(arg)"
            } else if let arg = value as? JSONArgumentSerializer {
                return arg.toObjectArgs()
            } else if let arg = value as? [String: Any] {
                let s = toArgParameters(params: arg)
                return "\(key): {\(s)}"
            } else if let arg = value as? [String] {
                let s = arg.map { "'\($0)'" } .joined(separator: ",")
                return "\(key): [\(s)]"
            } else {
                return "undefined"
            }
        }
        return p.joined(separator: ",")
    }

    /// Returns a string representation of the object in the form of a comma separated string, transforming the values of an array to the appropriate type argument for the function call
    ///
    /// - Parameter params: Array of values
    /// - Returns: Commas separated argument string e.g. `"hello", 1, true, ["test1"], {key: "value"}`
    private func toArgList(params: [Any]) -> String {
        let p = params.map { (value) in
            if let arg = value as? String {
                return "'\(arg)'"
            } else if let arg = value as? Int {
                return "\(arg)"
            } else if let arg = value as? Bool {
                return "\(arg)"
            } else if let arg = value as? Double {
                return "\(arg)"
            } else if let arg = value as? JSONArgumentSerializer {
                return arg.toObjectArgs()
            } else if let arg = value as? [String: Any] {
                let s = toArgParameters(params: arg)
                return "{\(s)}"
            } else if let arg = value as? [String] {
                let s = arg.map { "'\($0)'" } .joined(separator: ",")
                return "[\(s)]"
            } else {
                return "undefined"
            }
        }
        return p.joined(separator: ",")
    }
}