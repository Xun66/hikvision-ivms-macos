import Foundation

enum HikvisionTime {
    static func rtspTimestamp(_ date: Date) -> String {
        formatter("yyyyMMdd't'HHmmss'z'").string(from: date)
    }

    static func isapiTimestamp(_ date: Date) -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss'Z'").string(from: date)
    }

    static func parseISAPITime(_ string: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"] {
            if let date = formatter(format).date(from: string) {
                return date
            }
        }
        return nil
    }

    private static func formatter(_ dateFormat: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = dateFormat
        return formatter
    }
}
