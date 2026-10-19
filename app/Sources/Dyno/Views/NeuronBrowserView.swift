import Charts
import DynoKit
import SwiftUI

/// Pole colours, used for every highlight, chart and label of a pole.
enum PoleStyle {
    static let positive = DynoBrand.accent
    static let negative = DynoBrand.violet
    static func color(_ pole: NeuronPole) -> Color { pole == .positive ? positive : negative }
    static func number(_ value: Double) -> String {
        abs(value) >= 100 ? String(format: "%.0f", value) : abs(value) >= 10 ? String(format: "%.1f", value) : String(format: "%.2f", value)
    }
    static func rate(_ value: Double?) -> String { value.map { $0 >= 10 ? String(format: "%.1f", $0) : String(format: "%.2f", $0) } ?? "—" }
}

/// A finished atlas: a searchable, sortable list of units beside the selected unit's page.
struct NeuronBrowserView: View {
    var neurons: NeuronLab
    var browser: AtlasBrowser
    @State private var query = ""
    @State private var kind = ""
    @State private var level = 0
    @State private var sortOrder = [KeyPathComparator(\AtlasUnitSummary.unit)]
    @State private var selection: Int?

    private static let levels = ["10%", "25%", "50%"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 14).padding(.vertical, 10)
            if let error = browser.error {
                Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 8)
            }
            Divider()
            if browser.loading && browser.index == nil {
                ProgressView("Reading the atlas…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let index = browser.index {
                HSplitView {
                    unitList(index).frame(minWidth: 330, idealWidth: 400, maxWidth: 560)
                    UnitPageView(neurons: neurons, browser: browser).frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else { Spacer() }
        }
        .onAppear { selection = browser.selectedUnit }
        .onChange(of: browser.selectedUnit) { _, value in if selection != value { selection = value } }
        .onChange(of: selection) { _, value in if value != browser.selectedUnit { Task { await browser.open(value) } } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            if browser.layers.count > 1 {
                Picker("Layer", selection: Binding(get: { browser.layer }, set: { value in Task { await browser.setLayer(value) } })) {
                    ForEach(browser.layers, id: \.self) { Text(verbatim: "Layer \($0)").tag($0) }
                }.frame(maxWidth: 150)
            } else {
                Text(verbatim: "Layer \(browser.layer)").font(.headline)
            }
            if let index = browser.index {
                Text("\(index.units.count.formatted()) units · \(index.tokens.formatted()) tokens · \(index.hook)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Labels", selection: Binding(get: { browser.labelsJob }, set: { id in Task { await browser.loadLabels(id) } })) {
                Text("No labels").tag("")
                ForEach(browser.labelJobs.compactMap { $0["id"] as? String }, id: \.self) { id in
                    Text("Auto-interp · " + ((neurons.jobs.first { $0["id"] as? String == id }?["created"] as? Double).map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? id.prefix(8).description)).tag(id)
                }
            }.frame(maxWidth: 260)
            .disabled(browser.labelJobs.isEmpty)
            .help(browser.labelJobs.isEmpty ? "Run auto-interp on this atlas to label its units." : "Show auto-interp labels and their scores on each pole.")
        }
    }

    private func rows(_ index: AtlasIndex) -> [AtlasUnitSummary] {
        index.filtered(query: query, kind: kind.isEmpty ? nil : kind).sorted(using: sortOrder)
    }

    private func unitList(_ index: AtlasIndex) -> some View {
        let shown = rows(index)
        let label = Self.levels[level]
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Search: unit, neuron 20, or a token", text: $query).textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $kind) {
                    Text("All kinds").tag("")
                    ForEach(index.kinds, id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden().frame(width: 110)
            }
            HStack {
                Text("Rate at").font(.caption).foregroundStyle(.secondary)
                Picker("Rate at", selection: $level) { ForEach(0..<3) { Text("\(Self.levels[$0]) of max").tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                    .help("Firing rate per 100 tokens: how often each pole reaches this fraction of its own maximum.")
            }
            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Unit", value: \.unit) { u in
                    Text(u.kind == "neuron" ? "N\(u.index)" : "\(u.kind.prefix(1).uppercased())\(u.index)")
                        .monospacedDigit().foregroundStyle(u.kind == "neuron" ? Color.primary : Color.secondary)
                        .help("\(u.kind.capitalized) \(u.index) · unit \(u.unit)")
                }.width(min: 48, ideal: 56)
                TableColumn("+ max", value: \.positiveMaximum) { u in Text(PoleStyle.number(u.positive.maximum)).monospacedDigit() }.width(min: 44, ideal: 50)
                TableColumn("− max", value: \.negativeMaximum) { u in Text(PoleStyle.number(u.negative.maximum)).monospacedDigit() }.width(min: 44, ideal: 50)
                TableColumn("+ /100", value: rateKey(.positive)) { u in Text(PoleStyle.rate(rate(u, .positive))).monospacedDigit() }.width(min: 44, ideal: 50)
                TableColumn("− /100", value: rateKey(.negative)) { u in Text(PoleStyle.rate(rate(u, .negative))).monospacedDigit() }.width(min: 44, ideal: 50)
                TableColumn("Preview (+ | −)") { u in
                    (Text(preview(u.positive.preview)).foregroundColor(PoleStyle.positive) + Text("  |  ").foregroundColor(.secondary) + Text(preview(u.negative.preview)).foregroundColor(PoleStyle.negative))
                        .lineLimit(1).help("Positive: \(u.positive.preview.joined(separator: " ")) \nNegative: \(u.negative.preview.joined(separator: " "))")
                }
            }
            HStack {
                Text("\(shown.count.formatted()) of \(index.units.count.formatted()) units · rates at \(label) of each pole's maximum").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Export list") { neurons.export(encodable: shown, name: "dyno-atlas-L\(index.layer)-units.json") }.controlSize(.small)
            }
        }.padding(12)
    }

    private func rate(_ u: AtlasUnitSummary, _ pole: NeuronPole) -> Double? {
        let rates = u.pole(pole).rates
        return [rates.above10, rates.above25, rates.above50][level]
    }
    private func rateKey(_ pole: NeuronPole) -> KeyPath<AtlasUnitSummary, Double> {
        switch (pole, level) {
        case (.positive, 0): return \.positiveRate10
        case (.positive, 1): return \.positiveRate25
        case (.positive, _): return \.positiveRate50
        case (.negative, 0): return \.negativeRate10
        case (.negative, 1): return \.negativeRate25
        case (.negative, _): return \.negativeRate50
        }
    }
    private func preview(_ tokens: [String]) -> String {
        tokens.prefix(4).map { $0.replacingOccurrences(of: "\n", with: "↵") }.joined(separator: "·")
    }
}

// MARK: - Unit page

private struct UnitPageView: View {
    var neurons: NeuronLab
    var browser: AtlasBrowser
    @State private var mode = CommandLine.arguments.contains("--snapshot") ? ProcessInfo.processInfo.environment["DYNO_NEURON_POLES"] ?? "both" : "both"

    @State private var width: CGFloat = 800

    var body: some View {
        ScrollView {
            if let page = browser.page {
                content(page).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
            } else if browser.pageLoading {
                ProgressView("Reading unit…").padding(40).frame(maxWidth: .infinity)
            } else if let error = browser.pageError {
                Text(error).font(.callout).foregroundStyle(.orange).padding(20)
            } else {
                Text("Choose a unit from the list.").foregroundStyle(.secondary).padding(20)
            }
        }
    }

    @ViewBuilder private func content(_ page: UnitPage) -> some View {
        let labels = browser.labels?.labels(layer: browser.layer, unit: page.unit) ?? [:]
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "\(page.kind == "sae" ? "SAE feature" : page.kind.capitalized) \(page.index)").font(.title2)
                Text(verbatim: "Layer \(browser.layer) · unit \(page.unit)").foregroundStyle(.secondary)
                Spacer()
                if browser.pageLoading { ProgressView().controlSize(.small) }
                Button("Export unit") { neurons.export(encodable: page, name: "dyno-L\(browser.layer)-unit-\(page.unit).json") }.controlSize(.small)
            }
            HStack(spacing: 14) {
                if let mean = page.mean { Text("Mean \(PoleStyle.number(mean))") }
                if let std = page.std { Text("Std \(PoleStyle.number(std))") }
                if page.kind == "random" { Text("A random direction: a baseline, not a neuron.").foregroundStyle(.orange) }
            }.font(.caption).foregroundStyle(.secondary)
            Picker("Poles", selection: $mode) {
                Text("Side by side").tag("both"); Text("Positive").tag("positive"); Text("Negative").tag("negative")
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
            legend(page)
            if mode == "both" && width < 700 {
                // Too narrow for two columns: one pole above the other, still apart.
                PoleColumn(page: page, pole: .positive, vocab: browser.vocab, label: labels[.positive], compact: false)
                Divider()
                PoleColumn(page: page, pole: .negative, vocab: browser.vocab, label: labels[.negative], compact: false)
            } else if mode == "both" {
                HStack(alignment: .top, spacing: 14) {
                    PoleColumn(page: page, pole: .positive, vocab: browser.vocab, label: labels[.positive], compact: true)
                    Divider()
                    PoleColumn(page: page, pole: .negative, vocab: browser.vocab, label: labels[.negative], compact: true)
                }
            } else if let pole = NeuronPole(rawValue: mode) {
                PoleColumn(page: page, pole: pole, vocab: browser.vocab, label: labels[pole], compact: false)
            }
            Divider()
            ExampleList(title: "Random samples", note: "Tokens drawn at random from training documents, not ranked. They show what this unit does most of the time.",
                        examples: page.random, page: page, vocab: browser.vocab, initial: 6)
            ExampleList(title: "Held-out random samples", note: "The same, from held-out documents.",
                        examples: page.heldoutRandom, page: page, vocab: browser.vocab, initial: 0)
        }
    }

    private func legend(_ page: UnitPage) -> some View {
        HStack(spacing: 14) {
            swatch(.positive, "positive, shaded by activation ÷ \(PoleStyle.number(page.positiveMaximum))")
            swatch(.negative, "negative, ÷ \(PoleStyle.number(page.negativeMaximum))")
            HStack(spacing: 4) {
                Text("tok").font(.caption2).padding(.horizontal, 2).overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary, lineWidth: 1.2))
                Text("the example's token").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func swatch(_ pole: NeuronPole, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(PoleStyle.color(pole).opacity(0.6)).frame(width: 14, height: 12)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PoleColumn: View {
    var page: UnitPage
    var pole: NeuronPole
    var vocab: AtlasVocab
    var label: AutointerpRow?
    var compact: Bool

    var body: some View {
        let data = page.pole(pole)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(PoleStyle.color(pole)).frame(width: 9, height: 9)
                Text("\(pole.title) pole").font(.headline)
                Spacer()
                Text("max \(pole == .negative ? "−" : "")\(PoleStyle.number(data?.maximum ?? 0))").font(.callout.monospacedDigit())
            }
            if let label { labelBox(label) }
            if let data, data.maximum > 1e-6, !data.top.isEmpty {
                rates(data.rates)
                histogram(data)
                ExampleList(title: "Top activations", note: nil, examples: data.top, page: page, vocab: vocab, initial: compact ? 5 : 10)
                ExampleList(title: "Held-out top", note: "Strongest on documents the atlas didn't rank. Similar text here suggests the pattern generalizes.",
                            examples: data.heldoutTop, page: page, vocab: vocab, initial: 0)
                if !data.strata.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Stratified samples").font(.subheadline.weight(.semibold))
                        Text("Random examples from each band of activation, to show what weaker firing looks like.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(data.strata, id: \.decile) { stratum in
                            ExampleList(title: stratum.title, note: nil, examples: stratum.examples, page: page, vocab: vocab, initial: 0, small: true)
                        }
                    }
                }
            } else {
                Text("This pole never fires on the captured tokens.").font(.callout).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labelBox(_ row: AutointerpRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("AUTO-INTERP LABEL").font(.caption2).foregroundStyle(.secondary)
            if let text = row.label {
                Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { scores(row) }
                    VStack(alignment: .leading, spacing: 2) { scores(row) }
                }.font(.caption.monospacedDigit())
            } else {
                Text(row.status).font(.caption).foregroundStyle(.orange)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(PoleStyle.color(pole).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(PoleStyle.color(pole).opacity(0.3)))
    }
    @ViewBuilder private func scores(_ row: AutointerpRow) -> some View {
        score("Detection", row.detection)
        score("Fuzzing", row.fuzzing)
        score("Shuffled labels", row.shuffledDetection)
    }
    private func score(_ title: String, _ value: AutointerpRow.Score?) -> some View {
        HStack(spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value?.balancedAccuracy.map { String(format: "%.2f", $0) } ?? "—")
        }.fixedSize().help("Balanced accuracy on \(value?.shown ?? 0) held-out texts. 0.5 is chance.")
    }

    private func rates(_ rates: NeuronRates) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Firing rate per 100 tokens").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(rates.levels, id: \.0) { level, value in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(PoleStyle.rate(value)).font(.callout.monospacedDigit())
                        Text("≥ \(level) of max").font(.caption2).foregroundStyle(.secondary).fixedSize()
                    }.padding(.horizontal, 8).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }
    }

    private func histogram(_ data: UnitPage.Pole) -> some View {
        let labels = page.binLabels
        let counts = data.histogram
        return VStack(alignment: .leading, spacing: 4) {
            Text("How often it reaches each level").font(.caption).foregroundStyle(.secondary)
            Chart(counts.indices, id: \.self) { i in
                BarMark(x: .value("|activation|", i < labels.count ? labels[i] : "\(i)"), y: .value("Tokens", counts[i]))
                    .foregroundStyle(PoleStyle.color(pole).opacity(0.8))
            }
            .chartXAxis {
                AxisMarks(values: ticks(labels)) { value in
                    AxisValueLabel { if let text = value.as(String.self) { Text(Self.short(text)).font(.system(size: 9)) } }
                }
            }
            .chartYScale(type: .symmetricLog)
            .frame(height: compact ? 100 : 120)
            Text("Tokens per |activation| band, by lower edge. Log scale.").font(.caption2).foregroundStyle(.tertiary)
        }
    }
    /// Every fourth band from 0.01 up, so labels never collide.
    private func ticks(_ labels: [String]) -> [String] {
        stride(from: 1, to: labels.count, by: 4).map { labels[$0] }
    }
    /// "0.01–0.032" → "0.01": a band's lower edge.
    static func short(_ label: String) -> String { label.split(separator: "–").first.map(String.init) ?? label }
}

/// A titled list of examples with a "show all".
private struct ExampleList: View {
    var title: String
    var note: String?
    var examples: [ActivationExample]
    var page: UnitPage
    var vocab: AtlasVocab
    var initial: Int
    var small = false
    @State private var expanded: Bool?

    var body: some View {
        if !examples.isEmpty {
            let open = expanded ?? (initial > 0)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    expanded = !open
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                        Text(title).font(small ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                        Text("\(examples.count)").font(.caption).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                if open {
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    let shown = showAll ? examples : Array(examples.prefix(initial > 0 ? initial : 6))
                    ForEach(shown.indices, id: \.self) { i in ExampleView(example: shown[i], page: page, vocab: vocab) }
                    if shown.count < examples.count {
                        Button("Show all \(examples.count)") { showAll = true }.controlSize(.small)
                    }
                }
            }
        }
    }
    @State private var showAll = false
}

/// One example: its value, then the window of tokens shaded by activation.
struct ExampleView: View {
    var example: ActivationExample
    var page: UnitPage
    var vocab: AtlasVocab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let tokens = TokenHighlight.make(example, vocab: vocab, positiveMaximum: page.positiveMaximum, negativeMaximum: page.negativeMaximum)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(PoleStyle.number(example.value)).font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(example.value < 0 ? PoleStyle.negative : PoleStyle.positive)
                Text("\(Int((example.fraction * 100).rounded()))% of max").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let context = example.context, let position = example.position {
                    Text(verbatim: "document \(context) · token \(position)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            FlowLayout(spacing: 0, lineSpacing: 2) {
                ForEach(tokens.indices, id: \.self) { i in chip(tokens[i]) }
            }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private func chip(_ token: TokenHighlight) -> some View {
        let shade = token.intensity >= 0.04 ? token.intensity : 0
        let color = token.pole.map(PoleStyle.color) ?? .clear
        // Dark text on strong lime: light text there is unreadable.
        let darkText = scheme == .dark && token.pole == .positive && shade > 0.45
        return Text(token.display.isEmpty ? "∅" : token.display)
            .font(.system(size: 12))
            .foregroundStyle(darkText ? DynoBrand.ink : Color.primary)
            .padding(.vertical, 1).padding(.horizontal, token.isCenter ? 1 : 0)
            .background(color.opacity(shade == 0 ? 0 : 0.1 + 0.6 * shade), in: RoundedRectangle(cornerRadius: 2))
            .overlay {
                if token.isCenter { RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary, lineWidth: 1.3) }
            }
            .help("\(PoleStyle.number(token.activation))\(token.isCenter ? " · this example's token" : "")")
    }
}
