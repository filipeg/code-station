import SwiftUI

struct WorkspaceChangesView: View {
    let session: ChatSession
    let initialRoot: String
    let initialPath: String?
    @Environment(ProjectStore.self) private var store
    @Environment(GitStatsCache.self) private var gitStats
    @State private var selectedRoot: String?
    @FocusState private var focusedRoot: String?

    private var roots: [String] {
        let directories = store.workingDirectories(for: session)
        return directories.contains(initialRoot) ? directories : [initialRoot] + directories
    }
    private var selected: String { selectedRoot ?? initialRoot }

    var body: some View {
        VStack(spacing: 0) {
            if roots.count > 1 {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 16) {
                            ForEach(roots, id: \.self) { root in
                                Button { selectedRoot = root } label: {
                                    HStack(spacing: 8) {
                                        ProjectDot(tint: Theme.projectTint(for: name(root)), size: 8)
                                        Text(name(root)).font(.system(size: 13, weight: .semibold))
                                        Text(status(root)).font(.system(size: 11)).foregroundStyle(.secondary)
                                            .padding(5).background(Theme.field, in: RoundedRectangle(cornerRadius: 5))
                                    }
                                    .padding(.vertical, 16)
                                    .overlay(alignment: .bottom) {
                                        if root == selected { Rectangle().fill(Theme.accent).frame(height: 2) }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .focused($focusedRoot, equals: root)
                                .accessibilityAddTraits(root == selected ? .isSelected : [])
                                .onMoveCommand { direction in
                                    guard direction == .left || direction == .right,
                                          let index = roots.firstIndex(of: root) else { return }
                                    let next = min(max(0, index + (direction == .left ? -1 : 1)), roots.count - 1)
                                    selectedRoot = roots[next]
                                    focusedRoot = roots[next]
                                }
                                .id(root)
                            }
                        }.padding(.horizontal, 20)
                    }
                    .onChange(of: selected) { _, root in proxy.scrollTo(root) }
                }.background(Theme.card)
            }
            ZStack {
                ForEach(roots, id: \.self) { root in
                    ChangesView(root: root, initiallySelectedPath: root == initialRoot ? initialPath : nil)
                        .opacity(root == selected ? 1 : 0)
                        .allowsHitTesting(root == selected)
                        .disabled(root != selected)
                        .accessibilityHidden(root != selected)
                }
            }
            if let other = roots.first(where: { $0 != selected && !(gitStats.snapshot(at: $0)?.files.isEmpty ?? true) }) {
                HStack {
                    Text("\(status(other)) changed in \(name(other))").font(.system(size: 12))
                    InlineLink(title: "Review changes") { selectedRoot = other }
                }.padding(10)
            }
        }
    }

    private func name(_ root: String) -> String {
        for checkout in store.checkoutProjects(for: session) {
            if let project = store.project(checkout.projectID), (checkout.worktreePath ?? project.path) == root {
                return project.name
            }
        }
        return (root as NSString).lastPathComponent
    }

    private func status(_ root: String) -> String {
        guard let snapshot = gitStats.snapshot(at: root) else { return "Status unknown" }
        return snapshot.files.isEmpty ? "Clean" : counted(snapshot.files.count, "file")
    }
}
