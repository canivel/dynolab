import Foundation

/// The two sides of a unit. A unit's positive and negative activations are read separately and never merged.
public enum NeuronPole: String, CaseIterable, Codable, Sendable, Identifiable {
    case positive, negative
    public var id: String { rawValue }
    public var title: String { self == .positive ? "Positive" : "Negative" }
}

/// How often a pole reaches 10%, 25% and 50% of its maximum, per 100 tokens.
public struct NeuronRates: Codable, Hashable, Sendable {
    public var above10: Double?
    public var above25: Double?
    public var above50: Double?
    enum CodingKeys: String, CodingKey { case above10 = "10%", above25 = "25%", above50 = "50%" }
    public init(above10: Double? = nil, above25: Double? = nil, above50: Double? = nil) {
        self.above10 = above10; self.above25 = above25; self.above50 = above50
    }
    /// (label, rate) in increasing level order.
    public var levels: [(String, Double?)] { [("10%", above10), ("25%", above25), ("50%", above50)] }
}

/// One row of an atlas layer index: `index-L{layer}.json`.
public struct AtlasUnitSummary: Codable, Identifiable, Hashable, Sendable {
    public struct Pole: Codable, Hashable, Sendable {
        public var maximum: Double
        public var rates: NeuronRates
        public var preview: [String]
        enum CodingKeys: String, CodingKey { case maximum, rates = "per_100_tokens", preview }
        public init(maximum: Double, rates: NeuronRates = NeuronRates(), preview: [String] = []) {
            self.maximum = maximum; self.rates = rates; self.preview = preview
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            maximum = try c.decodeIfPresent(Double.self, forKey: .maximum) ?? 0
            rates = try c.decodeIfPresent(NeuronRates.self, forKey: .rates) ?? NeuronRates()
            preview = try c.decodeIfPresent([String].self, forKey: .preview) ?? []
        }
    }
    public var unit: Int
    public var kind: String
    public var index: Int
    public var positive: Pole
    public var negative: Pole
    public var id: Int { unit }
    public init(unit: Int, kind: String, index: Int, positive: Pole, negative: Pole) {
        self.unit = unit; self.kind = kind; self.index = index; self.positive = positive; self.negative = negative
    }
    public func pole(_ pole: NeuronPole) -> Pole { pole == .positive ? positive : negative }

    // Non-optional keys for sortable tables.
    public var positiveMaximum: Double { positive.maximum }
    public var negativeMaximum: Double { negative.maximum }
    public var positiveRate10: Double { positive.rates.above10 ?? 0 }
    public var positiveRate25: Double { positive.rates.above25 ?? 0 }
    public var positiveRate50: Double { positive.rates.above50 ?? 0 }
    public var negativeRate10: Double { negative.rates.above10 ?? 0 }
    public var negativeRate25: Double { negative.rates.above25 ?? 0 }
    public var negativeRate50: Double { negative.rates.above50 ?? 0 }

    /// A search matches the unit id, "kind index" (e.g. "neuron 20", "random 3"), the kind alone, or a preview token.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return true }
        if let number = Int(q.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) { return unit == number || index == number }
        let parts = q.split(separator: " ")
        if parts.count == 2, let number = Int(parts[1]), kind.hasPrefix(String(parts[0])) { return index == number }
        if kind.hasPrefix(q) { return true }
        return (positive.preview + negative.preview).contains { $0.lowercased().contains(q) }
    }
}

public struct AtlasIndex: Codable, Sendable {
    public var layer: Int
    public var hook: String
    public var tokens: Int
    public var units: [AtlasUnitSummary]
    public init(layer: Int, hook: String, tokens: Int, units: [AtlasUnitSummary]) {
        self.layer = layer; self.hook = hook; self.tokens = tokens; self.units = units
    }
    public static func read(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
    public var kinds: [String] { Array(Set(units.map(\.kind))).sorted { Self.kindOrder($0) < Self.kindOrder($1) } }
    static func kindOrder(_ kind: String) -> Int { ["neuron": 0, "sae": 1, "random": 2][kind] ?? 3 }
    /// The atlas unit that holds a neuron (or other kind) index.
    public func unit(kind: String, index: Int) -> AtlasUnitSummary? { units.first { $0.kind == kind && $0.index == index } }
    public func filtered(query: String, kind: String?) -> [AtlasUnitSummary] {
        units.filter { (kind == nil || $0.kind == kind) && $0.matches(query) }
    }
}

/// Token id to text, from `vocab-L{layer}.json` (`{"<id>": "text"}`).
public struct AtlasVocab: Sendable {
    public var tokens: [Int: String]
    public init(tokens: [Int: String]) { self.tokens = tokens }
    public static func read(_ data: Data) throws -> Self {
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        var tokens: [Int: String] = [:]
        tokens.reserveCapacity(raw.count)
        for (key, value) in raw { if let id = Int(key) { tokens[id] = value } }
        return Self(tokens: tokens)
    }
    public func text(_ id: Int) -> String { tokens[id] ?? "⟨\(id)⟩" }
}

/// A window of tokens around one activation.
public struct ActivationExample: Codable, Hashable, Sendable {
    public var value: Double
    public var fraction: Double
    public var ids: [Int]
    public var activations: [Double]
    public var center: Int
    public var context: Int?
    public var position: Int?
    public init(value: Double, fraction: Double, ids: [Int], activations: [Double], center: Int, context: Int? = nil, position: Int? = nil) {
        self.value = value; self.fraction = fraction; self.ids = ids; self.activations = activations
        self.center = center; self.context = context; self.position = position
    }
}

public struct StratifiedSample: Codable, Hashable, Sendable {
    public var decile: Int
    public var range: [Double]
    public var examples: [ActivationExample]
    /// "40–50% of max"
    public var title: String {
        guard range.count == 2 else { return "Decile \(decile)" }
        return "\(Int((range[0] * 100).rounded()))–\(Int((range[1] * 100).rounded()))% of max"
    }
}

/// One unit's page: `L{layer}/{unit}.json.gz`.
public struct UnitPage: Codable, Sendable {
    public struct Pole: Codable, Sendable {
        public var maximum: Double
        public var rates: NeuronRates
        public var histogram: [Int]
        public var top: [ActivationExample]
        public var stratified: [StratifiedSample]
        public var heldoutTop: [ActivationExample]
        enum CodingKeys: String, CodingKey { case maximum, rates = "per_100_tokens", histogram, top, stratified, heldoutTop = "heldout_top" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            maximum = try c.decodeIfPresent(Double.self, forKey: .maximum) ?? 0
            rates = try c.decodeIfPresent(NeuronRates.self, forKey: .rates) ?? NeuronRates()
            histogram = try c.decodeIfPresent([Int].self, forKey: .histogram) ?? []
            top = try c.decodeIfPresent([ActivationExample].self, forKey: .top) ?? []
            stratified = try c.decodeIfPresent([StratifiedSample].self, forKey: .stratified) ?? []
            heldoutTop = try c.decodeIfPresent([ActivationExample].self, forKey: .heldoutTop) ?? []
        }
        /// Stratified samples from the strongest decile down.
        public var strata: [StratifiedSample] { stratified.sorted { $0.decile > $1.decile } }
    }
    public var unit: Int
    public var kind: String
    public var index: Int
    public var edges: [Double]
    public var poles: [String: Pole]
    public var random: [ActivationExample]
    public var heldoutRandom: [ActivationExample]
    public var mean: Double?
    public var std: Double?
    enum CodingKeys: String, CodingKey { case unit, kind, index, edges, poles, random, heldoutRandom = "heldout_random", mean, std }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decode(Int.self, forKey: .unit)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "neuron"
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? unit
        edges = try c.decodeIfPresent([Double].self, forKey: .edges) ?? []
        poles = try c.decodeIfPresent([String: Pole].self, forKey: .poles) ?? [:]
        random = try c.decodeIfPresent([ActivationExample].self, forKey: .random) ?? []
        heldoutRandom = try c.decodeIfPresent([ActivationExample].self, forKey: .heldoutRandom) ?? []
        mean = try c.decodeIfPresent(Double.self, forKey: .mean)
        std = try c.decodeIfPresent(Double.self, forKey: .std)
    }
    public static func read(_ data: Data) throws -> Self { try JSONDecoder().decode(Self.self, from: data) }
    public func pole(_ pole: NeuronPole) -> Pole? { poles[pole.rawValue] }
    public var positiveMaximum: Double { pole(.positive)?.maximum ?? 0 }
    public var negativeMaximum: Double { pole(.negative)?.maximum ?? 0 }

    /// Labels for histogram bins: bin 0 is below the first edge, the last is at or above the last edge.
    public var binLabels: [String] {
        guard !edges.isEmpty else { return [] }
        func f(_ v: Double) -> String { v >= 10 ? String(format: "%.0f", v) : v >= 1 ? String(format: "%.1f", v) : String(format: "%.2g", v) }
        var out = ["<\(f(edges[0]))"]
        for i in 1..<edges.count { out.append("\(f(edges[i - 1]))–\(f(edges[i]))") }
        out.append("≥\(f(edges[edges.count - 1]))")
        return out
    }
}

/// One token of an example, ready to draw: text, its activation, and how strongly to shade it.
public struct TokenHighlight: Hashable, Sendable {
    public var text: String
    public var activation: Double
    /// The sign of the activation, or nil when it is zero.
    public var pole: NeuronPole?
    /// |activation| over that pole's maximum, clamped to 0…1.
    public var intensity: Double
    public var isCenter: Bool

    /// Shading proportional to activation over the pole maximum of the activation's own sign, so positive and
    /// negative stay distinguishable inside one window.
    public static func make(_ example: ActivationExample, vocab: AtlasVocab, positiveMaximum: Double, negativeMaximum: Double) -> [TokenHighlight] {
        example.ids.indices.map { i in
            let a = i < example.activations.count ? example.activations[i] : 0
            let pole: NeuronPole? = a > 0 ? .positive : a < 0 ? .negative : nil
            let maximum = pole == .negative ? negativeMaximum : positiveMaximum
            let intensity = pole == nil || maximum <= 0 ? 0 : min(abs(a) / maximum, 1)
            return TokenHighlight(text: vocab.text(example.ids[i]), activation: a, pole: pole, intensity: intensity, isCenter: i == example.center)
        }
    }
    /// Whitespace made visible enough to see, without turning spaces into dots.
    public var display: String {
        text.replacingOccurrences(of: "\n", with: "↵").replacingOccurrences(of: "\t", with: "⇥")
    }
}

/// `progress` on a running Lab job.
public struct LabJobProgress: Equatable, Sendable {
    public var message: String
    public var fraction: Double?
    public var etaSeconds: Double?
    public init(message: String, fraction: Double? = nil, etaSeconds: Double? = nil) {
        self.message = message; self.fraction = fraction; self.etaSeconds = etaSeconds
    }
    public init?(_ value: Any?) {
        guard let value = value as? [String: Any] else { return nil }
        message = value["message"] as? String ?? ""
        fraction = (value["fraction"] as? NSNumber)?.doubleValue
        etaSeconds = (value["eta_seconds"] as? NSNumber)?.doubleValue
    }
    public var eta: String? {
        guard let s = etaSeconds, s.isFinite, s >= 0 else { return nil }
        if s < 60 { return "Less than a minute left" }
        if s < 3600 { return "About \(Int((s / 60).rounded())) min left" }
        let hours = Int(s / 3600), minutes = Int((s.truncatingRemainder(dividingBy: 3600) / 60).rounded())
        return minutes == 0 ? "About \(hours) h left" : "About \(hours) h \(minutes) min left"
    }
}

/// Small parsers for the Neurons forms. Each returns nil for input it can't read, so the form can say so.
public enum NeuronForm {
    /// "14", "4, 8, 12", "10-13" → unique layer indices in order.
    public static func layers(_ text: String) -> [Int]? {
        var out: [Int] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == " " }) where !piece.isEmpty {
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false)
            if bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]), low <= high, high - low < 256 {
                out += Array(low...high)
            } else if let value = Int(piece) { out.append(value) } else { return nil }
        }
        guard !out.isEmpty, out.allSatisfy({ $0 >= 0 && $0 < 256 }) else { return nil }
        var seen = Set<Int>()
        return out.filter { seen.insert($0).inserted }
    }
    /// "27:81, 22:2246" (or "27/81", "L27 81") → [[27, 81], [22, 2246]].
    public static func units(_ text: String) -> [[Int]]? {
        var out: [[Int]] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            let numbers = piece.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            if numbers.isEmpty { continue }
            guard numbers.count == 2 else { return nil }
            out.append(numbers)
        }
        return out.isEmpty ? nil : out
    }
    /// "-2, -1, 0, 1.5" → numbers.
    public static func numbers(_ text: String) -> [Double]? {
        let pieces = text.split(whereSeparator: { $0 == "," || $0 == " " }).filter { !$0.isEmpty }
        let values = pieces.compactMap { Double($0) }
        return values.isEmpty || values.count != pieces.count ? nil : values
    }
    /// "2,000,000", "2_000_000", "2M", "500k" → an integer.
    public static func count(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "_", with: "")
        var scale = 1.0
        if t.hasSuffix("k") { scale = 1e3; t.removeLast() } else if t.hasSuffix("m") { scale = 1e6; t.removeLast() } else if t.hasSuffix("b") { scale = 1e9; t.removeLast() }
        guard let value = Double(t), value >= 0, value * scale < 1e13 else { return nil }
        return Int((value * scale).rounded())
    }
    /// One prompt per nonempty line.
    public static func prompts(_ text: String) -> [String] {
        text.split(separator: "\n").map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
