import SwiftUI

/// One segment of the breadcrumb path.
struct PathComponent: Identifiable {
    let name: String
    let path: String
    let isRoot: Bool
    let isLast: Bool

    var id: String { path }
}

/// Finder-style path bar: a chevron-separated location trail from the scan
/// root to the current folder. Ancestors are subtle, clickable text that
/// brighten with a soft highlight on hover; the current folder is plain,
/// prominent text. No accent-filled pills — this reads like a native macOS
/// path bar, not a row of buttons. The trail only jumps within the scan;
/// changing location is the sidebar's job.
///
/// It sits at the top of the list, above the column titles, and above
/// search results too, where clicking any segment — the current folder
/// included — leaves search for that folder. (Upstream 3a09ac2.)
///
/// Upstream also collapses the trail into shorter variants when space runs
/// out (ab868c6, building on 368eef2's `ViewThatFits` layout, which the
/// fork did not take). This bar scrolls sideways instead, so it keeps every
/// segment and every size.
struct BreadcrumbBar: View {
    let currentPath: String
    let rootPath: String
    /// Display name of the root segment (device name).
    let rootName: String
    /// Size of the scanned folder at a path, shown after its segment; nil
    /// hides it. (Ported from upstream 01f7a8e.)
    var sizeOfPath: (String) -> Int64? = { _ in nil }
    let onNavigate: (String) -> Void

    /// Segments relative to the scanned root, so external volumes don't
    /// grow phantom "/Volumes" crumbs pointing outside the scan.
    private var pathComponents: [PathComponent] {
        var result = [PathComponent(
            name: rootName, path: rootPath, isRoot: true, isLast: currentPath == rootPath
        )]

        // Synthetic locations ("::Name") aren't under the scan root; show
        // them as a single crumb after the root.
        if currentPath.hasPrefix("::") {
            result.append(PathComponent(
                name: String(currentPath.dropFirst(2)),
                path: currentPath, isRoot: false, isLast: true
            ))
            return result
        }

        let prefix = rootPath.directoryPrefix
        guard currentPath.hasPrefix(prefix) else { return result }

        let components = currentPath.dropFirst(prefix.count).split(separator: "/")
        var accumulatedPath = rootPath
        for (index, component) in components.enumerated() {
            accumulatedPath = accumulatedPath.hasSuffix("/")
                ? accumulatedPath + component
                : accumulatedPath + "/" + component
            result.append(PathComponent(
                name: String(component),
                path: accumulatedPath,
                isRoot: false,
                isLast: index == components.count - 1
            ))
        }
        return result
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(pathComponents) { component in
                    segment(component)

                    if !component.isLast {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        // Keep the whole trail on one line; it scrolls horizontally if deep.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func segment(_ component: PathComponent) -> some View {
        if component.isLast {
            // Current location: prominent text, no hover treatment. Its
            // size is in the window subtitle, so it is not repeated here.
            // (Upstream 3a6951d.) Still clickable — with search up, that
            // is the way back to this folder. (Upstream 3a09ac2.)
            HStack(spacing: 5) {
                Text(component.name)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { onNavigate(component.path) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { onNavigate(component.path) }
        } else {
            let size = sizeOfPath(component.path).map(ByteFormatter.formatFileSize)
            BreadcrumbLink(name: component.name, size: size) { onNavigate(component.path) }
        }
    }
}

/// A segment's folder size: quiet, fixed-width digits that never truncate
/// (the name beside it truncates first).
private struct BreadcrumbSize: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A clickable ancestor crumb: secondary text that brightens under a soft
/// rounded highlight on hover, like a Finder path-bar segment.
private struct BreadcrumbLink: View {
    let name: String
    var size: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(name)
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .lineLimit(1)
                if let size { BreadcrumbSize(text: size) }
            }
            .font(.callout)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                if hovering {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.quaternary)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

#Preview {
    BreadcrumbBar(
        currentPath: "/Volumes/External/Documents/Projects",
        rootPath: "/Volumes/External",
        rootName: "External",
        onNavigate: { _ in }
    )
    .frame(width: 600)
    .padding()
}
