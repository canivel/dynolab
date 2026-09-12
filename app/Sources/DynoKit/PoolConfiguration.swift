import Foundation

public enum PoolConfiguration {
    /// Replace connection fields only. Keep the chosen model, binary and execution settings.
    public static func merging(connection: Data, into configuration: String) throws -> String {
        guard var config = try JSONSerialization.jsonObject(with: Data(configuration.utf8)) as? [String: Any],
              let record = try JSONSerialization.jsonObject(with: connection) as? [String: Any] else {
            throw NSError(domain: "Pool", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pool setup must be a JSON object."])
        }
        for key in ["peer", "local_address", "user", "pairing_id"] {
            guard let value = record[key] as? String, !value.isEmpty else {
                throw NSError(domain: "Pool", code: 2, userInfo: [NSLocalizedDescriptionKey: "Paired connection is missing \(key)."])
            }
            config[key] = value
        }
        for key in ["ssh_port", "rpc_port"] {
            guard let value = record[key] as? Int else {
                throw NSError(domain: "Pool", code: 3, userInfo: [NSLocalizedDescriptionKey: "Paired connection is missing \(key)."])
            }
            config[key] = value
        }
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
