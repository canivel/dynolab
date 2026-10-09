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
            let said = body["error"] as? String
            throw Failure(errorDescription: explain((response as? HTTPURLResponse)?.statusCode ?? 0, said))
        }
        guard let link = body["review_url"] as? String, let url = URL(string: link), url.host == "research.dynolab.dev" else {
            throw Failure(errorDescription: "Uploaded, but the reply had no review link.")
        }
        return url
    }

    /// What went wrong, in words a person can act on.
    static func explain(_ status: Int, _ said: String?) -> String {
        switch status {
        case 401: return "The research token is invalid, expired or revoked. Forget it and paste a new one."
        case 403:
            if said?.contains("enabled") == true {
                return "Your account isn't enabled for uploads from Dyno yet. Ask to join the beta, or save the file and upload it on the site."
            }
            if said?.lowercased().contains("scope") == true {
                // A token made without "Allow private draft creation" can only read, and sharing creates a draft.
                return "This token can only read, so it can't upload. On research.dynolab.dev → Settings → Agents, create a new token with “Allow private draft creation” ticked, then click Forget here and paste the new one."
            }
            return said ?? "Dyno Research refused the upload."
        case 413: return "The package is larger than Dyno Research accepts (1 MB). Leave out thinking, or save the file instead."
        case 429: return said?.contains("daily") == true
            ? "You've reached today's limit of 10 drafts. Try again tomorrow, or save the file."
            : "Too many uploads in a minute. Wait a moment and try again."
        case 400: return (said.map { $0 + " " } ?? "") + "If the package is over 1 MB, leave out thinking or save the file instead."
        case 503: return "Dyno Research is unavailable right now. Try again in a minute."
        default: return said ?? "Dyno Research didn't accept the upload (HTTP \(status))."
        }
    }
}


/// A Hugging Face access token, for gated datasets in the benchmark library (Evals). Kept in the Keychain; sent
/// only with a run, to the worker that downloads the dataset, and never saved with the run.
enum HuggingFaceToken {
    private static let service = "dev.dynolab.huggingface-token"
    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult static func save(_ token: String) -> Bool {
        delete()
        return SecItemAdd([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "huggingface.co",
                           kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecValueData as String: Data(token.utf8)] as CFDictionary, nil) == errSecSuccess
    }
    static func delete() { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
}
