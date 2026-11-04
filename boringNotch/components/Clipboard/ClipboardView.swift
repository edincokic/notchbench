//
//  ClipboardView.swift
//  boringNotch
//
//  The Clipboard tab: a scrollable row of recently copied items.
//  Click an item to copy it again, then paste with ⌘V.
//

import AppKit
import SwiftUI

struct ClipboardView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var manager = ClipboardHistoryManager.shared

    var body: some View {
        HStack(spacing: 12) {
            sidebar
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10]))
                .overlay {
                    if manager.items.isEmpty {
                        emptyState
                    } else {
                        list
                    }
                }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 22))
                .foregroundStyle(.white)
            Text("\(manager.items.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text(manager.items.count == 1 ? "item" : "items")
                .font(.system(size: 10))
                .foregroundStyle(.gray)
            Spacer(minLength: 0)
            Button {
                withAnimation(.smooth) { manager.clearUnpinned() }
            } label: {
                Text("Clear")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .disabled(!manager.items.contains { !$0.isPinned })
            .opacity(manager.items.contains { !$0.isPinned } ? 1 : 0.4)
            .help("Remove everything except pinned items")
        }
        .frame(width: 70)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clipboard")
                .font(.system(size: 26))
                .foregroundStyle(.gray)
            Text("Nothing copied yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            Text("Copy text, links, images or files and they'll show up here.")
                .font(.system(size: 11))
                .foregroundStyle(.gray)
        }
        .multilineTextAlignment(.center)
        .padding()
    }

    private var list: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(manager.items) { item in
                    ClipboardItemCard(item: item)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(10)
            .animation(.smooth, value: manager.items)
        }
    }
}

struct ClipboardItemCard: View {
    let item: ClipboardItem
    @ObservedObject var manager = ClipboardHistoryManager.shared
    @State private var isHovering = false

    private var justCopied: Bool { manager.lastCopiedID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(8)
        .frame(width: 140)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isHovering ? 0.14 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(item.isPinned ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 1.5)
        )
        .overlay(alignment: .topTrailing) { hoverButtons }
        .overlay { copiedBadge }
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { isHovering = $0 }
        .onTapGesture { manager.copy(item) }
        .contextMenu { menu }
        .help("Click to copy")
    }

    @ViewBuilder
    private var preview: some View {
        switch item.kind {
        case .text:
            Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .lineLimit(5)
        case .link:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .underline()
                    .lineLimit(4)
            }
        case .image:
            if let image = manager.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 22))
                    .foregroundStyle(.gray)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            let urls = item.fileURLs
            HStack(spacing: 6) {
                if let first = urls.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                        .resizable()
                        .frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(urls.first?.lastPathComponent ?? "File")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if urls.count > 1 {
                        Text("+\(urls.count - 1) more")
                            .font(.system(size: 10))
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if let bundleID = item.sourceBundleID,
               let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 12, height: 12)
            }
            Text(relativeTime(item.date))
                .font(.system(size: 9))
                .foregroundStyle(.gray)
                .lineLimit(1)
            Spacer(minLength: 0)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    @ViewBuilder
    private var hoverButtons: some View {
        if isHovering && !justCopied {
            HStack(spacing: 4) {
                smallButton(icon: item.isPinned ? "pin.slash.fill" : "pin.fill",
                            help: item.isPinned ? "Unpin" : "Pin") {
                    manager.togglePin(item)
                }
                smallButton(icon: "xmark", help: "Remove") {
                    withAnimation(.smooth) { manager.remove(item) }
                }
            }
            .padding(5)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var copiedBadge: some View {
        if justCopied {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.7))
                .overlay {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.green)
                        Text("Copied")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy") { manager.copy(item) }
        Button(item.isPinned ? "Unpin" : "Pin") { manager.togglePin(item) }
        if item.kind == .link,
           let url = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .file, !item.fileURLs.isEmpty {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
        }
        Divider()
        Button("Remove", role: .destructive) { manager.remove(item) }
    }

    private func smallButton(icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.black.opacity(0.75)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func relativeTime(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
