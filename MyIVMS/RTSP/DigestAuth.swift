import Foundation
import CryptoKit

/// RFC 2617 Digest / Basic authentication for RTSP.
///
/// Hikvision devices default to Digest auth on RTSP. We parse the
/// `WWW-Authenticate` header from a 401 response and generate the
/// `Authorization` header for the retried request.
struct HTTPAuthenticator {
    enum Scheme { case basic, digest }

    let scheme: Scheme
    let realm: String
    let nonce: String
    let qop: String?
    let opaque: String?
    let algorithm: String

    private let username: String
    private let password: String
    private var nonceCount = 0

    /// Parse a `WWW-Authenticate` header value. Returns nil if unsupported.
    init?(header: String, username: String, password: String) {
        self.username = username
        self.password = password

        let lower = header.lowercased()
        if lower.hasPrefix("digest") {
            self.scheme = .digest
        } else if lower.hasPrefix("basic") {
            self.scheme = .basic
            self.realm = HTTPAuthenticator.field("realm", in: header) ?? ""
            self.nonce = ""
            self.qop = nil
            self.opaque = nil
            self.algorithm = "MD5"
            return
        } else {
            return nil
        }

        self.realm = HTTPAuthenticator.field("realm", in: header) ?? ""
        self.nonce = HTTPAuthenticator.field("nonce", in: header) ?? ""
        self.qop = HTTPAuthenticator.field("qop", in: header)
        self.opaque = HTTPAuthenticator.field("opaque", in: header)
        self.algorithm = HTTPAuthenticator.field("algorithm", in: header) ?? "MD5"
    }

    /// Build the `Authorization` header value for a request.
    mutating func authorization(method: String, uri: String) -> String {
        switch scheme {
        case .basic:
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            return "Basic \(token)"
        case .digest:
            return digestAuthorization(method: method, uri: uri)
        }
    }

    private mutating func digestAuthorization(method: String, uri: String) -> String {
        let ha1 = Self.md5("\(username):\(realm):\(password)")
        let ha2 = Self.md5("\(method):\(uri)")

        var response = ""
        var parts = [
            "username=\"\(username)\"",
            "realm=\"\(realm)\"",
            "nonce=\"\(nonce)\"",
            "uri=\"\(uri)\"",
        ]

        if let qop, qop.contains("auth") {
            nonceCount += 1
            let nc = String(format: "%08x", nonceCount)
            let cnonce = Self.md5(UUID().uuidString)
            response = Self.md5("\(ha1):\(nonce):\(nc):\(cnonce):auth:\(ha2)")
            parts.append("qop=auth")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\"\(cnonce)\"")
        } else {
            response = Self.md5("\(ha1):\(nonce):\(ha2)")
        }

        parts.append("response=\"\(response)\"")
        if let opaque { parts.append("opaque=\"\(opaque)\"") }
        return "Digest " + parts.joined(separator: ", ")
    }

    // MARK: Helpers

    private static func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Extract `key="value"` or `key=value` from a header, case-insensitively.
    private static func field(_ key: String, in header: String) -> String? {
        // Quoted form: key="..."
        if let range = header.range(of: "\(key)=\"", options: .caseInsensitive) {
            let rest = header[range.upperBound...]
            if let end = rest.firstIndex(of: "\"") {
                return String(rest[..<end])
            }
        }
        // Unquoted form: key=value (up to comma / whitespace)
        if let range = header.range(of: "\(key)=", options: .caseInsensitive) {
            let rest = header[range.upperBound...]
            let end = rest.firstIndex { $0 == "," || $0 == " " } ?? rest.endIndex
            let value = String(rest[..<end])
            if !value.hasPrefix("\"") { return value }
        }
        return nil
    }
}
