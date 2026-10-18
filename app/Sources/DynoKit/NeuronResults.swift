import Foundation

/// Result shapes of the Lab's neuron operations, decoded from `result` of a finished job or its artifacts.
/// Every field the service can leave out or set to null is optional.
public enum NeuronResults {
    /// Decodes a value the Lab client already parsed with JSONSerialization.
    public static func decode<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// A mean with a 95% interval; the interval is null when there are too few contexts.
public struct NeuronInterval: Codable, Hashable, Sendable {
    public var mean: Double
    public var low: Double?
    public var high: Double?
    public init(mean: Double, low: Double? = nil, high: Double? = nil) { self.mean = mean; self.low = low; self.high = high }
    public var text: String { text(digits: 3) }
    public func text(digits: Int, percent: Bool = false) -> String {
        let scale = percent ? 100.0 : 1.0
        let f = { (v: Double) in String(format: "%.\(digits)f", v * scale) + (percent ? "%" : "") }
        guard let low, let high else { return f(mean) }
        return "\(f(mean)) [\(f(low)), \(f(high))]"
    }
}

// MARK: Capture

public struct CaptureResult: Codable, Sendable {
    public struct Layer: Codable, Sendable {
        public var units: Int?
        public var tokens: Int?
        public var heldoutTokens: Int?
        public var deadUnits: Int?
        enum CodingKeys: String, CodingKey { case units, tokens, heldoutTokens = "heldout_tokens", deadUnits = "dead_units" }
    }
    public var tokens: Int?
    public var contexts: Int?
    public var layers: [String: Layer]
    public var neurons: Int?
    public var randomDirections: Int?
    public var store: String?
    public var stopped: String?
    public var seconds: Double?
    enum CodingKeys: String, CodingKey { case tokens, contexts, layers, neurons, randomDirections = "random_directions", store, stopped, seconds }
    public var sortedLayers: [(Int, Layer)] { layers.compactMap { k, v in Int(k).map { ($0, v) } }.sorted { $0.0 < $1.0 } }
}

// MARK: SAE

public struct SAEAlignmentSummary: Codable, Sendable {
    public var liveFeatures: Int?
    public var candidateNewBuildingBlocks: Int?
    public var candidateShare: Double?
    public var medianBestCorrelation: Double?
    public var medianR25: Double?
    public var bestCorrelationHistogram: [Int]?
    public var r25Histogram: [Int]?
    public var decoderShareTop1Histogram: [Int]?
    public var thresholds: [String: Double]?
    enum CodingKeys: String, CodingKey {
        case liveFeatures = "live_features", candidateNewBuildingBlocks = "candidate_new_building_blocks", candidateShare = "candidate_share"
        case medianBestCorrelation = "median_best_correlation", medianR25 = "median_r2_5", bestCorrelationHistogram = "best_correlation_histogram"
        case r25Histogram = "r2_5_histogram", decoderShareTop1Histogram = "decoder_share_top1_histogram", thresholds
    }
}

public struct SAEReport: Codable, Sendable {
    public struct Step: Codable, Sendable {
        public var step: Int
        public var loss: Double
        public var l0: Double?
        public var deadFraction: Double?
        enum CodingKeys: String, CodingKey { case step, loss, l0, deadFraction = "dead_fraction" }
    }
    public var seed: Int?
    public var fvu: Double?
    public var l0: Double?
    public var deadOnHeldout: Double?
    public var ceLossRecovered: Double?
    public var ceClean: Double?
    public var ceSpliced: Double?
    public var ceZeroAblation: Double?
    public var width: Int?
    public var k: Int?
    public var architecture: String?
    public var losses: [Step]?
    public var alignment: SAEAlignmentSummary?
    enum CodingKeys: String, CodingKey {
        case seed, fvu, l0, deadOnHeldout = "dead_on_heldout", ceLossRecovered = "ce_loss_recovered", ceClean = "ce_clean"
        case ceSpliced = "ce_spliced", ceZeroAblation = "ce_zero_ablation", width, k, architecture, losses, alignment
    }
}

public struct SAEFeatureAlignment: Codable, Identifiable, Hashable, Sendable {
    public struct Neuron: Codable, Hashable, Sendable { public var neuron: Int; public var correlation: Double }
    public var feature: Int
    public var live: Bool
    public var bestNeuron: Int?
    public var bestCorrelation: Double?
    public var r21: Double?
    public var r25: Double?
    public var topNeurons: [Neuron]?
    public var decoderShareTop1: Double?
    public var decoderShareTop5: Double?
    public var candidate: Bool?
    public var id: Int { feature }
    enum CodingKeys: String, CodingKey {
        case feature, live, bestNeuron = "best_neuron", bestCorrelation = "best_correlation", r21 = "r2_1", r25 = "r2_5"
        case topNeurons = "top_neurons", decoderShareTop1 = "decoder_share_top1", decoderShareTop5 = "decoder_share_top5"
        case candidate = "candidate_new_building_block"
    }
    // Non-optional keys for sortable tables: missing values sort last when descending.
    public var bestCorrelationKey: Double { bestCorrelation.map(abs) ?? -1 }
    public var r21Key: Double { r21 ?? -1 }
    public var r25Key: Double { r25 ?? -1 }
    public var decoderShareKey: Double { decoderShareTop1 ?? -1 }
    public var candidateKey: Int { candidate == true ? 1 : 0 }
}

public struct SAEAlignment: Codable, Sendable {
    public var summary: SAEAlignmentSummary?
    public var features: [SAEFeatureAlignment]
    public static func read(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
}

// MARK: Ablation

public struct AblationCondition: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var kind: String
    public var percentile: Double?
    public var of: String?
    public var top1Changed: NeuronInterval?
    public var kl: NeuronInterval?
    public var ceDelta: NeuronInterval?
    public var removedEntries: Double?
    public var removedMass: Double?
    public var id: String { name }
    enum CodingKeys: String, CodingKey {
        case name, kind, percentile, of, top1Changed = "top1_changed", kl, ceDelta = "ce_delta", removedEntries = "removed_entries", removedMass = "removed_mass"
    }
    /// Random controls are matched to an earlier targeted condition.
    public var isControl: Bool { kind == "random_mass" || kind == "random_count" }
}

public struct AblationResult: Codable, Sendable {
    public var conditions: [AblationCondition]
    public var layers: [Int]?
    public var hook: String?
    public var heldoutTokens: Int?
    public var cleanCE: Double?
    enum CodingKeys: String, CodingKey { case conditions, layers, hook, heldoutTokens = "heldout_tokens", cleanCE = "clean_ce" }
}

// MARK: Units

public struct TokenProbability: Codable, Hashable, Sendable { public var token: String; public var probability: Double }

public struct AttributionResult: Codable, Sendable {
    public struct Unit: Codable, Hashable, Sendable {
        public var layer: Int
        public var unit: Int
        public var attribution: Double
        public var direction: String?
    }
    public struct Prompt: Codable, Hashable, Sendable {
        public var prompt: String
        public var targetProbability: Double?
        enum CodingKeys: String, CodingKey { case prompt, targetProbability = "target_probability" }
    }
    public var targetToken: String?
    public var prompts: [Prompt]?
    public var units: [Unit]
    public var totalPositive: Double?
    public var totalNegative: Double?
    enum CodingKeys: String, CodingKey { case targetToken = "target_token", prompts, units, totalPositive = "total_positive", totalNegative = "total_negative" }
}

public struct AblateSetResult: Codable, Sendable {
    public struct Outcome: Codable, Hashable, Sendable { public var probability: Double; public var top: [TokenProbability]? }
    public struct Prompt: Codable, Hashable, Sendable {
        public var prompt: String
        public var baseline: Outcome
        public var ablated: Outcome
        public var randomControl: NeuronInterval?
        enum CodingKeys: String, CodingKey { case prompt, baseline, ablated, randomControl = "random_control" }
    }
    public var targetToken: String?
    public var units: [[Int]]?
    public var baselineProbability: Double?
    public var ablatedProbability: Double?
    public var randomControlProbability: Double?
    public var controlSeeds: Int?
    public var prompts: [Prompt]
    enum CodingKeys: String, CodingKey {
        case targetToken = "target_token", units, baselineProbability = "baseline_probability", ablatedProbability = "ablated_probability"
        case randomControlProbability = "random_control_probability", controlSeeds = "control_seeds", prompts
    }
}

public struct SteerResult: Codable, Sendable {
    public struct Output: Codable, Hashable, Sendable {
        public var prompt: String?
        public var strength: Double
        public var added: Double?
        public var text: String
    }
    public var layer: Int?
    public var unit: Int?
    public var scale: String?
    public var maximum: Double?
    public var outputs: [Output]
}

// MARK: Auto-interp

public struct AutointerpScoreSummary: Codable, Hashable, Sendable {
    public var poles: Int
    public var passRate: Double
    public var mean: Double
    public var median: Double
    public var histogram: [Int]
    enum CodingKeys: String, CodingKey { case poles, passRate = "pass_rate", mean, median, histogram }
}

public struct AutointerpKindSummary: Codable, Sendable {
    public var detection: AutointerpScoreSummary?
    public var fuzzing: AutointerpScoreSummary?
    public var shuffledLabels: AutointerpScoreSummary?
    public var byPole: [String: AutointerpScoreSummary?]?
    enum CodingKeys: String, CodingKey { case detection, fuzzing, shuffledLabels = "shuffled_labels", byPole = "by_pole" }
}

public struct AutointerpResult: Codable, Sendable {
    public struct Paired: Codable, Sendable {
        public var poles: Int
        public var meanDifference: Double
        public var thisPassRate: Double
        public var otherPassRate: Double
        public var pValue: Double
        enum CodingKeys: String, CodingKey { case poles, meanDifference = "mean_difference", thisPassRate = "this_pass_rate", otherPassRate = "other_pass_rate", pValue = "p_value" }
    }
    public struct PairedWith: Codable, Sendable { public var job: String; public var neuron: Paired? }
    public struct NewBuildingBlocks: Codable, Sendable {
        public var scored: Int
        public var interpretable: Int
        public var newBuildingBlocks: Int
        public var shareOfInterpretable: Double
        public var features: [Int]?
        enum CodingKeys: String, CodingKey { case scored, interpretable, newBuildingBlocks = "new_building_blocks", shareOfInterpretable = "share_of_interpretable", features }
    }
    public var atlas: String?
    public var layer: Int?
    public var summary: [String: AutointerpKindSummary]
    public var poles: Int?
    public var errors: Int?
    public var settings: [String: AnyCodableScalar]?
    public var pairedWith: PairedWith?
    public var saeNewBuildingBlocks: NewBuildingBlocks?
    enum CodingKeys: String, CodingKey {
        case atlas, layer, summary, poles, errors, settings, pairedWith = "paired_with", saeNewBuildingBlocks = "sae_new_building_blocks"
    }
    public var threshold: Double? { settings?["threshold"]?.number }
    public var kinds: [String] { summary.keys.sorted { AtlasIndex.kindOrder($0) < AtlasIndex.kindOrder($1) } }
}

/// A scalar setting (number, text or flag), for showing a settings block as it was sent.
public enum AnyCodableScalar: Codable, Hashable, Sendable {
    case number(Double), text(String), flag(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .flag(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .text(s) }
        else { self = .null }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let d): try c.encode(d)
        case .text(let s): try c.encode(s)
        case .flag(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }
    public var number: Double? { if case .number(let d) = self { return d }; return nil }
    public var description: String {
        switch self {
        case .number(let d): return d.rounded() == d && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .text(let s): return s
        case .flag(let b): return b ? "yes" : "no"
        case .null: return "—"
        }
    }
}

/// One scored pole from `autointerp.json`.
public struct AutointerpRow: Codable, Identifiable, Hashable, Sendable {
    public struct Score: Codable, Hashable, Sendable {
        public var balancedAccuracy: Double?
        public var shown: Int?
        enum CodingKeys: String, CodingKey { case balancedAccuracy = "balanced_accuracy", shown }
    }
    public var layer: Int
    public var unit: Int
    public var kind: String
    public var index: Int
    public var pole: String
    public var maximum: Double?
    public var label: String?
    public var detection: Score?
    public var fuzzing: Score?
    public var shuffledDetection: Score?
    public var skipped: String?
    public var error: String?
    public var id: String { "\(layer)-\(unit)-\(pole)" }
    enum CodingKeys: String, CodingKey {
        case layer, unit, kind, index, pole, maximum, label, detection, fuzzing, shuffledDetection = "shuffled_detection", skipped, error
    }
    public var detectionKey: Double { detection?.balancedAccuracy ?? -1 }
    public var fuzzingKey: Double { fuzzing?.balancedAccuracy ?? -1 }
    public var status: String { error.map { "Error: \($0)" } ?? skipped ?? (label == nil ? "Not labeled" : "Scored") }
}

public struct AutointerpReport: Codable, Sendable {
    public var rows: [AutointerpRow]
    public static func read(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
    /// Rows for one unit of one layer, by pole.
    public func labels(layer: Int, unit: Int) -> [NeuronPole: AutointerpRow] {
        var out: [NeuronPole: AutointerpRow] = [:]
        for row in rows where row.layer == layer && row.unit == unit {
            if let pole = NeuronPole(rawValue: row.pole) { out[pole] = row }
        }
        return out
    }
}
