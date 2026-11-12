import SwiftUI
import ClipSlotsKit

/// The popover owns its interaction state so expanding a page does not
/// invalidate the editor grid. Content and selection still come from the store.
struct PageNavigationControl: View {
    @ObservedObject var store: SlotStoreObservable
    var onCreate: () -> Void
    var onRename: (String, String) -> Void
    var onDelete: (String, String) -> Void

    @State private var isPresented = false
    @State private var expandedPageId: String?
    @State private var isMultiSelecting = false
    @State private var selectedPageIds: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Neu.subtleInk)
                Text(store.currentPage?.name ?? "默认页面")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text("\(store.currentPageSlotGroups.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Neu.subtleInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .neuWell(radius: 7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Neu.subtleInk)
            }
            .foregroundColor(Neu.ink)
            .padding(.horizontal, 9)
            .frame(height: NeumorphicMetrics.actionHeight)
            .neuRaised(radius: NeumorphicMetrics.actionRadius)
        }
        .buttonStyle(PageNavigationButtonStyle())
        .fixedSize()
        .accessibilityIdentifier("page-navigation-trigger")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { popover }
    }

    private var popover: some View {
        // Build the page/group lookup once per update rather than filtering
        // the complete group index separately for every visible page row.
        let groupsByPage = Dictionary(grouping: store.specialSlots, by: \.pageId)
        // Disclosure changes the rows inside a stable scroll viewport. Resizing
        // the native popover on every animation tick also relays out its host.
        let largestGroupCount = groupsByPage.values.map(\.count).max() ?? 0
        let listHeight = min(300, max(72, CGFloat(store.pages.count * 39 + largestGroupCount * 33)))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.88))
                        .frame(width: 30, height: 30)
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.invertedOnAccentText)
                }
                Text("页面导航").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    isPresented = false
                    onCreate()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("新建页面")
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(store.pages) { page in
                        let isCurrent = page.id == store.currentPageId
                        let isExpanded = expandedPageId == page.id || (expandedPageId == nil && isCurrent)
                        let isSelected = selectedPageIds.contains(page.id)
                        let groups = groupsByPage[page.id] ?? []
                        Button {
                            if isMultiSelecting {
                                if isSelected { selectedPageIds.remove(page.id) }
                                else { selectedPageIds.insert(page.id) }
                            } else {
                                if !isExpanded { store.switchToPage(id: page.id, fromNavigation: true) }
                                withAnimation(reduceMotion ? nil : Anim.navigationReveal) {
                                    expandedPageId = isExpanded ? "" : page.id
                                }
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: isCurrent ? "folder.fill" : "folder")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 18)
                                Text(page.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(groups.count)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                                if isMultiSelecting {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(isSelected ? .accentColor : .secondary)
                                } else {
                                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10)
                            .frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(isCurrent ? Color.primary.opacity(0.075) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PageNavigationButtonStyle())
                        .accessibilityIdentifier("page-navigation-\(page.id)")

                        if isExpanded && !isMultiSelecting {
                            LazyVStack(spacing: 2) {
                                ForEach(groups) { group in
                                    let isCurrentGroup = group.id == store.currentSpecialSlotId
                                    Button {
                                        store.switchSpecialSlot(id: group.id, fromNavigation: true)
                                        isPresented = false
                                    } label: {
                                        HStack(spacing: 8) {
                                            Rectangle()
                                                .fill(isCurrentGroup ? Color.accentColor : Color.primary.opacity(0.10))
                                                .frame(width: 1, height: 24)
                                            Text(group.name)
                                                .font(.system(size: 11, weight: .medium))
                                                .lineLimit(1)
                                            Spacer()
                                            if isCurrentGroup {
                                                Image(systemName: "chevron.right")
                                                    .font(.system(size: 8, weight: .bold))
                                            }
                                        }
                                        .foregroundColor(isCurrentGroup ? .primary : .secondary)
                                        .padding(.leading, 23)
                                        .padding(.trailing, 11)
                                        .frame(height: 31)
                                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .fill(isCurrentGroup ? Color.primary.opacity(0.07) : Color.clear))
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(PageNavigationButtonStyle())
                                    .accessibilityIdentifier("page-navigation-group-\(group.id)")
                                }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: listHeight)
            Divider()
            HStack(spacing: 10) {
                if isMultiSelecting {
                    Button(role: .destructive) {
                        for id in selectedPageIds { store.deletePage(id: id) }
                        finishSelection()
                    } label: { Label("删除 \(selectedPageIds.count)", systemImage: "trash") }
                    .disabled(selectedPageIds.isEmpty)
                    Button("取消", action: finishSelection)
                } else {
                    if store.pages.count > 1, let page = store.currentPage {
                        Button {
                            isPresented = false
                            onRename(page.id, page.name)
                        } label: { Label("重命名", systemImage: "pencil") }
                        Button(role: .destructive) {
                            isPresented = false
                            onDelete(page.id, page.name)
                        } label: { Label("删除", systemImage: "trash") }
                    }
                    Button {
                        selectedPageIds.removeAll()
                        withAnimation(reduceMotion ? nil : Anim.navigationReveal) { isMultiSelecting = true }
                    } label: { Label("多选", systemImage: "checkmark.circle") }
                }
                Spacer()
                Button {
                    isPresented = false
                    finishSelection()
                } label: { Text("完成").fontWeight(.semibold) }
            }
            .font(.system(size: 10.5))
            .buttonStyle(.borderless)
            .padding(.horizontal, 11)
            .padding(.bottom, 9)
        }
        .frame(width: 252)
    }

    private func finishSelection() {
        selectedPageIds.removeAll()
        withAnimation(reduceMotion ? nil : Anim.navigationReveal) { isMultiSelecting = false }
    }
}

private struct PageNavigationButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(configuration.isPressed || reduceMotion ? nil : Anim.navigationFeedback,
                       value: configuration.isPressed)
    }
}
