import DynoKit
import SwiftUI

/// A downloaded model someone asked to delete, waiting for them to confirm.
struct ModelToDelete: Identifiable {
    var path: String
    var name: String
    var id: String { path }
}

/// Asks before moving a downloaded model to the Trash: what goes, how much space it frees, and that a running model
/// has to be stopped first.
struct DeleteModelConfirmation: ViewModifier {
    var model: MonitorModel
    @Binding var item: ModelToDelete?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }), presenting: item) { target in
                let plan = model.removalPlan(path: target.path, name: target.name)
                if plan.problem == nil {
                    Button("Move to Trash", role: .destructive) {
                        failure = model.deleteModel(path: target.path, name: target.name)
                        item = nil
                    }
                }
                Button(plan.problem == nil ? "Cancel" : "OK", role: .cancel) { item = nil }
            } message: { target in
                let plan = model.removalPlan(path: target.path, name: target.name)
                if let problem = plan.problem {
                    Text(problem)
                } else {
                    Text(Self.message(plan.bytes, plan.targets))
                }
            }
            .alert("Model not deleted", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }

    private static func message(_ bytes: Int64, _ targets: [URL]) -> String {
        let folder = targets.first.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? ""
        let size: String = Format.bytes(bytes)
        return size + " will be moved to the Trash:\n" + folder
            + "\n\nThe space comes back when you empty the Trash. Until then you can put it back from the Trash."
    }

    private var title: String { "Delete \(item?.name ?? "this model")?" }
}

extension View {
    func confirmsModelDeletion(_ model: MonitorModel, item: Binding<ModelToDelete?>) -> some View {
        modifier(DeleteModelConfirmation(model: model, item: item))
    }
}
