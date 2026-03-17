import Foundation

// MARK: - Shared Timestamp Parser

/// Centralized timestamp parsing for all Open WebUI API responses.
/// The server may return timestamps in seconds, milliseconds, microseconds, or nanoseconds.
/// This utility detects the precision automatically and converts to `Date`.
enum TimestampParser {
    /// Converts a JSON value (Double, Int, or nil) to a `Date`.
    /// Returns the current date if the value is nil or unparseable.
    static func parse(_ value: Any?) -> Date {
        if let ts = value as? Double {
            return fromNumeric(ts)
        }
        if let ts = value as? Int {
            return fromNumeric(Double(ts))
        }
        return .now
    }
    
    /// Converts a JSON value to an optional `Date`.
    /// Returns nil if the value is nil or NSNull.
    static func parseOptional(_ value: Any?) -> Date? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        return parse(value)
    }
    
    /// Detects timestamp precision (seconds/ms/µs/ns) and converts to `Date`.
    /// Handles the Open WebUI API which may return nanosecond timestamps (19 digits).
    static func fromNumeric(_ ts: Double) -> Date {
        guard ts > 0 else { return .now }
        if ts > 1_000_000_000_000_000_000 {       // nanoseconds (19+ digits)
            return Date(timeIntervalSince1970: ts / 1_000_000_000)
        } else if ts > 1_000_000_000_000_000 {    // microseconds (16+ digits)
            return Date(timeIntervalSince1970: ts / 1_000_000)
        } else if ts > 1_000_000_000_000 {        // milliseconds (13+ digits)
            return Date(timeIntervalSince1970: ts / 1_000)
        } else {                                   // seconds (10 digits)
            return Date(timeIntervalSince1970: ts)
        }
    }
}
