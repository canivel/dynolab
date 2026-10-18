import XCTest
@testable import DynoKit

final class NeuronAtlasTests: XCTestCase {
    private let index = """
    {"layer": 14, "hook": "mlp_hidden", "tokens": 189978, "units": [
      {"unit": 0, "kind": "neuron", "index": 0,
       "positive": {"maximum": 8.125, "per_100_tokens": {"10%": 20.05, "25%": 3.97, "50%": 0.12}, "preview": [" included", " <"]},
       "negative": {"maximum": 6.09, "per_100_tokens": {"10%": 40.3, "25%": 17.0, "50%": 1.97}, "preview": [" meters"]}},
      {"unit": 3072, "kind": "random", "index": 0,
       "positive": {"maximum": 2.0, "per_100_tokens": {"10%": 1, "25%": null, "50%": 0}, "preview": []},
       "negative": {"maximum": 0, "per_100_tokens": {}, "preview": []}}
    ]}
    """
    private let page = """
    {"unit": 0, "kind": "neuron", "index": 0, "edges": [0.01, 0.0316, 0.1, 0.316, 1, 3.16, 10, 31.6, 100, 316, 1000],
     "poles": {
       "positive": {"maximum": 8.0, "histogram": [1,2,3,4,5,6,7,8,9,10,11,12], "per_100_tokens": {"10%": 20, "25%": 4, "50%": 0.1},
         "top": [{"value": 8.0, "fraction": 1.0, "ids": [323, 311, 999], "activations": [4.0, -3.0, 8.0], "center": 2, "context": 453, "position": 126}],
         "stratified": [{"decile": 4, "range": [0.4, 0.5], "examples": []}, {"decile": 5, "range": [0.5, 0.6], "examples": []}],
         "heldout_top": []},
       "negative": {"maximum": 6.0, "histogram": [], "per_100_tokens": {"10%": 40, "25%": 17, "50%": 2},
         "top": [{"value": -6.0, "fraction": 1.0, "ids": [323], "activations": [-6.0], "center": 0}], "stratified": [], "heldout_top": []}},
     "random": [], "heldout_random": [], "mean": -0.29, "std": 1.34}
    """

    func testIndexDecodesRatesAndSearches() throws {
        let atlas = try AtlasIndex.read(Data(index.utf8))
        XCTAssertEqual(atlas.units.count, 2)
        XCTAssertEqual(atlas.units[0].positive.rates.above25, 3.97)
        XCTAssertNil(atlas.units[1].positive.rates.above25)
        XCTAssertNil(atlas.units[1].negative.rates.above10)
        XCTAssertEqual(atlas.kinds, ["neuron", "random"])
        XCTAssertEqual(atlas.filtered(query: "random 0", kind: nil).map(\.unit), [3072])
        XCTAssertEqual(atlas.filtered(query: "3072", kind: nil).map(\.unit), [3072])
        XCTAssertEqual(atlas.filtered(query: "meters", kind: nil).map(\.unit), [0])
        XCTAssertEqual(atlas.filtered(query: "", kind: "neuron").map(\.unit), [0])
        XCTAssertEqual(atlas.unit(kind: "neuron", index: 0)?.unit, 0)
        XCTAssertNil(atlas.unit(kind: "neuron", index: 5))
    }

    func testVocabMapsIdsAndMarksUnknown() throws {
        let vocab = try AtlasVocab.read(Data(#"{"323": " and", "311": " to", "198": "\n"}"#.utf8))
        XCTAssertEqual(vocab.text(323), " and")
        XCTAssertEqual(vocab.text(42), "⟨42⟩")
    }

    func testPageKeepsPolesApartAndHighlightsBySign() throws {
        let unit = try UnitPage.read(Data(page.utf8))
        XCTAssertEqual(unit.positiveMaximum, 8)
        XCTAssertEqual(unit.negativeMaximum, 6)
        XCTAssertEqual(unit.pole(.positive)?.strata.map(\.decile), [5, 4])
        XCTAssertEqual(unit.pole(.positive)?.strata.first?.title, "50–60% of max")
        XCTAssertEqual(unit.binLabels.count, 12)
        XCTAssertEqual(unit.binLabels.first, "<0.01")
        XCTAssertEqual(unit.binLabels.last, "≥1000")
        let vocab = AtlasVocab(tokens: [323: " and", 311: "\n"])
        let tokens = TokenHighlight.make(unit.pole(.positive)!.top[0], vocab: vocab, positiveMaximum: unit.positiveMaximum, negativeMaximum: unit.negativeMaximum)
        XCTAssertEqual(tokens.map(\.pole), [.positive, .negative, .positive])
        XCTAssertEqual(tokens.map(\.intensity), [0.5, 0.5, 1.0])
        XCTAssertEqual(tokens.map(\.isCenter), [false, false, true])
        XCTAssertEqual(tokens[1].display, "↵")
        XCTAssertEqual(tokens[2].text, "⟨999⟩")
    }

    func testHighlightClampsAndHandlesSilentPole() {
        let example = ActivationExample(value: 1, fraction: 1, ids: [1, 2, 3], activations: [12, -1, 0], center: 0)
        let tokens = TokenHighlight.make(example, vocab: AtlasVocab(tokens: [:]), positiveMaximum: 8, negativeMaximum: 0)
        XCTAssertEqual(tokens[0].intensity, 1)
        XCTAssertEqual(tokens[1].intensity, 0)
        XCTAssertNil(tokens[2].pole)
    }

    func testProgressAndEta() {
        let progress = LabJobProgress(["message": "Captured 10,000 tokens", "fraction": 0.25, "eta_seconds": 5400.0])
        XCTAssertEqual(progress?.fraction, 0.25)
        XCTAssertEqual(progress?.eta, "About 1 h 30 min left")
        XCTAssertEqual(LabJobProgress(message: "", etaSeconds: 30).eta, "Less than a minute left")
        XCTAssertEqual(LabJobProgress(message: "", etaSeconds: 600).eta, "About 10 min left")
        XCTAssertNil(LabJobProgress(["message": "Loading", "fraction": NSNull(), "eta_seconds": NSNull()])?.eta)
        XCTAssertNil(LabJobProgress(nil))
    }

    func testFormParsers() {
        XCTAssertEqual(NeuronForm.layers("14"), [14])
        XCTAssertEqual(NeuronForm.layers("10-12, 14 10"), [10, 11, 12, 14])
        XCTAssertNil(NeuronForm.layers("a"))
        XCTAssertNil(NeuronForm.layers("300"))
        XCTAssertEqual(NeuronForm.units("27:81, 22:2246\nL4 7"), [[27, 81], [22, 2246], [4, 7]])
        XCTAssertNil(NeuronForm.units("27"))
        XCTAssertEqual(NeuronForm.numbers("-2, 0 1.5"), [-2, 0, 1.5])
        XCTAssertNil(NeuronForm.numbers("1, x"))
        XCTAssertEqual(NeuronForm.count("2,000,000"), 2_000_000)
        XCTAssertEqual(NeuronForm.count("2M"), 2_000_000)
        XCTAssertEqual(NeuronForm.count("500k"), 500_000)
        XCTAssertNil(NeuronForm.count("lots"))
        XCTAssertEqual(NeuronForm.prompts("a\n\n b \n"), ["a", " b "])
    }
}

final class NeuronDraftTests: XCTestCase {
    func testCaptureConfiguration() throws {
        var draft = NeuronDraft()
        XCTAssertThrowsError(try draft.configuration())
        draft.model = "/models/Qwen3-0.6B"; draft.layers = "14, 20"; draft.tokens = "200k"
        let c = try draft.configuration()
        XCTAssertEqual(c["operation"] as? String, "capture")
        XCTAssertEqual(c["layers"] as? [Int], [14, 20])
        XCTAssertEqual(c["tokens"] as? Int, 200_000)
        XCTAssertEqual(c["corpus"] as? String, "web-mix")
        XCTAssertEqual((c["units"] as? [String: Any])?["neurons"] as? String, "all")
        XCTAssertEqual((c["units"] as? [String: Any])?["random_directions"] as? Int, 50)
        XCTAssertNil(c["resume_from"])
        draft.layers = "0-8"
        XCTAssertThrowsError(try draft.configuration())
        draft.layers = "3"; draft.corpus = "files"
        XCTAssertThrowsError(try draft.configuration())
        draft.corpusFiles = ["/tmp/a.txt"]
        XCTAssertEqual((try draft.configuration()["corpus"] as? [[String: [String]]])?.first?["files"], ["/tmp/a.txt"])
    }

    func testOtherOperations() throws {
        var draft = NeuronDraft(); draft.model = "m"
        draft.operation = "sae_train"; draft.layers = "14, 15"
        XCTAssertThrowsError(try draft.configuration())
        draft.layers = "14"; draft.seeds = "0, 1"
        XCTAssertEqual(try draft.configuration()["seeds"] as? [Int], [0, 1])

        draft.operation = "ablate"
        XCTAssertEqual(try draft.configuration()["layers"] as? String, "all")
        XCTAssertNil(try draft.configuration()["conditions"])

        draft.operation = "units"; draft.mode = "ablate_set"; draft.unitSet = "27:81, 22:2246"
        XCTAssertEqual(try draft.configuration()["units"] as? [[Int]], [[27, 81], [22, 2246]])
        draft.mode = "steer"; draft.steerUnit = "27:81"; draft.strengths = "0, 2, 1.5"
        let steer = try draft.configuration()
        XCTAssertEqual(steer["unit"] as? [Int], [27, 81])
        XCTAssertEqual((steer["strengths"] as? [Any])?.count, 3)
        XCTAssertEqual((steer["strengths"] as? [Any])?.first as? Int, 0)

        draft.operation = "autointerp"; draft.model = ""
        XCTAssertThrowsError(try draft.configuration())
        draft.atlas = String(repeating: "a", count: 32); draft.explainerPort = 8083; draft.scorerPort = 8084; draft.atlasLayer = 14
        let auto = try draft.configuration()
        XCTAssertNil(auto["model"])
        XCTAssertEqual((auto["scorer"] as? [String: Int])?["port"], 8084)
        XCTAssertEqual(auto["layer"] as? Int, 14)
        XCTAssertEqual(auto["threshold"] as? Double, 0.75)
        draft.threshold = "2"
        XCTAssertThrowsError(try draft.configuration())
    }
}

final class NeuronResultsTests: XCTestCase {
    private func json(_ text: String) -> Any { try! JSONSerialization.jsonObject(with: Data(text.utf8)) }

    func testAblationWithMissingIntervals() {
        let value = json("""
        {"conditions": [{"name": "weak-75", "kind": "below", "percentile": 75, "of": null,
          "top1_changed": {"mean": 0.47, "low": 0.45, "high": 0.48}, "kl": {"mean": 1.04, "low": null, "high": null},
          "ce_delta": {"mean": 0.93, "low": 0.87, "high": 0.98}, "removed_entries": 0.75, "removed_mass": 0.37},
          {"name": "weak-75 random (mass-matched)", "kind": "random_mass", "percentile": null, "of": "weak-75",
          "top1_changed": {"mean": 0.74, "low": 0.72, "high": 0.76}, "kl": {"mean": 3.1}, "ce_delta": {"mean": 2.9},
          "removed_entries": 0.37, "removed_mass": 0.37}], "layers": [0, 1], "heldout_tokens": 20124, "clean_ce": 3.11}
        """)
        let result = NeuronResults.decode(AblationResult.self, from: value)
        XCTAssertEqual(result?.conditions.count, 2)
        XCTAssertEqual(result?.conditions[0].kl?.text, "1.040")
        XCTAssertEqual(result?.conditions[0].top1Changed?.text(digits: 1, percent: true), "47.0% [45.0%, 48.0%]")
        XCTAssertEqual(result?.conditions[1].isControl, true)
        XCTAssertEqual(result?.cleanCE, 3.11)
    }

    func testSAEAlignmentWithDeadFeatures() throws {
        let data = Data("""
        {"summary": {"live_features": 1, "candidate_new_building_blocks": 1, "candidate_share": 1.0, "median_best_correlation": 0.4,
          "median_r2_5": 0.2, "best_correlation_histogram": [1], "r2_5_histogram": [1], "decoder_share_top1_histogram": [1],
          "thresholds": {"correlation": 0.5, "r2_5": 0.5}},
         "features": [{"feature": 0, "live": true, "best_neuron": 20, "best_correlation": -0.94, "r2_1": 0.88, "r2_5": 0.89,
           "top_neurons": [{"neuron": 20, "correlation": -0.94}], "decoder_share_top1": 0.04, "decoder_share_top5": 0.07,
           "candidate_new_building_block": false},
          {"feature": 4, "live": false}],
         "neurons": []}
        """.utf8)
        let alignment = try SAEAlignment.read(data)
        XCTAssertEqual(alignment.features.count, 2)
        XCTAssertEqual(alignment.features[0].bestCorrelationKey, 0.94)
        XCTAssertEqual(alignment.features[1].r25Key, -1)
        XCTAssertNil(alignment.features[1].bestNeuron)
        XCTAssertEqual(alignment.summary?.thresholds?["r2_5"], 0.5)
        let sorted = alignment.features.sorted(using: KeyPathComparator(\SAEFeatureAlignment.bestCorrelationKey, order: .reverse))
        XCTAssertEqual(sorted.map(\.feature), [0, 4])
    }

    func testUnitsResults() {
        let set = NeuronResults.decode(AblateSetResult.self, from: json("""
        {"target_token": " Paris", "units": [[27, 81]], "baseline_probability": 0.78, "ablated_probability": 0.10,
         "random_control_probability": 0.77, "control_seeds": 10,
         "prompts": [{"prompt": "The capital of France is", "baseline": {"probability": 0.65, "top": [{"token": " Paris", "probability": 0.65}]},
           "ablated": {"probability": 0.0058, "top": []}, "random_control": {"mean": 0.66, "low": 0.64, "high": 0.69, "values": [0.65]}}]}
        """))
        XCTAssertEqual(set?.prompts.first?.randomControl?.high, 0.69)
        let steer = NeuronResults.decode(SteerResult.self, from: json("""
        {"layer": 27, "unit": 81, "scale": "maximum", "maximum": 181.0,
         "outputs": [{"prompt": "My favorite place", "strength": 0, "added": 0.0, "text": " the beach."}]}
        """))
        XCTAssertEqual(steer?.outputs.first?.strength, 0)
        let attribution = NeuronResults.decode(AttributionResult.self, from: json("""
        {"target_token": " Paris", "prompts": [{"prompt": "p", "target_probability": 0.9}],
         "units": [{"layer": 27, "unit": 1330, "attribution": -1.39, "direction": "against"}], "total_positive": 157.3, "total_negative": -152.5}
        """))
        XCTAssertEqual(attribution?.units.first?.unit, 1330)
    }

    func testAutointerpSummaryAndRows() throws {
        let summary = NeuronResults.decode(AutointerpResult.self, from: json("""
        {"atlas": "abc", "layer": 14, "settings": {"poles": "both", "stratified": true, "threshold": 0.75},
         "summary": {"random": {"detection": {"poles": 2, "pass_rate": 0.5, "mean": 0.65, "median": 0.65, "histogram": [0,0,0,0,0,1,1,0,0,0]},
                                "fuzzing": null, "shuffled_labels": null, "by_pole": {"positive": null}},
                     "neuron": {"detection": {"poles": 6, "pass_rate": 0.17, "mean": 0.65, "median": 0.65, "histogram": [0,0,0,0,0,3,2,1,0,0]},
                                "fuzzing": null, "shuffled_labels": {"poles": 6, "pass_rate": 0, "mean": 0.47, "median": 0.5, "histogram": [0,0,0,0,6,0,0,0,0,0]},
                                "by_pole": {"positive": {"poles": 3, "pass_rate": 0, "mean": 0.67, "median": 0.7, "histogram": [0,0,0,0,0,0,3,0,0,0]}}}},
         "poles": 8, "errors": 0,
         "paired_with": {"job": "def", "neuron": {"poles": 6, "mean_difference": 0.05, "this_pass_rate": 0.2, "other_pass_rate": 0.1, "p_value": 0.4}}}
        """))
        XCTAssertEqual(summary?.kinds, ["neuron", "random"])
        XCTAssertEqual(summary?.threshold, 0.75)
        XCTAssertEqual(summary?.settings?["stratified"]?.description, "yes")
        XCTAssertNil(summary?.summary["random"]?.fuzzing)
        XCTAssertEqual(summary?.pairedWith?.neuron?.pValue, 0.4)
        let report = try AutointerpReport.read(Data("""
        {"rows": [{"layer": 14, "unit": 165, "kind": "neuron", "index": 165, "pole": "negative", "maximum": 3.9, "label": "first syllables",
           "detection": {"balanced_accuracy": 0.5, "shown": 10}, "shuffled_detection": {"balanced_accuracy": null, "shown": 10}},
          {"layer": 14, "unit": 165, "kind": "neuron", "index": 165, "pole": "positive", "skipped": "This pole never fires"}], "settings": {}}
        """.utf8))
        let labels = report.labels(layer: 14, unit: 165)
        XCTAssertEqual(labels[.negative]?.label, "first syllables")
        XCTAssertEqual(labels[.positive]?.status, "This pole never fires")
        XCTAssertEqual(labels[.positive]?.detectionKey, -1)
        XCTAssertTrue(report.labels(layer: 13, unit: 165).isEmpty)
    }
}
