import Foundation

/// A private preview a person made in the desktop app (`sansora.preview/1`). It may hold an
/// unapproved draft, so it comes from its own route and never touches the config or events.
enum Preview {
    enum Failure: String, Error { case preview_not_found, preview_test_key_required, preview_unavailable }

    struct Response: Decodable { var schema: String; var definition: PaywallDefinition }

    /// XXXX-XXXX-XXXX in any case and spacing, with I/L and O read as 1 and 0. nil when it can't be a code.
    static func normalize(_ input: String) -> String? {
        var code = input.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        code = code.replacingOccurrences(of: "I", with: "1").replacingOccurrences(of: "L", with: "1").replacingOccurrences(of: "O", with: "0")
        return code.range(of: "^[0-9A-HJKMNP-TV-Z]{12}$", options: .regularExpression) != nil ? code : nil
    }

    static func fetch(baseURL: URL, publicKey: String, code: String, session: URLSession = .shared) async -> Result<PaywallDefinition, Failure> {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/sdk/preview/\(code)"))
        req.setValue(publicKey, forHTTPHeaderField: "X-Sansora-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .failure(.preview_unavailable) }
            if http.statusCode == 404 { return .failure(.preview_not_found) }
            if http.statusCode == 403 { return .failure(.preview_test_key_required) }
            guard http.statusCode == 200, let parsed = try? JSONDecoder().decode(Response.self, from: data), parsed.schema == "sansora.preview/1" else { return .failure(.preview_unavailable) }
            return .success(parsed.definition)
        } catch {
            return .failure(.preview_unavailable)
        }
    }
}
