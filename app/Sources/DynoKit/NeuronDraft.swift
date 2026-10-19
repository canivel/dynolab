import Foundation

/// The Neurons forms' settings, and the Lab job configuration they make. `configuration()` checks only what the form
/// itself can get wrong; the Lab service validates the rest and its message is shown as is.
public struct NeuronDraft: Equatable, Sendable {
    public static let operations = ["capture", "atlas", "sae_train", "ablate", "units", "autointerp"]
    public static let hooks = ["mlp_hidden", "mlp_gate_pre", "mlp_up", "mlp_output", "attn_output", "block_output"]
    public static let corpusPresets = ["web-mix", "fineweb-edu"]
    public static func name(_ operation: String) -> String {
        ["capture": "Capture", "atlas": "Atlas", "sae_train": "SAE", "ablate": "Ablation", "units": "Units", "autointerp": "Auto-interp"][operation] ?? operation
    }

    public var operation = "capture"
    public var model = ""
    public var hook = "mlp_hidden"
    public var layers = "14"
    /// A preset name, or "files" for `corpusFiles`.
    public var corpus = "web-mix"
    public var corpusFiles: [String] = []
    public var tokens = "2,000,000"
    public var context = "1024"
    // capture
    public var allNeurons = true
    public var neuronCount = "512"
    public var randomDirections = "50"
    public var store = "reservoir"
    public var resumeFrom = ""
    // atlas
    public var capture = ""
    // sae_train
    public var saeTokens = "20,000,000"
    public var architecture = "topk"
    public var expansion = "4"
    public var k = "32"
    public var seeds = "0"
    // ablate
    public var allLayers = true
    public var calibrationTokens = "50,000"
    public var evalTokens = "100,000"
    // units
    public var mode = "attribute"
    public var prompts = "The Eiffel Tower is in the city of\nThe capital of France is"
    public var targetToken = " Paris"
    public var top = "40"
    public var unitSet = ""
    public var controlSeeds = "10"
    public var steerUnit = ""
    public var strengths = "-2, -1, 0, 1, 2, 4"
    public var scale = "maximum"
    public var maxTokens = "48"
    // autointerp
    public var atlas = ""
    public var atlasLayer: Int?
    public var neuronUnits = "100"
    public var randomUnits = "20"
    public var explainerPort: Int?
    public var scorerPort: Int?
    public var poles = "both"
    public var examples = "20"
    public var window = "32"
    public var stratified = true
    public var detection = "10"
    public var fuzzing = "10"
    public var threshold = "0.75"
    public var compareTo = ""

    public init() {}

    public struct Problem: Error, LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    private func count(_ text: String, _ field: String) throws -> Int {
        guard let value = NeuronForm.count(text) else { throw Problem("\(field): enter a whole number, like 2,000,000 or 2M.") }
        return value
    }
    private func corpusValue() throws -> Any {
        if corpus == "files" {
            guard !corpusFiles.isEmpty else { throw Problem("Corpus: choose one or more .txt or .jsonl files.") }
            return [["files": corpusFiles]]
        }
        return corpus
    }
    private func layerList() throws -> [Int] {
        guard let value = NeuronForm.layers(layers) else { throw Problem("Layers: enter layer numbers like 14 or 10, 14 or 10-13.") }
        return value
    }

    /// The job configuration, without `operation`'s model when the operation takes none.
    public func configuration() throws -> [String: Any] {
        var c: [String: Any] = ["operation": operation]
        let needsModel = !["autointerp"].contains(operation)
        if needsModel {
            guard !model.trimmingCharacters(in: .whitespaces).isEmpty else { throw Problem("Choose a model.") }
            c["model"] = model
        } else if !model.isEmpty { c["model"] = model }
        switch operation {
        case "capture":
            let list = try layerList()
            guard list.count <= 8 else { throw Problem("A capture records 1–8 layers.") }
            c["layers"] = list; c["hook"] = hook; c["corpus"] = try corpusValue()
            c["tokens"] = try count(tokens, "Tokens"); c["context"] = try count(context, "Context")
            var units: [String: Any] = ["neurons": allNeurons ? "all" as Any : try count(neuronCount, "Neurons") as Any]
            units["random_directions"] = try count(randomDirections, "Random directions")
            c["units"] = units; c["store"] = store
            if !resumeFrom.isEmpty { c["resume_from"] = resumeFrom }
        case "atlas":
            guard !capture.isEmpty else { throw Problem("Choose a finished capture.") }
            c["capture"] = capture
        case "sae_train":
            let list = try layerList()
            guard list.count == 1 else { throw Problem("An SAE is trained on one layer.") }
            c["layers"] = list; c["hook"] = hook; c["corpus"] = try corpusValue()
            c["tokens"] = try count(saeTokens, "Tokens"); c["context"] = try count(context, "Context")
            c["architecture"] = architecture; c["expansion"] = try count(expansion, "Expansion"); c["k"] = try count(k, "k")
            guard let seedList = NeuronForm.numbers(seeds), seedList.allSatisfy({ $0.rounded() == $0 }) else { throw Problem("Seeds: whole numbers, like 0 or 0, 1, 2.") }
            c["seeds"] = seedList.map { Int($0) }
        case "ablate":
            c["layers"] = allLayers ? "all" as Any : try layerList() as Any
            c["hook"] = hook; c["corpus"] = try corpusValue(); c["context"] = try count(context, "Context")
            c["calibration_tokens"] = try count(calibrationTokens, "Calibration tokens"); c["eval_tokens"] = try count(evalTokens, "Evaluation tokens")
        case "units":
            c["mode"] = mode; c["hook"] = hook
            let list = NeuronForm.prompts(prompts)
            guard !list.isEmpty else { throw Problem("Enter at least one prompt, one per line.") }
            c["prompts"] = list
            switch mode {
            case "attribute":
                guard !targetToken.isEmpty else { throw Problem("Enter a target token. Include a leading space if the token has one.") }
                c["target_token"] = targetToken; c["top"] = try count(top, "Top units")
                c["layers"] = allLayers ? "all" as Any : try layerList() as Any
            case "ablate_set":
                guard !targetToken.isEmpty else { throw Problem("Enter a target token. Include a leading space if the token has one.") }
                guard let units = NeuronForm.units(unitSet) else { throw Problem("Units: layer:unit pairs, like 27:81, 22:2246.") }
                c["target_token"] = targetToken; c["units"] = units; c["control_seeds"] = try count(controlSeeds, "Control seeds")
            default:
                guard let unit = NeuronForm.units(steerUnit), unit.count == 1 else { throw Problem("Unit: one layer:unit pair, like 27:81.") }
                guard let values = NeuronForm.numbers(strengths) else { throw Problem("Strengths: numbers, like -2, 0, 2.") }
                c["unit"] = unit[0]; c["strengths"] = values.map { $0.rounded() == $0 ? Int($0) as Any : $0 as Any }
                c["scale"] = scale; c["max_tokens"] = try count(maxTokens, "Max tokens")
            }
        case "autointerp":
            guard !atlas.isEmpty else { throw Problem("Choose a finished atlas.") }
            guard let explainerPort, let scorerPort else { throw Problem("Choose running model servers for the explainer and the scorer.") }
            c["atlas"] = atlas
            if let atlasLayer { c["layer"] = atlasLayer }
            c["units"] = ["neuron": try count(neuronUnits, "Neurons"), "random": try count(randomUnits, "Random directions")]
            c["explainer"] = ["port": explainerPort]; c["scorer"] = ["port": scorerPort]
            c["poles"] = poles; c["examples"] = try count(examples, "Examples"); c["window"] = try count(window, "Window")
            c["stratified"] = stratified; c["detection"] = try count(detection, "Detection texts"); c["fuzzing"] = try count(fuzzing, "Fuzzing texts")
            guard let t = Double(threshold), t > 0, t <= 1 else { throw Problem("Threshold: a number between 0 and 1.") }
            c["threshold"] = t
            if !compareTo.isEmpty { c["compare_to"] = compareTo }
        default: throw Problem("Unknown operation \(operation).")
        }
        return c
    }
}
