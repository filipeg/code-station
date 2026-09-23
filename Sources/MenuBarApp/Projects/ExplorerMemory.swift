import Foundation

// Where each explorer was left, by the folder it shows. The pane is torn down whenever
// another tab takes its place, so without this every trip to Chat and back would shut
// every folder and drop the file that was open, unsaved edits included.
@MainActor
@Observable
final class ExplorerMemory {
    struct Place {
        var expanded: Set<String> = []
        var selected: FileNode?
        var showHidden = true
        var treeWidth = ExplorerSplitLayout.defaultTreeWidth
        var renderingMarkdown = false
        // Only kept while the file has edits that are not on disk. A clean file is read
        // again on return, so it shows whatever an agent has written since.
        var unsaved: UnsavedEdit?
    }

    struct UnsavedEdit {
        let path: String
        let preview: FilePreview
        let draft: String
        let original: String
        let loadedAt: Date?
    }

    private var places: [String: Place] = [:]

    func place(for root: String) -> Place? {
        places[root]
    }

    func remember(_ place: Place, for root: String) {
        places[root] = place
    }
}
