import DynoKit
import SwiftUI

struct DiscoverView: View {
    var model: MonitorModel
    var useMLX: (String) -> Void = { _ in }
    var useGGUF: (String) -> Void = { _ in }
    @State var library = false
    @State private var selectedRepository: String?
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Format", selection: Binding(get: { model.catalogFormat }, set: { model.catalogFormat = $0 })) {
                        ForEach(ModelCatalog.ModelFormat.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).frame(width: 200)
                    Picker("Source", selection: $library) {
                        Text("Search Hub").tag(false)
                        Text("Downloaded (\(downloadedCount))").tag(true)
                    }.pickerStyle(.segmented).frame(width: 310)
                    Spacer()
                    if library { Button("Refresh library") { model.rescanModels() } }
                }
                Text(model.catalogFormat == .mlx
                     ? "MLX · Serve on Apple Silicon and run Lab experiments. Use in Models to configure and start."
                     : "GGUF · Run through the experimental pool. Choose one quantization; MLX serving and Lab capture do not support this format.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(library ? "Filter downloaded models" : "Search \(model.catalogFormat.rawValue) models on Hugging Face", text: Binding(get: { model.searchText }, set: { model.searchCatalog($0) })).textFieldStyle(.roundedBorder)
                    if model.isSearching && !library { ProgressView().controlSize(.small) }
                    if !library {
                        Picker("Sort", selection: Binding(get: { model.catalogSort }, set: { model.catalogSort = $0 })) {
                            ForEach(ModelCatalog.Sort.allCases) { Text($0.title).tag($0) }
                        }.frame(width: 160)
                    }
                }
            }.padding(16)
            Divider()
            downloadActivity
            if library { downloaded }
            else if let error = model.catalogError {
                VStack { Text(error).foregroundStyle(.secondary); Button("Retry") { model.loadCatalog() } }.padding()
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if model.catalog.isEmpty && !model.isSearching { Text("No matching models.").foregroundStyle(.secondary).padding() }
                        ForEach(model.catalog) { candidate in
                            CatalogRow(model: model, candidate: candidate,
                                       isDownloaded: model.downloadedRepositories.contains(candidate.id),
                                       progress: model.downloads[candidate.id], budget: model.system.gpuMemoryBudget,
                                       useMLX: useMLX, chooseGGUF: { selectedRepository = $0 })
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { selectedRepository != nil }, set: { if !$0 { selectedRepository = nil } })) {
            VStack {
                HStack { Text("GGUF files").font(.headline); Spacer(); Button("Done") { selectedRepository = nil } }.padding()
                GGUFModelsView(model: model, repository: selectedRepository ?? "") { path in
                    selectedRepository = nil; useGGUF(path)
                }
            }.frame(width: 760, height: 640)
        }
    }
    private var visibleDownloads: [DownloadManager.Progress] {
        model.downloads.values.sorted { $0.repository < $1.repository }
    }
    @ViewBuilder private var downloadActivity: some View {
        if !visibleDownloads.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Downloads", systemImage: "arrow.down.circle.fill").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(visibleDownloads, id: \.repository) { item in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.displayName ?? item.repository).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(item.status == "cancelled" ? "Cancelled" : item.error != nil ? "Stopped" : item.isFinished ? "Downloaded" : item.isStale ? "Status unavailable" : item.isPaused ? "Paused" : item.status == "cancelling" ? "Cancelling…" : "Downloading")
                                        .font(.caption).foregroundStyle(item.error != nil || item.isStale ? Color.orange : Color.secondary)
                                    if !item.isFinished && (!item.isExternal || item.controlToken != nil) {
                                        Button(item.isPaused ? "Continue" : "Pause") {
                                            if item.isPaused { model.continueDownload(item.repository) }
                                            else { model.pauseDownload(item.repository) }
                                        }.controlSize(.small).disabled(item.isStale)
                                    }
                                    if !item.isExternal || (!item.isFinished && item.controlToken != nil) {
                                        Button(item.isFinished ? "Dismiss" : "Cancel") {
                                            if item.isFinished { model.dismissDownload(item.repository) }
                                            else { model.cancelGGUF(item.repository) }
                                        }.controlSize(.small).disabled(item.isStale)
                                    }
                                }
                                if let fraction = item.fraction {
                                    ProgressView(value: fraction).tint(item.isStale ? .orange : .accentColor)
                                    Text("\(Int(fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: item.downloadedBytes, countStyle: .decimal)) of \(ByteCountFormatter.string(fromByteCount: item.totalBytes ?? 0, countStyle: .decimal))")
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                } else { ProgressView().controlSize(.small) }
                                if let detail = item.error ?? item.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                                if item.isExternal {
                                    Text("Background download · continues when Dyno closes").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxHeight: 160)
            }.padding(16).background(Color.accentColor.opacity(0.05))
            Divider()
        }
    }
    private var downloadedCount: Int { model.catalogFormat == .mlx ? model.localModels.count : model.ggufModels.count }
    private func matches(_ value: String) -> Bool {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }
    private var downloaded: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.catalogFormat == .mlx {
                    ForEach(model.localModels.filter { matches($0.name) }) { item in
                        libraryRow(item.shortName, detail: "MLX · " + Format.bytes(item.sizeBytes), action: "Use in Models") { useMLX(item.name) }
                    }
                } else {
                    ForEach(model.ggufModels.filter { matches($0.name + " " + ($0.repository ?? "")) }) { item in
                        libraryRow(item.name, detail: "GGUF · " + Format.bytes(item.size), action: "Use in Pools") { useGGUF(item.path) }
                    }
                }
                Text("Only complete local models are listed. Selecting a model does not start it or replace a running endpoint.").font(.caption).foregroundStyle(.secondary)
                if downloadedCount == 0 { Text("No downloaded \(model.catalogFormat.rawValue) models. Switch to Search Hub to download one.").foregroundStyle(.secondary) }
            }.padding(16)
        }
    }
    private func libraryRow(_ name: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) { Text(name).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(action, action: perform).buttonStyle(.dynoPrimary)
        }.padding(14).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct CatalogRow: View {
    var model: MonitorModel
    var candidate: CatalogModel
    var isDownloaded: Bool
    var progress: DownloadManager.Progress?
    var budget: Int64?
    var useMLX: (String) -> Void
    var chooseGGUF: (String) -> Void

    /// A model whose weights alone exceed the GPU budget cannot run here, and
    /// one that is close will have no room left for the KV cache.
    private var fitsComfortably: Bool {
        guard model.catalogFormat == .mlx else { return true }
        guard let budget, let size = candidate.sizeBytes else { return true }
        return Double(size) < Double(budget) * 0.85
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    if let quantization = candidate.quantization {
                        Text(quantization)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    if candidate.isMultimodal {
                        Text("vision")
                            .font(.system(size: 9))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    if !fitsComfortably {
                        Label("memory caution", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                            .help("Weights approach or exceed this Mac's GPU budget; context and workspace need additional memory.")
                    }
                }
                HStack(spacing: 8) {
                    Text(candidate.author)
                    if let size = candidate.sizeBytes {
                        Text("· \(Format.bytes(size))")
                    }
                    if let released = candidate.createdAt {
                        Text("· \(Self.relative(released))")
                    }
                    // A brand-new repository has no downloads and no likes;
                    // printing "0 downloads" on every row is noise, not data.
                    if candidate.downloads > 0 {
                        Text("· \(formatted(candidate.downloads)) downloads")
                    }
                    if candidate.likes > 0 {
                        Text("· ♥ \(candidate.likes)")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var action: some View {
        if model.catalogFormat == .gguf {
            VStack(alignment: .trailing, spacing: 4) {
                if model.ggufModels.contains(where: { $0.repository == candidate.id }) {
                    Label("Files downloaded", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
                Button("Choose GGUF file") { chooseGGUF(candidate.id) }.controlSize(.small)
            }
        } else if let progress, let error = progress.error {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Failed").font(.system(size: 10)).foregroundStyle(.red)
                Button("Dismiss") { model.dismissDownload(candidate.id) }
                    .controlSize(.mini)
            }
            .help(error)
        } else if let progress, !progress.isFinished {
            VStack(alignment: .trailing, spacing: 3) {
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).frame(width: 96)
                    Text("\(Format.bytes(progress.downloadedBytes)) of "
                         + "\(Format.bytes(progress.totalBytes))")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel") { model.cancelDownload(candidate) }
                    .controlSize(.mini)
            }
        } else if isDownloaded || progress?.isFinished == true {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.system(size: 11))
                Button("Use in Models") { useMLX(candidate.id) }.controlSize(.small)
            }
        } else {
            Button("Download") { model.download(candidate) }
                .controlSize(.small)
                .disabled(model.runtime == nil)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relative(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatted(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.0fk", Double(count) / 1_000) }
        return "\(count)"
    }
}
