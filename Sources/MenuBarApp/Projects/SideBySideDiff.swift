import SwiftUI

struct DiffComparisonRow: Identifiable {
    let id: Int
    var left: DiffLine?
    var right: DiffLine?
    var oldNumber: Int?
    var newNumber: Int?

    static func align(_ lines: [DiffLine]) -> [Self] {
        var rows: [Self] = []
        var old = 1
        var new = 1
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.kind == .deletion || line.kind == .addition {
                var removed: [DiffLine] = []
                var added: [DiffLine] = []
                while index < lines.count && (lines[index].kind == .deletion || lines[index].kind == .addition) {
                    if lines[index].kind == .deletion { removed.append(lines[index]) }
                    else { added.append(lines[index]) }
                    index += 1
                }
                for offset in 0..<max(removed.count, added.count) {
                    let left = offset < removed.count ? removed[offset] : nil
                    let right = offset < added.count ? added[offset] : nil
                    rows.append(Self(id: rows.count, left: left, right: right,
                                     oldNumber: left == nil ? nil : old, newNumber: right == nil ? nil : new))
                    if left != nil { old += 1 }
                    if right != nil { new += 1 }
                }
                continue
            }
            if line.kind == .hunk {
                let parts = line.text.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? old
                    new = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? new
                }
            }
            if line.kind == .gap, let gap = line.gap {
                old += gap.count ?? 0
                new = gap.start + (gap.count ?? 0)
            }
            let numbered = line.kind == .context
            rows.append(Self(id: rows.count, left: line, right: line,
                             oldNumber: numbered ? old : nil, newNumber: numbered ? new : nil))
            if numbered { old += 1; new += 1 }
            index += 1
        }
        return rows
    }
}

struct SideBySideDiff: View {
    let lines: [DiffLine]
    let expand: (String, DiffExpandDirection) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 0) {
                    ForEach(DiffComparisonRow.align(lines)) { row in
                        if let gap = row.left?.gap {
                            HStack {
                                ForEach([DiffExpandDirection.up, .all, .down], id: \.self) { direction in
                                    Button("Show context \(direction.rawValue)") { expand(gap.key, direction) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .font(.system(size: 11)).padding(8)
                        } else if row.left?.kind == .hunk || row.left?.kind == .meta || row.left?.kind == .section {
                            Text(row.left?.text ?? "").font(.mono(11))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                                .background(Theme.field)
                        } else {
                            HStack(alignment: .top, spacing: 0) {
                                cell(row.left, number: row.oldNumber)
                                cell(row.right, number: row.newNumber)
                            }
                        }
                    }
                }
                .frame(width: max(760, geometry.size.width))
            }
        }
    }

    private func cell(_ line: DiffLine?, number: Int?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(number.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            Text(line.map { String($0.text.prefix(1)) } ?? "").frame(width: 10)
            Text(line.map { String($0.text.dropFirst()) } ?? " ")
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.mono(12)).padding(.vertical, 3).padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if line == nil {
                Canvas { context, size in
                    var stripes = Path()
                    for x in stride(from: -size.height, to: size.width, by: 8) {
                        stripes.move(to: CGPoint(x: x, y: 0))
                        stripes.addLine(to: CGPoint(x: x + size.height, y: size.height))
                    }
                    context.stroke(stripes, with: .color(Theme.border), lineWidth: 3)
                }.background(Theme.field).clipped()
            }
        }
        .background(line?.kind == .addition ? Theme.addition.opacity(0.12) :
                    line?.kind == .deletion ? Theme.deletion.opacity(0.12) : line == nil ? Theme.field : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
        .accessibilityLabel(line == nil ? "No corresponding line" : line!.text)
    }
}
