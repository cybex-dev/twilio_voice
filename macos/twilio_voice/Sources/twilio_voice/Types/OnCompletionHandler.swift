/// Closure for completion handler, with generic optional result and optional error
public typealias OnCompletionHandler<T> = (T?, String?) -> Void

/// Closure for completion handler, with optional error
public typealias OnCompletionErrorHandler = (String?) -> Void

/// Closure for completion handler, with optional result
public typealias OnCompletionValueHandler<T> = (T?) -> Void
