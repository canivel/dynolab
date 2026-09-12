import SwiftUI
import DynoKit

struct GGUFModelsView: View {
    var model: MonitorModel
    var useInPool: (String) -> Void
    @State private var repository = "Qwen/Qwen3-0.6B-GGUF"
    @State private var listedRepository = ""
    @State private var files: [GGUFFile] = []
    @State private var selected = ""
    @State private var loading = false
    @State private var error = ""

    init(model: MonitorModel, repository: String = "Qwen/Qwen3-0.6B-GGUF", useInPool: @escaping (String) -> Void) {
        self.model = model; self.useInPool = useInPool
        _repository = State(initialValue: repository)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Download a GGUF model").font(.title3.bold())
                Text("Enter a Hugging Face repository and choose one quantization file. Downloads can be cancelled and retried. Split GGUF files are not supported in this preview.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("organization/model-GGUF", text: $repository).textFieldStyle(.roundedBorder)
                        .onSubmit { fetch() }
                    Button("Find files") { fetch() }.disabled(loading)
                    if loading { ProgressView().controlSize(.small) }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if !files.isEmpty {
                    Picker("File / quantization", selection: $selected) {
                        ForEach(files) { file in
                            Text(file.rfilename + (file.size.map { " · " + Format.bytes($0) } ?? "") + (file.supported ? "" : " · split file unsupported"))
                                .tag(file.rfilename)
                        }
                    }
                    let identifier = listedRepository + "/" + selected
                    if let progress = model.downloads[identifier] {
                        if let message = progress.error {
                            Text(message).font(.caption).foregroundStyle(.orange)
                            Button("Retry download") { model.downloadGGUF(repository: listedRepository, filename: selected) }
                        } else if progress.isFinished {
                            Label("Downloaded — ready to select below", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            HStack {
                                if let fraction = progress.fraction { ProgressView(value: fraction).frame(width: 200) }
                                else { ProgressView().controlSize(.small) }
                                Text(Format.bytes(progress.downloadedBytes)).font(.caption)
                                Button("Cancel") { model.cancelGGUF(identifier) }
                            }
                        }
                    } else {
                        Button("Download selected GGUF") { model.downloadGGUF(repository: listedRepository, filename: selected) }
                            .buttonStyle(.dynoPrimary)
                            .disabled(!files.contains(where: { $0.rfilename == selected && $0.supported }) || loading || repository != listedRepository)
                    }
                }
                Divider()
                HStack {
                    Text("Downloaded GGUF models").font(.headline)
                    Spacer()
                    Button("Refresh library") { model.rescanModels() }
                }
                if model.ggufModels.isEmpty {
                    Text("No complete GGUF models found. Download one above or use Choose GGUF in Pools to select an existing file.").foregroundStyle(.secondary)
                }
                ForEach(model.ggufModels) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.callout.bold())
                            Text("GGUF · " + Format.bytes(item.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use in Pools") { useInPool(item.path) }
                    }.padding(12).background(.quaternary.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }.padding(20)
        }
        .task { if files.isEmpty { fetch() } }
    }
    private func fetch() {
        guard !loading else { return }
        let repo = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        repository = repo; loading = true; error = ""; files = []; selected = ""
        Task {
            do {
                files = try await GGUFModels.files(repository: repo)
                listedRepository = repo
                selected = files.first(where: { $0.supported })?.rfilename ?? ""
                if files.isEmpty { error = "This repository contains no GGUF files." }
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
