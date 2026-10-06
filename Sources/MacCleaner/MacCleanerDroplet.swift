//
//  MacCleanerDroplet.swift
//  MacCleaner
//
//  A Droppy droplet that scans safe Mac cleanup targets — caches, logs,
//  Xcode leftovers, app leftovers, other caches and the Trash — and lets
//  the user pick exactly what goes. Everything removed goes to the Trash
//  by default; emptying the Trash itself is the one permanent action and
//  is always opt-in.

import AppKit
import Combine
import DroppyKit
import Foundation
import SwiftUI

/// The class Droppy's loader instantiates, named in the bundle's
/// `NSPrincipalClass`. Keep it empty: it runs before the host is ready.
@objc(MacCleanerPrincipal)
public final class MacCleanerPrincipal: NSObject, DropletPrincipal {
    public override init() { super.init() }

    @MainActor public func makeDroplet() -> AnyObject { MacCleanerDroplet() }
}

// MARK: - Model

/// One cleanup category, matching the review-first cleaner UX.
enum CleanerCategoryID: String, CaseIterable, Identifiable {
    case caches
    case logs
    case developer
    case leftovers
    case otherCaches
    case trash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .caches: return "Caches"
        case .logs: return "Logs"
        case .developer: return "Developer junk"
        case .leftovers: return "Leftovers from uninstalled apps"
        case .otherCaches: return "Other caches"
        case .trash: return "Trash"
        }
    }

    var subtitle: String {
        switch self {
        case .caches: return "Temporary files apps rebuild on their own."
        case .logs: return "Old diagnostic logs."
        case .developer: return "Xcode build and simulator leftovers."
        case .leftovers: return "Files left behind by apps you uninstalled."
        case .otherCaches: return "Safe to remove, nothing breaks. Apps may open slower once."
        case .trash: return "Emptying the Trash is permanent."
        }
    }

    var systemImage: String {
        switch self {
        case .caches: return "archivebox"
        case .logs: return "doc.text"
        case .developer: return "hammer"
        case .leftovers: return "puzzlepiece"
        case .otherCaches: return "internaldrive"
        case .trash: return "trash"
        }
    }

    /// Safe categories are on by default; the rest are review-first.
    var isSafe: Bool {
        switch self {
        case .caches, .logs, .developer: return true
        case .leftovers, .otherCaches, .trash: return false
        }
    }
}

/// One file or folder found by the scan.
struct CleanerItem: Identifiable, Hashable {
    let id: String  // absolute path
    let name: String
    let path: String
    let size: Int64
    let category: CleanerCategoryID
    /// When true this item deletes permanently (Trash contents).
    /// Everything else is trashed so it can be restored.
    let isPermanent: Bool
}

/// One category with its scanned items.
struct CleanerCategoryResult: Identifiable {
    let id: CleanerCategoryID
    var items: [CleanerItem]

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

enum CleanerPhase: Equatable {
    case idle
    case scanning
    case results
    case cleaning
}

// MARK: - Size helpers

enum CleanerFormat {
    static func string(_ size: Int64) -> String {
        if size <= 0 { return "—" }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: size)
    }
}

/// Synchronous, bounded directory-size walk. Skips packages descended
/// too deep and caps file count so a huge cache can't stall the shelf.
/// Counts regular files too, so a folder with nothing in it (no files at
/// all, even counting nested subfolders) reads as empty and is skipped.
enum CleanerScanner {
    static let maxFilesPerRoot = 4000
    static let maxItemsPerCategory = 60

    static func sizeAndCount(of url: URL, budget: inout Int) -> (size: Int64, files: Int) {
        var total: Int64 = 0
        var count = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0, 0)
        }
        while let file = enumerator.nextObject() as? URL {
            if budget <= 0 { break }
            budget -= 1
            guard let vals = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]) else { continue }
            if vals.isSymbolicLink == true {
                // Never follow links: a linked folder would count (and
                // clean!) data that lives outside the scanned cache.
                enumerator.skipDescendants()
                continue
            }
            guard vals.isRegularFile == true else { continue }
            // VM disks and disk images are never caches, no matter where
            // they sit. One Docker.raw can "find" 200+ GB on its own.
            if skippedExtensions.contains(file.pathExtension.lowercased()) { continue }
            count += 1
            total += Int64(vals.fileSize ?? 0)
        }
        return (total, count)
    }

    /// Extensions that are never cleanable data, wherever they are found.
    static let skippedExtensions: Set<String> = [
        "raw", "vmdk", "vhd", "vhdx", "vdi", "qcow2", "sparseimage", "sparsebundle"
    ]

    static func children(of root: URL, category: CleanerCategoryID, isPermanent: Bool) -> [CleanerItem] {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [CleanerItem] = []
        var budget = maxFilesPerRoot
        for kid in kids {
            // A top-level link is not the cache's own data; leave it alone.
            if (try? kid.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { continue }
            let size: Int64
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: kid.path, isDirectory: &isDir)
            if isDir.boolValue {
                let measured = sizeAndCount(of: kid, budget: &budget)
                if measured.files == 0 { continue }  // just a folder, nothing in it
                size = measured.size
            } else {
                size = (try? fm.attributesOfItem(atPath: kid.path)[.size] as? Int64) ?? 0
            }
            if size <= 0 { continue }
            out.append(CleanerItem(
                id: kid.path,
                name: kid.lastPathComponent,
                path: kid.path,
                size: size,
                category: category,
                isPermanent: isPermanent
            ))
        }
        return out.sorted { $0.size > $1.size }.prefix(maxItemsPerCategory).map { $0 }
    }
}

// MARK: - Droplet

/// Scans safe cleanup targets and cleans only what the user picked.
@MainActor
public final class MacCleanerDroplet: NSObject, ObservableObject, Droplet {
    /// Must equal `DroppyDropletID` in the bundle's Info.plist and `id` in
    /// droplet.json. The loader refuses the bundle if the three disagree.
    public nonisolated static let id: DropletID = "mac-cleaner"

    private var host: DropletHost?
    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?

    @Published var phase: CleanerPhase = .idle
    @Published var categories: [CleanerCategoryResult] = []
    @Published var selectedIDs: Set<String> = []
    @Published var lastCleanedBytes: Int64 = 0
    @Published var lastCleanedDate: Date?
    /// True once a scan has completed. Tells the "never scanned" intro
    /// apart from "scanned and found nothing", which gets its own message.
    @Published var hasScanned = false

    var totalFound: Int64 { categories.reduce(0) { $0 + $1.totalSize } }
    var selectedBytes: Int64 {
        categories.flatMap(\.items).filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    var selectedCount: Int { selectedIDs.count }
    var totalCount: Int { categories.reduce(0) { $0 + $1.items.count } }

    // MARK: Lifecycle

    public func activate(host: DropletHost) throws {
        self.host = host
        host.log.info("Mac Cleaner activated")
        lastCleanedBytes = host.preferences.value(forKey: "lastCleanedBytes", default: 0 as Int64)
    }

    public func deactivate() {
        scanTask?.cancel()
        cleanTask?.cancel()
        scanTask = nil
        cleanTask = nil
        host = nil
    }

    // MARK: Preferences

    func isCategoryEnabled(_ id: CleanerCategoryID) -> Bool {
        guard let host else { return true }
        return host.preferences.value(forKey: "cat.\(id.rawValue)", default: true)
    }

    func setCategoryEnabled(_ id: CleanerCategoryID, _ enabled: Bool) {
        host?.preferences.setValue(enabled, forKey: "cat.\(id.rawValue)")
    }

    var moveToTrash: Bool {
        host?.preferences.value(forKey: "moveToTrash", default: true) ?? true
    }

    var moveToTrashBinding: Binding<Bool> {
        Binding(
            get: { self.moveToTrash },
            set: { self.host?.preferences.setValue($0, forKey: "moveToTrash") }
        )
    }

    func binding(for category: CleanerCategoryID) -> Binding<Bool> {
        Binding(
            get: { self.isCategoryEnabled(category) },
            set: { self.setCategoryEnabled(category, $0) }
        )
    }

    // MARK: Scan

    /// What the shelf widget's Scan button does.
    public func scan() {
        guard phase != .scanning && phase != .cleaning else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runScan()
        }
    }

    public func cancelScan() {
        scanTask?.cancel()
        if phase == .scanning { phase = categories.isEmpty ? .idle : .results }
    }

    private func runScan() async {
        phase = .scanning
        categories = []
        selectedIDs = []
        host?.shelf.setHoldsOpen(true)

        if host?.environment.isHarness == true {
            // Demo data for the harness shots: stable, fast, no disk access.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { phase = .idle; host?.shelf.setHoldsOpen(false); return }
            categories = Self.demoResults()
        } else {
            categories = await Task.detached(priority: .utility) {
                Self.scanFileSystem()
            }.value
        }

        if Task.isCancelled {
            phase = categories.isEmpty ? .idle : .results
            host?.shelf.setHoldsOpen(false)
            return
        }

        // Pre-select: everything found, including Trash, EXCEPT very
        // large single items. A runaway cache (a 200 GB npm cache, a
        // giant mailbox) is still listed and still cleanable, but it is
        // never one tap away from deletion without an explicit tick:
        // "Clean 246 GB" preselected is how a cleaner looks like it is
        // about to wipe the disk.
        var pre: Set<String> = []
        for cat in categories {
            for item in cat.items where item.size <= Self.autoSelectMaxSize {
                pre.insert(item.id)
            }
        }
        selectedIDs = pre
        phase = .results
        hasScanned = true
        host?.shelf.setHoldsOpen(false)
        if categories.isEmpty {
            host?.log.info("Mac Cleaner scan found nothing to clean")
            presentNote("Nothing to clean — your Mac is tidy")
        } else {
            host?.log.info("Mac Cleaner scan found \(CleanerFormat.string(totalFound)) in \(totalCount) items")
        }
    }

    // MARK: Selection (the "choose" feature)

    func isCategorySelected(_ id: CleanerCategoryID) -> Bool {
        guard let cat = categories.first(where: { $0.id == id }), !cat.items.isEmpty else { return false }
        return cat.items.allSatisfy { selectedIDs.contains($0.id) }
    }

    func toggleCategory(_ id: CleanerCategoryID) {
        guard let cat = categories.first(where: { $0.id == id }) else { return }
        if isCategorySelected(id) {
            for item in cat.items { selectedIDs.remove(item.id) }
        } else {
            // Trash needs an explicit per-item opt-in gesture in the
            // expanded view; the category toggle still works there.
            for item in cat.items { selectedIDs.insert(item.id) }
        }
    }

    func toggleItem(_ item: CleanerItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    func selectSafe() {
        var next: Set<String> = []
        for cat in categories where cat.id.isSafe {
            for item in cat.items { next.insert(item.id) }
        }
        selectedIDs = next
    }

    func selectNone() {
        selectedIDs = []
    }

    // MARK: Clean

    /// What the Clean button does: trash (or delete) only selected items.
    /// Never silent: an empty selection gets a message, not nothing.
    public func cleanSelected() {
        guard phase == .results else { return }
        guard !selectedIDs.isEmpty else {
            presentNote("Nothing selected — tick what to remove first")
            return
        }
        cleanTask?.cancel()
        cleanTask = Task { [weak self] in
            guard let self else { return }
            await self.runClean()
        }
    }

    private func runClean() async {
        let targets = categories.flatMap(\.items).filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        phase = .cleaning
        host?.shelf.setHoldsOpen(true)

        let trashInsteadOfDelete = moveToTrash
        var freed: Int64 = 0
        var removedPaths: Set<String> = []
        // Items that vanished or changed between scan and clean (caches
        // churn constantly) vs items that failed for another reason.
        var stalePaths: Set<String> = []
        var failedCount = 0

        for item in targets {
            if Task.isCancelled { break }
            let url = URL(fileURLWithPath: item.path)
            guard FileManager.default.fileExists(atPath: item.path) else {
                host?.log.info("Mac Cleaner item already gone: \(item.path)")
                stalePaths.insert(item.id)
                continue
            }
            let ok: Bool
            if item.category == .trash || !trashInsteadOfDelete {
                // Permanent: only for Trash contents, or when the user
                // switched off "move to Trash" in settings.
                do {
                    try FileManager.default.removeItem(at: url)
                    ok = true
                } catch {
                    host?.log.error("Mac Cleaner could not remove \(item.path): \(error.localizedDescription)")
                    ok = false
                }
            } else {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    ok = true
                } catch {
                    host?.log.error("Mac Cleaner could not trash \(item.path): \(error.localizedDescription)")
                    ok = false
                }
            }
            if ok {
                freed += item.size
                removedPaths.insert(item.id)
            } else {
                failedCount += 1
            }
        }

        // Drop cleaned AND vanished items from the results: a rescan
        // would not find them either, so the list stays truthful.
        let gone = removedPaths.union(stalePaths)
        categories = categories.map { cat in
            var c = cat
            c.items.removeAll { gone.contains($0.id) }
            return c
        }.filter { !$0.items.isEmpty }
        selectedIDs.subtract(gone)

        lastCleanedBytes += freed
        lastCleanedDate = Date()
        host?.preferences.setValue(lastCleanedBytes, forKey: "lastCleanedBytes")

        phase = .results
        host?.shelf.setHoldsOpen(false)
        if freed > 0 && stalePaths.isEmpty && failedCount == 0 {
            host?.feedback.play(.success)
            host?.log.notice("Mac Cleaner freed \(CleanerFormat.string(freed))")
            presentDoneHUD(freed: freed)
        } else if freed > 0 {
            // Partial: something changed under us mid-clean.
            host?.feedback.play(.success)
            host?.log.notice("Mac Cleaner freed \(CleanerFormat.string(freed)); \(stalePaths.count + failedCount) items changed, rescan to refresh")
            presentNote("Freed \(CleanerFormat.string(freed)) — rescan to refresh")
        } else if !stalePaths.isEmpty {
            host?.log.notice("Mac Cleaner found only stale items; asking for a rescan")
            presentNote("Already gone — rescan to refresh")
        } else if failedCount > 0 {
            host?.feedback.play(.failure)
            presentNote("Couldn't clean — rescan and try again")
        } else {
            presentDoneHUD(freed: freed)
        }
    }

    private func presentDoneHUD(freed: Int64) {
        let text = freed > 0 ? "Freed \(CleanerFormat.string(freed))" : "Nothing to clean"
        presentNote(text)
    }

    /// A short message on the notch: completions, tidy scans, and the
    /// nothing-selected nudge. One shared id so notes replace each other.
    private func presentNote(_ text: String) {
        guard let host else { return }
        let request = DropletHUDRequest(
            id: "mac-cleaner.done",
            duration: 3.0,
            priority: .high,
            accessibilityLabel: text
        ) {
            HStack(spacing: 0) {
                Image(systemName: "sparkles")
                    .font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
                Spacer(minLength: 0)
                Text(verbatim: text)
                    .font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
        }
        _ = host.hud.present(request)
    }

    /// Close the review UI and go back to the shelf.
    func closeReview() {
        host?.notchSurface.dismissExpandedSurface("cleaner-detail")
    }

    /// Open the full review UI.
    func openReview() {
        guard let host else { return }
        if host.isGranted(.expandedSurface) {
            let presentation = host.notchSurface.presentExpandedSurface(
                ExpandedSurfacePresentationRequest(surfaceID: "cleaner-detail", opensShelf: true)
            )
            if presentation != nil { return }
            host.log.error("Mac Cleaner review surface was refused, falling back to the shelf widget")
        }
        _ = host.shelf.open(revealing: "cleaner")
    }

    // MARK: Real filesystem scan (read-only)

    /// Items bigger than this are listed but never pre-selected: they
    /// need an explicit tick no matter the defaults.
    nonisolated static let autoSelectMaxSize: Int64 = 2 * 1024 * 1024 * 1024

    nonisolated static func scanFileSystem() -> [CleanerCategoryResult] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var out: [CleanerCategoryResult] = []

        func items(at relative: String, category: CleanerCategoryID, permanent: Bool = false) -> [CleanerItem] {
            let root = home.appendingPathComponent(relative, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else { return [] }
            if category == .trash {
                return CleanerScanner.children(of: root, category: category, isPermanent: true)
            }
            return CleanerScanner.children(of: root, category: category, isPermanent: permanent)
        }

        let caches = items(at: "Library/Caches", category: .caches)
        if !caches.isEmpty { out.append(CleanerCategoryResult(id: .caches, items: caches)) }

        var logs = items(at: "Library/Logs", category: .logs)
        logs += items(at: "Library/Containers/com.apple.mail/Data/Library/Logs", category: .logs)
        if !logs.isEmpty { out.append(CleanerCategoryResult(id: .logs, items: Array(logs.prefix(60)))) }

        var dev: [CleanerItem] = []
        dev += items(at: "Library/Developer/Xcode/DerivedData", category: .developer)
        dev += items(at: "Library/Developer/Xcode/Archives", category: .developer)
        dev += items(at: "Library/Developer/CoreSimulator/Caches", category: .developer)
        if !dev.isEmpty { out.append(CleanerCategoryResult(id: .developer, items: Array(dev.prefix(60)))) }

        let leftovers = scanLeftovers(home: home)
        if !leftovers.isEmpty { out.append(CleanerCategoryResult(id: .leftovers, items: leftovers)) }

        var other: [CleanerItem] = []
        other += items(at: ".npm/_cacache", category: .otherCaches)
        other += items(at: "Library/Application Support/Code/CachedData", category: .otherCaches)
        // Note: Docker's VM disk (Containers/com.docker.docker/Data/vms)
        // is deliberately NOT scanned: it is a virtual machine disk, not
        // a cache, and deleting it breaks every container.
        // Browser caches (per-profile folders can be large).
        for rel in ["Library/Caches/Google/Chrome", "Library/Caches/Firefox", "Library/Caches/com.apple.Safari"] {
            other += items(at: rel, category: .otherCaches)
        }
        if !other.isEmpty { out.append(CleanerCategoryResult(id: .otherCaches, items: Array(other.prefix(60)))) }

        let trash = items(at: ".Trash", category: .trash)
        if !trash.isEmpty { out.append(CleanerCategoryResult(id: .trash, items: trash)) }

        return out
    }

    /// Heuristic: folders in Application Support whose app bundle is gone.
    nonisolated static func scanLeftovers(home: URL) -> [CleanerItem] {
        let fm = FileManager.default
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        guard let kids = try? fm.contentsOfDirectory(
            at: support, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        let appDirs: Set<String>
        if let apps = try? fm.contentsOfDirectory(atPath: "/Applications") {
            appDirs = Set(apps.map { $0.lowercased().replacingOccurrences(of: ".app", with: "") })
        } else {
            appDirs = []
        }
        var out: [CleanerItem] = []
        var budget = 2000
        for kid in kids.prefix(120) {
            let name = kid.lastPathComponent.lowercased()
            // Skip Apple / system support dirs to avoid false positives.
            if name.hasPrefix("com.apple.") || name.hasPrefix("apple ") { continue }
            let stem = name.replacingOccurrences(of: ".", with: " ")
            let looksInstalled = appDirs.contains { $0.contains(name) || name.contains($0) || $0.contains(stem) }
            if looksInstalled { continue }
            var isDir: ObjCBool = false
            _ = fm.fileExists(atPath: kid.path, isDirectory: &isDir)
            let size: Int64
            if isDir.boolValue {
                let measured = CleanerScanner.sizeAndCount(of: kid, budget: &budget)
                if measured.files == 0 { continue }  // just a folder, nothing in it
                size = measured.size
            } else {
                size = (try? fm.attributesOfItem(atPath: kid.path)[.size] as? Int64) ?? 0
            }
            if size < 16 * 1024 { continue }  // ignore tiny leftovers
            out.append(CleanerItem(id: kid.path, name: kid.lastPathComponent, path: kid.path, size: size, category: .leftovers, isPermanent: false))
        }
        return out.sorted { $0.size > $1.size }.prefix(30).map { $0 }
    }

    nonisolated static func demoResults() -> [CleanerCategoryResult] {
        func item(_ cat: CleanerCategoryID, _ name: String, _ mb: Int64, permanent: Bool = false) -> CleanerItem {
            CleanerItem(id: "/demo/\(cat.rawValue)/\(name)", name: name, path: "/demo/\(cat.rawValue)/\(name)", size: mb * 1024 * 1024, category: cat, isPermanent: permanent)
        }
        return [
            CleanerCategoryResult(id: .caches, items: [
                item(.caches, "com.apple.Safari", 412),
                item(.caches, "com.spotify.client", 268),
                item(.caches, "com.apple.Photos", 194),
            ]),
            CleanerCategoryResult(id: .logs, items: [
                item(.logs, "DiagnosticReports", 1),
            ]),
            CleanerCategoryResult(id: .developer, items: [
                item(.developer, "DerivedData", 198),
                item(.developer, "CoreSimulator", 12),
            ]),
            CleanerCategoryResult(id: .leftovers, items: [
                item(.leftovers, "OldVPNHelper", 0 + 16),
            ]),
            CleanerCategoryResult(id: .otherCaches, items: [
                item(.otherCaches, "Chrome Profile Cache", 257),
            ]),
            CleanerCategoryResult(id: .trash, items: [
                item(.trash, "Screen Recording.mov", 3440, permanent: true),
            ]),
        ]
    }
}

// MARK: - Shelf widget

extension MacCleanerDroplet: ShelfWidgetProviding {
    public var widgetDescriptors: [ShelfWidgetDescriptor] {
        [
            ShelfWidgetDescriptor(
                id: "cleaner",
                title: "Cleaner",
                systemImage: "sparkles",
                layoutTraits: ShelfWidgetLayoutTraits(
                    preferredSoloWidth: 420,
                    preferredPairedWidth: 210,
                    contentHeight: .fixed(190)
                ),
                searchKeywords: ["clean", "cache", "trash", "storage", "disk"]
            )
        ]
    }

    public func makeWidgetView(_ id: ShelfWidgetID, context: ShelfWidgetContext) -> AnyView {
        AnyView(MacCleanerWidget(droplet: self, context: context))
    }

    public func makeWidgetSettingsPopover(_ id: ShelfWidgetID) -> AnyView? { nil }
}

private struct MacCleanerWidget: View {
    @ObservedObject var droplet: MacCleanerDroplet
    let context: ShelfWidgetContext

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(spacing: DroppySpacing.xsm) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                Text("Cleaner")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text(verbatim: totalText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .accessibilityLabel("Found \(totalText)")
            }
            .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)

            if context.isCompact {
                compactBody
            } else {
                fullBody
            }

            Spacer(minLength: 0)
        }
        .padding(context.contentInsets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var totalText: String {
        let found = droplet.totalFound
        return found > 0 ? CleanerFormat.string(found) + " found" : "Clean up your Mac"
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            Text(verbatim: droplet.selectedBytes > 0 ? CleanerFormat.string(droplet.selectedBytes) : "Scan first")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            scanButton(small: true)
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if droplet.phase == .scanning {
                scanningHint(text: "Scanning…", action: { droplet.cancelScan() }, label: "Cancel")
            } else if droplet.phase == .cleaning {
                HStack(spacing: DroppySpacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                    Text("Cleaning…")
                        .font(.system(size: 13))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
            } else if droplet.categories.isEmpty {
                if droplet.hasScanned {
                    Text("Nothing to clean — your Mac is tidy.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    scanButton(small: false)
                } else {
                    Text("Scans for leftovers from uninstalled apps, caches, logs and the Trash. You review everything first.")
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(3)
                    scanButton(small: false)
                }
            } else {
                Text("Scans for leftovers from uninstalled apps, caches, logs and the Trash. You review everything first.")
                    .font(.system(size: 12))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .lineLimit(3)
                HStack(spacing: DroppySpacing.sm) {
                    scanButton(small: false)
                    Button("Review") { droplet.openReview() }
                        .buttonStyle(DroppyQuietButtonStyle(size: .small))
                    Spacer(minLength: 0)
                    Text(verbatim: "\(droplet.selectedCount) of \(droplet.totalCount) selected")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
                if droplet.selectedBytes > 0 {
                    Button("Clean \(CleanerFormat.string(droplet.selectedBytes))") {
                        droplet.cleanSelected()
                    }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
                    .disabled(droplet.phase != .results)
                } else {
                    Text("Nothing selected — open Review to choose what goes.")
                        .font(.system(size: 11))
                        .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                }
            }
        }
    }

    private func scanningHint(text: String, action: @escaping () -> Void, label: String) -> some View {
        HStack(spacing: DroppySpacing.sm) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: 0)
            Button(label) { action() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }

    private func scanButton(small: Bool) -> some View {
        Button(droplet.categories.isEmpty ? "Scan" : "Rescan") {
            droplet.scan()
        }
        .buttonStyle(DroppyAccentButtonStyle(size: .small))
        .disabled(droplet.phase == .scanning || droplet.phase == .cleaning)
        .accessibilityLabel("Scan for cleanable files")
        .opacity(small ? 1 : 1)
    }
}

// MARK: - Expanded surface (review & choose)

// Droppy discovers takeover providers through `ExpandedSurfaceHosting`;
// the harness reads `ExpandedSurfaceProviding` directly. Conforming to
// both is how the review surface appears in each host.
extension MacCleanerDroplet: ExpandedSurfaceHosting {
    public var expandedSurfaceProvider: (any ExpandedSurfaceProviding)? { self }
}

extension MacCleanerDroplet: ExpandedSurfaceProviding {
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        [
            ExpandedSurfaceDescriptor(
                id: "cleaner-detail",
                title: "Cleaner",
                systemImage: "sparkles",
                suppresses: [.shelfWidgets, .autoCollapse]
            )
        ]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        AnyView(MacCleanerDetail(droplet: self))
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        // Content area; the host adds shelf chrome around it.
        let height = min(proposal.maximumSize.height, max(380, CGFloat(160 + categories.count * 74)))
        return CGSize(width: proposal.standardSize.width, height: height)
    }

    public func expandedSurfaceDidDismiss(
        _ id: ExpandedSurfaceID,
        presentation: ExpandedSurfacePresentation,
        reason: ExpandedSurfaceDismissalReason
    ) {
        host?.log.debug("Cleaner detail dismissed: \(reason)")
    }
}

private struct MacCleanerDetail: View {
    @ObservedObject var droplet: MacCleanerDroplet
    @State private var expanded: Set<String> = []

    private var safeCats: [CleanerCategoryResult] {
        droplet.categories.filter { $0.id.isSafe }
    }

    private var optionalCats: [CleanerCategoryResult] {
        droplet.categories.filter { !$0.id.isSafe }
    }

    private var hasLargeItems: Bool {
        droplet.categories.flatMap(\.items).contains { $0.size > MacCleanerDroplet.autoSelectMaxSize }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            header
            if hasLargeItems {
                Text("Very large items are left unticked — tick them yourself to include them.")
                    .font(.system(size: 11))
                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
            }
            if droplet.phase == .scanning {
                scanningRow
            } else if droplet.categories.isEmpty {
                emptyRow
            } else {
                list
            }
            footer
        }
        .padding(DroppySpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: DroppySpacing.xsm) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))
            Text("Cleaner")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            Text(verbatim: droplet.totalFound > 0 ? CleanerFormat.string(droplet.totalFound) + " found" : "")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Button {
                droplet.closeReview()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(DroppyCircleButtonStyle(size: 20))
            .help("Back")
            .accessibilityLabel("Back to the shelf")
        }
        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
    }

    private var scanningRow: some View {
        HStack(spacing: DroppySpacing.sm) {
            ProgressView().controlSize(.small).tint(.white)
            Text("Scanning caches, logs and Trash…")
                .font(.system(size: 13))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: 0)
            Button("Cancel") { droplet.cancelScan() }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
        }
    }

    private var emptyRow: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            if droplet.hasScanned {
                Text("Nothing to clean")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text("Your Mac is already tidy. Scan again any time.")
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Button("Rescan") { droplet.scan() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            } else {
                Text("Clean up your Mac")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                Text("Scans for leftovers from uninstalled apps, caches, logs and the Trash. You review everything first and removed items go to the Trash.")
                    .font(.system(size: 13))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                Button("Scan") { droplet.scan() }
                    .buttonStyle(DroppyAccentButtonStyle(size: .small))
            }
        }
        .padding(.vertical, DroppySpacing.sm)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: DroppySpacing.md) {
                if !safeCats.isEmpty {
                    Text("Safe cleanup")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    ForEach(safeCats) { cat in
                        categoryRow(cat)
                    }
                }
                if !optionalCats.isEmpty {
                    Text("Optional, review first")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                        .padding(.top, DroppySpacing.xsm)
                    ForEach(optionalCats) { cat in
                        categoryRow(cat)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 320)
    }

    private func categoryRow(_ cat: CleanerCategoryResult) -> some View {
        VStack(alignment: .leading, spacing: DroppySpacing.xsm) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                Toggle("", isOn: Binding(
                    get: { droplet.isCategorySelected(cat.id) },
                    set: { _ in droplet.toggleCategory(cat.id) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Select all in \(cat.id.title)")

                Image(systemName: cat.id.systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.id.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Text(cat.id.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        .lineLimit(3)
                    if cat.id == .trash {
                        Text("Permanent — does not go to the Trash.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                    // Top items with individual checkboxes: the "choose" feature.
                    // Each row shows its full path underneath: a bare hash
                    // for a name ("110a…6b419") tells nobody what would be
                    // removed, and a cleaner must never ask for trust it
                    // does not earn with specifics.
                    ForEach(cat.items.prefix(5)) { item in
                        HStack(spacing: DroppySpacing.xsm) {
                            Toggle("", isOn: Binding(
                                get: { droplet.selectedIDs.contains(item.id) },
                                set: { _ in droplet.toggleItem(item) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(verbatim: item.name)
                                    .font(.system(size: 12))
                                    .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(verbatim: item.path)
                                    .font(.system(size: 10))
                                    .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(item.path)
                            }
                            Spacer(minLength: DroppySpacing.sm)
                            Text(verbatim: CleanerFormat.string(item.size))
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                        }
                    }
                    if cat.items.count > 5 {
                        Text("+\(cat.items.count - 5) more totalling \(CleanerFormat.string(cat.items.dropFirst(5).reduce(0) { $0 + $1.size }))")
                            .font(.system(size: 11))
                            .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
                    }
                }
                Spacer(minLength: DroppySpacing.sm)
                Text(verbatim: CleanerFormat.string(cat.totalSize))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
            }
            Divider().opacity(0.25)
        }
    }

    private var footer: some View {
        HStack(spacing: DroppySpacing.sm) {
            Text(verbatim: "\(droplet.selectedCount) of \(droplet.totalCount) selected")
                .font(.system(size: 12))
                .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
            Spacer(minLength: 0)
            if droplet.categories.isEmpty {
                Button("Rescan") { droplet.scan() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
            } else {
                Button("Done") { droplet.closeReview() }
                    .buttonStyle(DroppyQuietButtonStyle(size: .small))
                Button("Clear") {
                    droplet.selectNone()
                }
                .buttonStyle(DroppyQuietButtonStyle(size: .small))
                // Always tappable while results are up: with nothing
                // selected it explains that instead of staying silent.
                Button(droplet.selectedIDs.isEmpty ? "Clean" : "Clean \(CleanerFormat.string(droplet.selectedBytes))") {
                    droplet.cleanSelected()
                }
                .buttonStyle(DroppyAccentButtonStyle(size: .small))
                .disabled(droplet.phase == .cleaning)
            }
        }
    }
}

// MARK: - HUD

extension MacCleanerDroplet: HUDPresenting {}

// MARK: - Settings pane

extension MacCleanerDroplet: SettingsPaneProviding {
    public func makeSettingsPane(context: SettingsPaneContext) -> AnyView {
        AnyView(MacCleanerSettings(droplet: self))
    }

    public var settingsSearchEntries: [SettingsSearchEntry] {
        [SettingsSearchEntry(title: "Cleaner", keywords: ["clean", "cache", "trash", "storage"])]
    }
}

private struct MacCleanerSettings: View {
    @ObservedObject var droplet: MacCleanerDroplet

    var body: some View {
        DropletSettingsPane {
            DropletSettingsCard {
                DropletToggleRow(
                    title: "Move to Trash instead of deleting",
                    subtitle: "Removed items go to the Trash so you can restore them. Only emptying the Trash is permanent.",
                    isOn: droplet.moveToTrashBinding
                )
            }

            DropletSettingsSection {
                settingsSectionHeader("Scan these by default")
            } content: {
                DropletSettingsCard {
                    ForEach(CleanerCategoryID.allCases) { cat in
                        DropletToggleRow(
                            title: cat.title,
                            subtitle: cat.isSafe ? "Safe cleanup, pre-selected." : "Review first, pre-selected.",
                            isOn: droplet.binding(for: cat)
                        )
                    }
                }
            }

            DropletSettingsSection {
                settingsSectionHeader("Last cleanup")
            } content: {
                DropletSettingsCard {
                    DropletControlRow(title: "Freed so far") {
                        DropletValuePill(text: CleanerFormat.string(droplet.lastCleanedBytes))
                    }
                }
            }
        }
    }
}
