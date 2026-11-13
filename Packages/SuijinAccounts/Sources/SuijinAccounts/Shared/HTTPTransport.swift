import Foundation

/// Sends one HTTP request. Injected in tests so usage parsing runs against fixtures.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral `URLSession` (no cookies, no cache) with a 10 second request and resource timeout.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 10) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        return (data, http)
    }
}

enum UsageHTTP {
    /// Sends the request and maps transport and status failures to `UsageError` (never echoing headers).
    static func fetchJSON(_ request: URLRequest, transport: any HTTPTransport) async throws -> [String: Any] {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as UsageError {
            throw error
        } catch let error as URLError {
            throw UsageError.transport(error.code == .timedOut ? "timed out" : "network error \(error.code.rawValue)")
        } catch {
            throw UsageError.transport("network error")
        }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw UsageError.unauthorized(status: response.statusCode)
        case 429: throw UsageError.rateLimited(retryAfter: retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        default: throw UsageError.httpStatus(response.statusCode)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        return object
    }

    /// Upper bound for a server-requested delay, so a corrupt header cannot stop polling for good.
    static let maxRetryAfter: TimeInterval = 24 * 60 * 60

    /// `Retry-After` as delta seconds or an HTTP date, relative to `now`; nil when absent or unreadable.
    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let text = value?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let seconds = TimeInterval(text), seconds.isFinite {
            return seconds > 0 ? min(seconds, maxRetryAfter) : nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: text) else { return nil }
        let delay = date.timeIntervalSince(now)
        return delay > 0 ? min(delay, maxRetryAfter) : nil
    }
}

/// Number helpers for loosely typed JSON.
enum JSONNumber {
    static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        // JSON booleans also bridge to NSNumber; they are never a valid number here.
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

enum UsageDates {
    /// Claude resets: epoch seconds or milliseconds (1e10 separates them), a numeric string, or an ISO 8601 string.
    static func claudeReset(_ value: Any?) -> Date? {
        if let number = JSONNumber.double(value) { return epoch(number) }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let number = Double(text), number.isFinite { return epoch(number) }
        return iso8601(text)
    }

    private static func epoch(_ value: Double) -> Date {
        Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }

    static func iso8601(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // Microsecond fractions ("...:00.123456+00:00") are cut to milliseconds, which the formatter accepts.
        if let range = text.range(of: #"\.\d{4,}"#, options: .regularExpression) {
            let trimmed = text.replacingCharacters(in: range, with: String(text[range].prefix(4)))
            return withFraction.date(from: trimmed)
        }
        return nil
    }
}
