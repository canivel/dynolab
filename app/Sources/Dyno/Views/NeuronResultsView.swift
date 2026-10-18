import Charts
import DynoKit
import SwiftUI

/// The result of a finished neuron job other than an atlas (which opens in the browser).
struct NeuronResultView: View {
    var neurons: NeuronLab
    var job: [String: Any]
    var result: [String: Any]

    private var id: String { job["id"] as? String ?? "" }
    private var config: [String: Any] { job["config"] as? [String: Any] ?? [:] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let warnings = result["warnings"] as? [String], !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                }
            }
            switch job["operation"] as? String ?? "" {
            case "capture": CaptureResultView(neurons: neurons, id: id, result: result)
            case "atlas": ProgressView("Opening the atlas…").onAppear { neurons.openBrowserIfAtlas() }
            case "sae_train": SAEResultView(neurons: neurons, id: id, job: job, result: result)
            case "ablate": AblationResultView(neurons: neurons, result: result)
            case "units": UnitsResultView(neurons: neurons, job: job, result: result)
            case "autointerp": AutointerpResultView(neurons: neurons, id: id, result: result)
            default: EmptyView()
            }
            if let note = result["note"] as? String {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup("Provenance & artifacts") {
                Text(ResearchLab.pretty(result["provenance"] ?? [:]) + "\n" + ResearchLab.pretty(result["artifacts"] ?? []))
                    .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Text("Local artifacts: ~/.mlx-dyno/lab/\(id)/").font(.caption)
            }
        }
    }
}

// MARK: - Shared pieces

/// A small labelled number.
private struct Metric: View {
    var title: String
    var value: String
    var detail: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit())
            if let detail { Text(detail).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true) }
        }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Metrics in a row, all as tall as the tallest.
private struct MetricRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { HStack(spacing: 10) { content }.fixedSize(horizontal: false, vertical: true) }
}

/// Counts in equal bins over [0, 1].
private struct UnitHistogram: View {
    var title: String
    var counts: [Int]
    var color: Color
    var height: CGFloat = 110
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            let width = 1.0 / Double(max(counts.count, 1))
            Chart(counts.indices, id: \.self) { i in
                RectangleMark(xStart: .value("Low", Double(i) * width), xEnd: .value("High", Double(i + 1) * width),
                              yStart: .value("Zero", 0), yEnd: .value("Count", counts[i]))
                    .foregroundStyle(color.opacity(0.8))
            }
            .chartXScale(domain: 0...1)
            .chartXAxis { AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) }
            .frame(height: height)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func fmt(_ value: Double?, _ digits: Int = 3) -> String { value.map { String(format: "%.\(digits)f", $0) } ?? "—" }
private func percent(_ value: Double?, _ digits: Int = 1) -> String { value.map { String(format: "%.\(digits)f%%", $0 * 100) } ?? "—" }
private func shortModel(_ model: String) -> String { model.split(separator: "/").last.map(String.init) ?? model }

// MARK: - Capture

private struct CaptureResultView: View {
    var neurons: NeuronLab
    var id: String
    var result: [String: Any]
    var body: some View {
        if let capture = NeuronResults.decode(CaptureResult.self, from: result["capture"]) {
            VStack(alignment: .leading, spacing: 14) {
                MetricRow {
                    Metric(title: "Tokens", value: (capture.tokens ?? 0).formatted(), detail: capture.contexts.map { "\($0.formatted()) document windows" })
                    Metric(title: "Neurons", value: (capture.neurons ?? 0).formatted())
                    Metric(title: "Random directions", value: (capture.randomDirections ?? 0).formatted(), detail: "Baseline units")
                    Metric(title: "Time", value: capture.seconds.map { Duration.seconds($0).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)) } ?? "—")
                }
                Text("Layers").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow { Text("Layer"); Text("Units"); Text("Training tokens"); Text("Held-out tokens"); Text("Dead units") }
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(capture.sortedLayers, id: \.0) { layer, row in
                        GridRow {
                            Text(verbatim: "L\(layer)")
                            Text((row.units ?? 0).formatted())
                            Text((row.tokens ?? 0).formatted())
                            Text((row.heldoutTokens ?? 0).formatted())
                            Text((row.deadUnits ?? 0).formatted()).foregroundStyle((row.deadUnits ?? 0) > 0 ? Color.orange : .primary)
                        }.font(.callout.monospacedDigit())
                    }
                }
                if let stopped = capture.stopped { Text("Stopped early: \(stopped)").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("Build atlas from this capture") {
                        neurons.draft.operation = "atlas"; neurons.draft.capture = id
                        if let model = neurons.config(id)["model"] as? String { neurons.draft.model = model }
                    }.buttonStyle(.dynoPrimary)
                    Text("Sets up an atlas job on the left. Run it to browse units.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - SAE

private struct SAEResultView: View {
    var neurons: NeuronLab
    var id: String
    var job: [String: Any]
    var result: [String: Any]
    @State private var alignment: SAEAlignment?
    @State private var loadError: String?
    @State private var sortOrder = [KeyPathComparator(\SAEFeatureAlignment.bestCorrelationKey, order: .reverse)]
    @State private var candidatesOnly = false
    @State private var liveOnly = true
    @State private var message: String?

    private var reports: [SAEReport] { NeuronResults.decode([SAEReport].self, from: result["reports"]) ?? [] }
    private var sae: [String: Any] { result["sae"] as? [String: Any] ?? [:] }
    private var layer: Int { sae["layer"] as? Int ?? (job["config"] as? [String: Any])?["layers"].flatMap { ($0 as? [Int])?.first } ?? 0 }
    private var model: String { sae["model"] as? String ?? job["model"] as? String ?? "" }
    private var hook: String? { sae["hook"] as? String }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "\((sae["architecture"] as? String ?? "").uppercased()) SAE · layer \(layer) · \(sae["width"] as? Int ?? 0) features from \(sae["width_in"] as? Int ?? 0) inputs · k \(sae["k"] as? Int ?? 0)")
                .font(.callout).foregroundStyle(.secondary)
            metrics
            lossCurve
            if let summary = reports.first?.alignment { alignmentSummary(summary) }
            features
        }
        .task(id: id) {
            guard (result["artifacts"] as? [String] ?? []).contains("sae-alignment.json") else { return }
            do {
                let data = try await neurons.artifact(id, "sae-alignment.json")
                alignment = try await Task.detached { try SAEAlignment.read(data) }.value
            } catch { loadError = "Feature alignment could not be read: \(error.localizedDescription)" }
        }
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Held-out quality per seed").font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Seed").gridColumnAlignment(.leading); Text("FVU"); Text("L0"); Text("Dead"); Text("CE recovered"); Text("CE clean"); Text("CE spliced"); Text("CE zeroed")
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(reports.indices, id: \.self) { i in
                    let r = reports[i]
                    GridRow {
                        Text(verbatim: "\(r.seed ?? i)").gridColumnAlignment(.leading)
                        Text(fmt(r.fvu)); Text(fmt(r.l0, 1)); Text(percent(r.deadOnHeldout))
                        Text(fmt(r.ceLossRecovered)).fontWeight(.semibold)
                        Text(fmt(r.ceClean)); Text(fmt(r.ceSpliced)); Text(fmt(r.ceZeroAblation))
                    }.font(.callout.monospacedDigit())
                }
            }
            Text("FVU: fraction of variance unexplained (lower is better). CE recovered: 0 is as bad as zeroing the hook, 1 is as good as the original model.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lossCurve: some View {
        let points = reports.enumerated().flatMap { i, r in (r.losses ?? []).map { (seed: "Seed \(r.seed ?? i)", step: $0.step, loss: $0.loss) } }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Training loss").font(.headline)
            Chart(points.indices, id: \.self) { i in
                LineMark(x: .value("Step", points[i].step), y: .value("Loss", points[i].loss))
                    .foregroundStyle(by: .value("Seed", points[i].seed))
            }
            .chartForegroundStyleScale(range: [DynoBrand.violet, DynoBrand.accent, Color.orange])
            .chartLegend(reports.count > 1 ? .visible : .hidden)
            .frame(height: 170)
        }
    }

    private func alignmentSummary(_ s: SAEAlignmentSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Are features single neurons?").font(.headline)
            MetricRow {
                Metric(title: "Live features", value: (s.liveFeatures ?? 0).formatted())
                Metric(title: "Median best |r|", value: fmt(s.medianBestCorrelation), detail: "With the single most correlated neuron")
                Metric(title: "Median R² (5 neurons)", value: fmt(s.medianR25))
                Metric(title: "Candidate new building blocks", value: (s.candidateNewBuildingBlocks ?? 0).formatted(), detail: "\(percent(s.candidateShare)) of live features")
            }
            HStack(alignment: .top, spacing: 14) {
                UnitHistogram(title: "Best |correlation| with one neuron", counts: s.bestCorrelationHistogram ?? [], color: DynoBrand.violet)
                UnitHistogram(title: "R² from the top 5 neurons", counts: s.r25Histogram ?? [], color: DynoBrand.violet)
                UnitHistogram(title: "Decoder share of the top neuron", counts: s.decoderShareTop1Histogram ?? [], color: DynoBrand.violet)
            }
            Text("A candidate new building block is a live feature that no single neuron (|r| < \(fmt(s.thresholds?["correlation"], 2))) and no five neurons (R² < \(fmt(s.thresholds?["r2_5"], 2))) explain. A candidate, not a finding: check its examples.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var features: some View {
        if let loadError { Text(loadError).font(.caption).foregroundStyle(.orange) }
        if let alignment {
            let rows = alignment.features.filter { (!liveOnly || $0.live) && (!candidatesOnly || $0.candidate == true) }.sorted(using: sortOrder)
            let atlas = neurons.atlas(model: model, layer: layer, hook: hook)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Features").font(.headline)
                    Spacer()
                    Toggle("Live only", isOn: $liveOnly).toggleStyle(.checkbox)
                    Toggle("Candidates only", isOn: $candidatesOnly).toggleStyle(.checkbox)
                    Button("Export table") { neurons.export(encodable: rows, name: "dyno-sae-L\(layer)-features.json") }.controlSize(.small)
                }
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Feature", value: \.feature) { f in Text(verbatim: "F\(f.feature)").monospacedDigit() }.width(min: 50, ideal: 60)
                    TableColumn("Top neuron") { f in
                        if let neuron = f.bestNeuron {
                            Button("N\(neuron)" as String) {
                                message = neurons.reveal(model: model, layer: layer, hook: hook, index: neuron) ? nil : "Build an atlas of layer \(layer) for this model to browse its neurons."
                            }.buttonStyle(.link).disabled(atlas == nil)
                            .help(atlas == nil ? "No atlas of layer \(layer) for this model." : "Open neuron \(neuron) in the atlas.")
                        } else { Text("—").foregroundStyle(.secondary) }
                    }.width(min: 60, ideal: 70)
                    TableColumn("Best |r|", value: \.bestCorrelationKey) { f in Text(fmt(f.bestCorrelation.map(abs))).monospacedDigit() }.width(min: 56, ideal: 64)
                    TableColumn("R² 1", value: \.r21Key) { f in Text(fmt(f.r21)).monospacedDigit() }.width(min: 50, ideal: 56)
                    TableColumn("R² 5", value: \.r25Key) { f in Text(fmt(f.r25)).monospacedDigit() }.width(min: 50, ideal: 56)
                    TableColumn("Decoder share", value: \.decoderShareKey) { f in Text(fmt(f.decoderShareTop1)).monospacedDigit() }.width(min: 70, ideal: 84)
                    TableColumn("New block?", value: \.candidateKey) { f in
                        if f.candidate == true { Text("Candidate").foregroundStyle(DynoBrand.violet) } else if !f.live { Text("Dead").foregroundStyle(.secondary) } else { Text("") }
                    }.width(min: 70, ideal: 80)
                }.frame(height: 340)
                Text("\(rows.count.formatted()) features · click a top neuron to open it in an atlas of this model and layer").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        } else if (result["artifacts"] as? [String] ?? []).contains("sae-alignment.json"), loadError == nil {
            ProgressView("Reading feature alignment…")
        }
    }
}

// MARK: - Ablation

private struct AblationResultView: View {
    var neurons: NeuronLab
    var result: [String: Any]
    var body: some View {
        if let ablation = NeuronResults.decode(AblationResult.self, from: result["ablation"]) {
            let conditions = ablation.conditions
            VStack(alignment: .leading, spacing: 14) {
                Text("\(ablation.layers.map { "\($0.count) layers" } ?? "Layers") · \(ablation.hook ?? "") · \((ablation.heldoutTokens ?? 0).formatted()) held-out tokens · clean loss \(fmt(ablation.cleanCE))")
                    .font(.callout).foregroundStyle(.secondary)
                Text("How often the top next-token prediction changes").font(.headline)
                Chart {
                    ForEach(conditions) { c in
                        if let t = c.top1Changed {
                            BarMark(x: .value("Top-1 changed", t.mean), y: .value("Condition", c.name))
                                .foregroundStyle(by: .value("Kind", c.isControl ? "Random control" : "Targeted"))
                            if let low = t.low, let high = t.high {
                                RuleMark(xStart: .value("Low", low), xEnd: .value("High", high), y: .value("Condition", c.name))
                                    .foregroundStyle(Color.primary.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.5))
                            }
                        }
                    }
                }
                .chartForegroundStyleScale(["Targeted": DynoBrand.violet, "Random control": Color.secondary.opacity(0.5)])
                .chartXScale(domain: 0...1)
                .chartXAxis { AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d * 100))%") } } } }
                .frame(height: CGFloat(max(conditions.count, 1) * 34 + 40))
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        Text("Condition"); Text("Top-1 changed"); Text("KL"); Text("Loss change"); Text("Entries removed"); Text("Mass removed")
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(conditions) { c in
                        GridRow {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.name)
                                Text(c.isControl ? "random, matched to \(c.of ?? "")" : c.kind == "below" ? "below p\(fmt(c.percentile, 0))" : c.kind == "above" ? "above p\(fmt(c.percentile, 0))" : c.kind)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(c.top1Changed?.text(digits: 1, percent: true) ?? "—")
                            Text(c.kl?.text(digits: 3) ?? "—")
                            Text(c.ceDelta?.text(digits: 3) ?? "—")
                            Text(percent(c.removedEntries))
                            Text(percent(c.removedMass))
                        }.font(.callout.monospacedDigit())
                    }
                }
                Text("Brackets are 95% bootstrap intervals over contexts. A targeted condition matters beyond its size only when it differs from both of its random controls.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Export table") { neurons.export(encodable: conditions, name: "dyno-ablation.json") }.controlSize(.small)
            }
        }
    }
}

// MARK: - Units

private struct UnitsResultView: View {
    var neurons: NeuronLab
    var job: [String: Any]
    var result: [String: Any]
    @State private var message: String?
    private var model: String { job["model"] as? String ?? "" }
    private var hook: String? { (result["hook"] as? [String: Any])?["hook"] as? String }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let attribution = NeuronResults.decode(AttributionResult.self, from: result["attribution"]) { attributionView(attribution) }
            if let set = NeuronResults.decode(AblateSetResult.self, from: result["ablate_set"]) { ablateSetView(set) }
            if let steer = NeuronResults.decode(SteerResult.self, from: result["steer"]) { steerView(steer) }
            if let message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func attributionView(_ a: AttributionResult) -> some View {
        let peak = a.units.map { abs($0.attribution) }.max() ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            Text("Which units push toward ‘\(a.targetToken ?? "")’?").font(.headline)
            ForEach(a.prompts ?? [], id: \.prompt) { p in
                HStack { Text(p.prompt).lineLimit(1); Spacer(); Text("p(target) \(percent(p.targetProbability))").monospacedDigit().foregroundStyle(.secondary) }.font(.caption)
            }
            VStack(spacing: 4) {
                ForEach(a.units.indices, id: \.self) { i in
                    let u = a.units[i]
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.caption).foregroundStyle(.tertiary).frame(width: 24, alignment: .trailing)
                        Button("L\(u.layer) · N\(u.unit)" as String) {
                            message = neurons.reveal(model: model, layer: u.layer, hook: hook, index: u.unit) ? nil : "No atlas of layer \(u.layer) for this model. Capture that layer and build an atlas to browse the unit."
                        }.buttonStyle(.link).frame(width: 110, alignment: .leading)
                        .help("Open in an atlas of this model and layer")
                        GaugeBar(fraction: abs(u.attribution) / max(peak, 1e-9), color: u.attribution >= 0 ? PoleStyle.positive : PoleStyle.negative, height: 8)
                        Text(String(format: "%+.3f", u.attribution)).font(.caption.monospacedDigit()).frame(width: 64, alignment: .trailing)
                        Text(u.direction ?? (u.attribution >= 0 ? "toward" : "against")).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    }
                }
            }
            Text("Totals: \(fmt(a.totalPositive, 1)) toward, \(fmt(a.totalNegative, 1)) against. Copy units into Ablate a set to test them.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Ablate the top 8 as a set") {
                    neurons.draft.operation = "units"; neurons.draft.mode = "ablate_set"
                    neurons.draft.unitSet = a.units.filter { $0.attribution > 0 }.prefix(8).map { "\($0.layer):\($0.unit)" }.joined(separator: ", ")
                    neurons.draft.targetToken = a.targetToken ?? neurons.draft.targetToken
                    if let prompts = a.prompts { neurons.draft.prompts = prompts.map(\.prompt).joined(separator: "\n") }
                    neurons.draft.model = model
                }.controlSize(.small)
                Button("Export list") { neurons.export(encodable: a.units, name: "dyno-attribution.json") }.controlSize(.small)
            }
        }
    }

    private func ablateSetView(_ s: AblateSetResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Zeroing \(s.units?.count ?? 0) units: p(‘\(s.targetToken ?? "")’)").font(.headline)
            MetricRow {
                Metric(title: "Before", value: percent(s.baselineProbability))
                Metric(title: "Units zeroed", value: percent(s.ablatedProbability))
                Metric(title: "Random sets zeroed", value: percent(s.randomControlProbability), detail: "\(s.controlSeeds ?? 0) sets, same count per layer")
            }
            let bars = s.prompts.enumerated().flatMap { i, p -> [(prompt: String, kind: String, value: Double, low: Double?, high: Double?)] in
                let name = "\(i + 1). " + String(p.prompt.prefix(32))
                return [(name, "Before", p.baseline.probability, nil, nil), (name, "Units zeroed", p.ablated.probability, nil, nil),
                        (name, "Random sets", p.randomControl?.mean ?? 0, p.randomControl?.low, p.randomControl?.high)]
            }
            Chart(bars.indices, id: \.self) { i in
                let b = bars[i]
                BarMark(x: .value("Prompt", b.prompt), y: .value("Probability", b.value))
                    .foregroundStyle(by: .value("Condition", b.kind)).position(by: .value("Condition", b.kind))
                if let low = b.low, let high = b.high {
                    RuleMark(x: .value("Prompt", b.prompt), yStart: .value("Low", low), yEnd: .value("High", high))
                        .position(by: .value("Condition", b.kind)).foregroundStyle(Color.primary.opacity(0.7))
                }
            }
            .chartForegroundStyleScale(["Before": Color.secondary.opacity(0.5), "Units zeroed": DynoBrand.violet, "Random sets": DynoBrand.accent])
            .chartYScale(domain: 0...1).frame(height: 190)
            ForEach(s.prompts, id: \.prompt) { p in
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.prompt).font(.callout)
                    HStack(alignment: .top, spacing: 14) {
                        tops("Before", p.baseline)
                        tops("Units zeroed", p.ablated)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Random sets").font(.caption).foregroundStyle(.secondary)
                            Text(p.randomControl?.text(digits: 1, percent: true) ?? "—").font(.caption.monospacedDigit())
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func tops(_ title: String, _ outcome: AblateSetResult.Outcome) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) · \(percent(outcome.probability))").font(.caption).foregroundStyle(.secondary)
            ForEach(outcome.top ?? [], id: \.token) { t in
                HStack { Text(t.token.replacingOccurrences(of: " ", with: "·").replacingOccurrences(of: "\n", with: "↵")).font(.caption.monospaced()); Spacer(); Text(percent(t.probability)).font(.caption.monospacedDigit()) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func steerView(_ s: SteerResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "Steering L\(s.layer ?? 0) · N\(s.unit ?? 0)").font(.headline)
            Text(s.scale == "maximum" ? "Strength is a multiple of the unit's maximum, \(fmt(s.maximum, 1)). The value is added at every position." : "Strength is the value added at every position.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(s.outputs.indices, id: \.self) { i in
                let o = s.outputs[i]
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Strength \(PoleStyle.number(o.strength))").font(.callout.weight(.semibold))
                        if let added = o.added { Text("adds \(PoleStyle.number(added))").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let prompt = o.prompt { Text(prompt).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Text(o.text.isEmpty ? "No visible output." : o.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(o.strength == 0 ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Auto-interp

private struct AutointerpResultView: View {
    var neurons: NeuronLab
    var id: String
    var result: [String: Any]
    @State private var report: AutointerpReport?
    @State private var loadError: String?
    @State private var sortOrder = [KeyPathComparator(\AutointerpRow.detectionKey, order: .reverse)]
    @State private var message: String?

    var body: some View {
        if let auto = NeuronResults.decode(AutointerpResult.self, from: result["autointerp"]) {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "Layer \(auto.layer ?? 0) · \(auto.poles ?? 0) poles scored · pass at \(fmt(auto.threshold, 2)) balanced accuracy\(auto.errors.map { $0 > 0 ? " · \($0) errors" : "" } ?? "")")
                    .font(.callout).foregroundStyle(.secondary)
                baselines(auto)
                ForEach(auto.kinds, id: \.self) { kind in kindDetail(kind, auto.summary[kind]!) }
                if let paired = auto.pairedWith { pairedView(paired) }
                if let blocks = auto.saeNewBuildingBlocks {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SAE features that pass and no neuron explains").font(.headline)
                        MetricRow {
                            Metric(title: "Scored", value: "\(blocks.scored)")
                            Metric(title: "Pass", value: "\(blocks.interpretable)")
                            Metric(title: "Candidate new building blocks", value: "\(blocks.newBuildingBlocks)", detail: "\(percent(blocks.shareOfInterpretable)) of those that pass")
                        }
                    }
                }
                rows(auto)
                HStack {
                    if let atlas = auto.atlas, neurons.details[atlas] != nil {
                        Button("Open atlas with these labels") {
                            neurons.openAtlas(atlas, labels: id)
                        }.controlSize(.small)
                    }
                }
            }
            .task(id: id) {
                do {
                    let data = try await neurons.artifact(id, "autointerp.json")
                    report = try await Task.detached { try AutointerpReport.read(data) }.value
                } catch { loadError = "Rows could not be read: \(error.localizedDescription)" }
            }
        }
    }

    private func baselines(_ auto: AutointerpResult) -> some View {
        let columns: [(String, AutointerpScoreSummary?, Color)] = [
            ("Neurons · detection", auto.summary["neuron"]?.detection, DynoBrand.accent),
            ("Neurons · shuffled labels", auto.summary["neuron"]?.shuffledLabels, Color.secondary),
            ("Random directions · detection", auto.summary["random"]?.detection, Color.secondary),
        ] + (auto.summary["sae"].map { [("SAE features · detection", $0.detection, DynoBrand.violet)] } ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            Text("Labels against their baselines").font(.headline)
            Text("A label is worth something only when its unit beats both the shuffled labels and the random directions scored the same way.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 12) {
                ForEach(columns.indices, id: \.self) { i in
                    let (title, s, color) = columns[i]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.caption.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        if let s {
                            Text(percent(s.passRate, 0)).font(.title2.monospacedDigit())
                            Text(verbatim: "pass · \(s.poles) poles").font(.caption2).foregroundStyle(.secondary)
                            Text("mean \(fmt(s.mean, 2)) · median \(fmt(s.median, 2))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            UnitHistogram(title: "Balanced accuracy", counts: s.histogram, color: color, height: 70)
                        } else { Text("Not scored").font(.caption).foregroundStyle(.secondary) }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func kindDetail(_ kind: String, _ s: AutointerpKindSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind == "neuron" ? "Neurons" : kind == "random" ? "Random directions" : kind == "sae" ? "SAE features" : kind.capitalized).font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                GridRow { Text("Score"); Text("Poles"); Text("Pass rate"); Text("Mean"); Text("Median") }.font(.caption).foregroundStyle(.secondary)
                summaryRow("Detection", s.detection)
                summaryRow("Fuzzing", s.fuzzing)
                summaryRow("Shuffled labels", s.shuffledLabels)
                ForEach(NeuronPole.allCases) { pole in
                    if let entry = s.byPole?[pole.rawValue], let value = entry { summaryRow("Detection · \(pole.rawValue) pole", value) }
                }
            }
        }
    }
    private func summaryRow(_ title: String, _ s: AutointerpScoreSummary?) -> some View {
        GridRow {
            Text(title)
            Text(s.map { "\($0.poles)" } ?? "—")
            Text(percent(s?.passRate, 0))
            Text(fmt(s?.mean, 2))
            Text(fmt(s?.median, 2))
        }.font(.callout.monospacedDigit())
    }

    private func pairedView(_ p: AutointerpResult.PairedWith) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paired with an earlier run").font(.headline)
            if let n = p.neuron {
                MetricRow {
                    Metric(title: "Shared poles", value: "\(n.poles)")
                    Metric(title: "Mean difference", value: String(format: "%+.3f", n.meanDifference), detail: "This run minus the other")
                    Metric(title: "Pass rate", value: "\(percent(n.thisPassRate, 0)) vs \(percent(n.otherPassRate, 0))")
                    Metric(title: "p-value", value: String(format: "%.3f", n.pValue), detail: "Sign-flip permutation test")
                }
            } else { Text("The two runs scored no poles in common.").font(.caption).foregroundStyle(.secondary) }
            Text("Compared with job \(p.job)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private func rows(_ auto: AutointerpResult) -> some View {
        if let loadError { Text(loadError).font(.caption).foregroundStyle(.orange) }
        if let report {
            let rows = report.rows.sorted(using: sortOrder)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Every pole").font(.headline)
                    Spacer()
                    Button("Export rows") { neurons.export(encodable: rows, name: "dyno-autointerp-rows.json") }.controlSize(.small)
                }
                Table(rows, sortOrder: $sortOrder) {
                    TableColumn("Unit", value: \.unit) { r in
                        Button(r.kind == "neuron" ? "N\(r.index)" as String : "\(r.kind.prefix(1).uppercased())\(r.index)") {
                            message = auto.atlas.map { neurons.reveal(atlas: $0, model: "", layer: r.layer, hook: nil, kind: r.kind, index: r.index) } == true ? nil : "The atlas this run labeled is not available."
                        }.buttonStyle(.link)
                    }.width(min: 50, ideal: 60)
                    TableColumn("Pole", value: \.pole) { r in Text(r.pole).foregroundStyle(PoleStyle.color(NeuronPole(rawValue: r.pole) ?? .positive)) }.width(min: 56, ideal: 64)
                    TableColumn("Label") { r in Text(r.label ?? r.status).lineLimit(2).foregroundStyle(r.label == nil ? Color.orange : .primary).help(r.label ?? r.status) }
                    TableColumn("Detection", value: \.detectionKey) { r in Text(fmt(r.detection?.balancedAccuracy, 2)).monospacedDigit().fontWeight((r.detection?.balancedAccuracy ?? 0) >= (auto.threshold ?? 1) ? .bold : .regular) }.width(min: 60, ideal: 66)
                    TableColumn("Fuzzing", value: \.fuzzingKey) { r in Text(fmt(r.fuzzing?.balancedAccuracy, 2)).monospacedDigit() }.width(min: 54, ideal: 60)
                    TableColumn("Shuffled") { r in Text(fmt(r.shuffledDetection?.balancedAccuracy, 2)).monospacedDigit().foregroundStyle(.secondary) }.width(min: 54, ideal: 60)
                }.frame(height: 320)
                Text("Bold: the label passes. Shuffled: the same pole scored with another unit's label. Click a unit to open it in the atlas.").font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}
