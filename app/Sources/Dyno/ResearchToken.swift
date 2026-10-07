import Foundation
import Security

/// The person's Dyno Research API token (created at research.dynolab.dev/settings/agents), kept in the Keychain.
/// It can create private drafts; only the person can publish, on the website.
enum ResearchToken {
    private static let service = "dev.dynolab.research-token"

    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult static func save(_ token: String) -> Bool {
        delete()
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                         kSecAttrAccount as String: "research.dynolab.dev",
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                         kSecValueData as String: Data(token.utf8)]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }
}

/// Uploads a test package to Dyno Research as a private draft. Returns the draft's review page.
enum ResearchUpload {
    struct Failure: LocalizedError { var errorDescription: String? }

    static func draft(_ package: [String: Any], token: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "https://research.dynolab.dev/api/v1/studies")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: package)
        request.timeoutInterval = 60
        // The API refuses browser-like requests: no cookies, no shared session.
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        let (data, response) = try await URLSession(configuration: config).data(for: request)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            throw Failure(errorDescription: body["error"] as? String ?? "Dyno Research didn't accept the upload.")
        }
        guard let link = body["review_url"] as? String, let url = URL(string: link), url.host == "research.dynolab.dev" else {
            throw Failure(errorDescription: "Uploaded, but the reply had no review link.")
        }
        return url
    }
}
