import Foundation

/// Колбэк прогресса (значение 0.0...1.0).
public typealias ProgressHandler = @Sendable (Double) -> Void
