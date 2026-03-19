/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The Spiderweb-backed FSKit bridge volume used by native request mounts.
*/

import Darwin
import Foundation
import FSKit
import OSLog

let modeAllBits: Int32 = 0o7777

private struct SpiderwebBridgeOpenState {
    var handleID: UInt64
    var modes: FSVolume.OpenModes
    var writable: Bool
    var retainCount: Int
}

private struct SpiderwebDirectoryCacheEntry {
    let fetchedAt: Date
    let listing: SpiderwebRemoteDirectoryListing
}

final class SpiderwebBridgeItem: FSItem {
    var path: String
    let itemIdentifier: FSItem.Identifier
    var cachedAttr: SpiderwebRemoteAttr? {
        didSet {
            cachedAttrFetchedAt = cachedAttr == nil ? nil : Date()
        }
    }
    private(set) var cachedAttrFetchedAt: Date?

    init(path: String, itemIdentifier: FSItem.Identifier, cachedAttr: SpiderwebRemoteAttr?) {
        self.path = path
        self.itemIdentifier = itemIdentifier
        self.cachedAttr = cachedAttr
        self.cachedAttrFetchedAt = cachedAttr == nil ? nil : Date()
        super.init()
    }
}

final class SpiderwebBridgeVolume:
    FSVolume,
    FSVolume.Operations,
    FSVolume.PathConfOperations,
    FSVolume.AccessCheckOperations,
    FSVolume.ItemDeactivation,
    FSVolume.OpenCloseOperations,
    FSVolume.ReadWriteOperations,
    FSVolume.XattrOperations
{
    private let logger = Logger.spiderwebfs
    private let runtime: SpiderwebMountRuntime
    private let stateLock = NSLock()
    private let failFastCooldownMS = spiderwebFailFastCooldownMS

    private var pathToItem: [String: SpiderwebBridgeItem] = [:]
    private var nextItemIdentifier: UInt64 = 1024
    private var openStates: [UInt64: SpiderwebBridgeOpenState] = [:]
    private var volumeStatsCache = syntheticStatFS
    private var blockedPaths: [String: Date] = [:]
    private var invalidatedPaths: Set<String> = []
    private var directoryCache: [String: SpiderwebDirectoryCacheEntry] = [:]

    private let rootItem: SpiderwebBridgeItem
    private let directoryCacheTTL: TimeInterval = 5.0
    private let attributeCacheTTL: TimeInterval = 5.0
    private let directoryPageSize: UInt32 = 256

    let supportedVolumeCapabilities: FSVolume.SupportedCapabilities = {
        let capabilities = FSVolume.SupportedCapabilities()
        // Bridge items are mount-local path objects, not stable object-ID lookups.
        // Advertising persistent object IDs encourages vnode reuse we can't honor.
        capabilities.supportsPersistentObjectIDs = false
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsHardLinks = false
        capabilities.supportsSparseFiles = false
        capabilities.supportsHiddenFiles = true
        capabilities.supportsFastStatFS = true
        capabilities.caseFormat = .sensitive
        return capabilities
    }()

    let maximumLinkCount = 1
    let maximumNameLength = 255
    let restrictsOwnershipChanges = false
    let truncatesLongNames = false
    let itemDeactivationPolicy: FSVolume.ItemDeactivationOptions = .always

    init(requestURL: URL) throws {
        runtime = try SpiderwebMountRuntime(requestURL: requestURL)
        rootItem = SpiderwebBridgeItem(path: "/", itemIdentifier: .rootDirectory, cachedAttr: nil)
        super.init(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: runtime.request.volumeNameOrDefault))
        runtime.setInvalidationHandler { [weak self] invalidation in
            self?.applyMountedInvalidation(invalidation)
        }
        pathToItem["/"] = rootItem
    }

    deinit {
        releaseAllOpenHandles()
        runtime.shutdown()
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "spiderwebfs")
        stateLock.lock()
        let cached = volumeStatsCache
        stateLock.unlock()
        stats.blockSize = Int(cached.blockSize)
        stats.ioSize = Int(cached.fragmentSize)
        stats.totalBlocks = cached.totalBlocks
        stats.availableBlocks = cached.availableBlocks
        stats.freeBlocks = cached.freeBlocks
        stats.usedBlocks = cached.totalBlocks >= cached.freeBlocks ? cached.totalBlocks - cached.freeBlocks : 0
        stats.totalFiles = cached.totalFiles
        stats.freeFiles = cached.freeFiles
        return stats
    }

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        _ = options
        primeBridgeInBackground()
        reply(rootItem, nil)
    }

    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = options
        releaseAllOpenHandles()
        runtime.shutdown()
        reply(nil)
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = options
        primeBridgeInBackground()
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        releaseAllOpenHandles()
        runtime.shutdown()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = flags
        primeBridgeInBackground()
        reply(nil)
    }

    private func primeBridgeInBackground() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            do {
                _ = try self.runtime.ensureBridge()
                try self.refreshVolumeStatistics()
            } catch {
                self.logger.notice("Background bridge warmup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func checkAccess(to item: FSItem, requestedAccess access: FSVolume.AccessMask, replyHandler reply: @escaping (Bool, Error?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            if access.intersection(writeLikeAccessMask).isEmpty {
                reply(true, nil)
                return
            }
            let allowWrites = runtime.isWritablePath(bridgeItem.path)
            reply(allowWrites, nil)
        } catch {
            reply(false, error)
        }
    }

    func deactivateItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        guard let bridgeItem = item as? SpiderwebBridgeItem else {
            reply(nil)
            return
        }

        let normalizedPath = normalize(path: bridgeItem.path)
        var handleIDToRelease: UInt64?
        stateLock.lock()
        bridgeItem.cachedAttr = nil
        blockedPaths.removeValue(forKey: normalizedPath)
        invalidatedPaths.remove(normalizedPath)
        clearDirectoryCacheLocked(forPath: normalizedPath)
        handleIDToRelease = openStates.removeValue(forKey: bridgeItem.itemIdentifier.rawValue)?.handleID
        if normalizedPath != "/" {
            pathToItem.removeValue(forKey: normalizedPath)
        }
        stateLock.unlock()
        if let handleIDToRelease {
            try? runtime.ensureBridge().release(handleID: handleIDToRelease)
        }
        reply(nil)
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let attr = try withPerformanceLogging(operation: "getAttributes", path: bridgeItem.path) {
                return try currentAttributes(for: bridgeItem)
            }
            reply(makeAttributes(for: bridgeItem, attr: attr, desiredAttributes: desiredAttributes), nil)
        } catch {
            reply(nil, error)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let attr = try withPerformanceLogging(operation: "setAttributes", path: bridgeItem.path) {
                let bridge = try runtime.ensureBridge()

                if requestedUnsupportedAttributeMutation(newAttributes) {
                    throw POSIXError(.EINVAL)
                }

                if newAttributes.isValid(.size) {
                    try bridge.truncate(path: bridgeItem.path, size: newAttributes.size)
                    invalidateCachedPath(bridgeItem.path)
                    return try currentAttributes(for: bridgeItem)
                }

                if requestedSoftMetadataMutation(newAttributes) {
                    guard runtime.isWritablePath(bridgeItem.path) else {
                        throw readOnlyError(message: "Spiderweb path \(bridgeItem.path) is read-only")
                    }
                    if hasIgnoredMetadataMutation(newAttributes) {
                        logger.notice("Ignoring unsupported metadata fields for \(bridgeItem.path, privacy: .public): \(self.describeIgnoredMetadataRequest(newAttributes), privacy: .public)")
                    }
                    let request = makeSetAttrRequest(newAttributes)
                    if newAttributes.isValid(.flags) {
                        logger.notice(
                            "Applying FSKit flags request for \(bridgeItem.path, privacy: .public): raw=\(newAttributes.flags) mapped=\(request.flags ?? 0) request=\(self.describeSetAttributesRequest(newAttributes), privacy: .public)"
                        )
                    }
                    if request.isEmpty {
                        logger.notice("Ignoring metadata-only no-op for writable Spiderweb path \(bridgeItem.path, privacy: .public): \(self.describeSetAttributesRequest(newAttributes), privacy: .public)")
                        return try currentAttributes(for: bridgeItem)
                    }

                    let attr = try bridge.setattr(path: bridgeItem.path, request: request)
                    invalidateCachedPath(bridgeItem.path)
                    clearBlockedPath(bridgeItem.path)
                    bridgeItem.cachedAttr = attr
                    return attr
                }

                throw CocoaError(.featureUnsupported)
            }
            reply(makeAttributes(for: bridgeItem, attr: attr, desiredAttributes: attributeSnapshotRequest()), nil)
        } catch {
            if let bridgeItem = item as? SpiderwebBridgeItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(nil, error)
        }
    }

    func getXattr(named name: FSFileName, of item: FSItem, replyHandler reply: @escaping (Data?, Error?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            _ = try requireXattrName(name)
            reply(nil, unsupportedXattrReadError(path: bridgeItem.path))
        } catch {
            reply(nil, error)
        }
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy, replyHandler reply: @escaping (Error?) -> Void) {
        _ = value
        _ = policy
        do {
            let bridgeItem = try requireBridgeItem(item)
            _ = try requireXattrName(name)
            reply(unsupportedXattrWriteError(path: bridgeItem.path))
        } catch {
            reply(error)
        }
    }

    func listXattrs(of item: FSItem, replyHandler reply: @escaping ([FSFileName]?, Error?) -> Void) {
        do {
            _ = try requireBridgeItem(item)
            reply([], nil)
        } catch {
            reply(nil, error)
        }
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        do {
            let directoryItem = try requireBridgeItem(directory)
            let entryName = try fsNameString(name)
            let childPath = try append(name: name, toDirectoryPath: directoryItem.path)
            let resolved = try withPerformanceLogging(operation: "lookupItem", path: childPath) { () -> (SpiderwebBridgeItem, FSFileName) in
                if let cachedEntry = cachedDirectoryEntry(named: entryName, inDirectoryPath: directoryItem.path) {
                    let child = itemForPath(childPath, attr: cachedEntry.attr)
                    if let attr = cachedEntry.attr {
                        child.cachedAttr = attr
                        clearBlockedPath(childPath)
                        return (child, FSFileName(string: entryName))
                    }
                    if let cachedAttr = child.cachedAttr, shouldUseCachedAttributes(for: child) {
                        child.cachedAttr = cachedAttr
                        clearBlockedPath(childPath)
                        return (child, FSFileName(string: entryName))
                    }
                }

                let child = itemForPath(childPath, attr: nil)
                let attr = try currentAttributes(for: child)
                clearBlockedPath(childPath)
                child.cachedAttr = attr
                return (child, FSFileName(string: entryName))
            }
            reply(resolved.0, resolved.1, nil)
        } catch {
            if let directoryItem = directory as? SpiderwebBridgeItem,
               let childPath = try? append(name: name, toDirectoryPath: directoryItem.path)
            {
                noteFailure(for: childPath, error: error)
            }
            reply(nil, nil, error)
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        guard let bridgeItem = item as? SpiderwebBridgeItem else {
            reply(nil)
            return
        }
        var handleIDToRelease: UInt64?
        stateLock.lock()
        if bridgeItem.path != "/" {
            pathToItem.removeValue(forKey: bridgeItem.path)
            handleIDToRelease = openStates.removeValue(forKey: bridgeItem.itemIdentifier.rawValue)?.handleID
        }
        clearDirectoryCacheLocked(forPath: normalize(path: bridgeItem.path))
        stateLock.unlock()
        if let handleIDToRelease {
            try? runtime.ensureBridge().release(handleID: handleIDToRelease)
        }
        reply(nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let target = try runtime.ensureBridge().readlink(path: bridgeItem.path)
            reply(FSFileName(string: target), nil)
        } catch {
            if let bridgeItem = item as? SpiderwebBridgeItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(nil, error)
        }
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        do {
            let directoryItem = try requireBridgeItem(directory)
            let childPath = try append(name: name, toDirectoryPath: directoryItem.path)
            let resolved = try withPerformanceLogging(operation: "createItem", path: childPath) { () -> (SpiderwebBridgeItem, FSFileName) in
                let createdAttr: SpiderwebRemoteAttr?
                switch type {
                case .directory:
                    try runtime.ensureBridge().mkdir(path: childPath)
                    createdAttr = nil
                case .file:
                    let mode = newAttributes.isValid(.mode) ? newAttributes.mode : UInt32(0o644)
                    let created = try runtime.ensureBridge().create(path: childPath, mode: mode, flags: UInt32(O_RDWR))
                    if newAttributes.isValid(.size), newAttributes.size > 0 {
                        try runtime.ensureBridge().truncate(path: childPath, size: newAttributes.size)
                        createdAttr = nil
                    } else {
                        createdAttr = created
                    }
                default:
                    throw CocoaError(.featureUnsupported)
                }

                invalidateCachedPath(directoryItem.path)
                invalidateCachedPath(childPath)
                let child = itemForPath(childPath, attr: createdAttr)
                let attr = if let createdAttr {
                    createdAttr
                } else {
                    try currentAttributes(for: child)
                }
                child.cachedAttr = attr
                return (child, FSFileName(string: name.string ?? ""))
            }
            reply(resolved.0, resolved.1, nil)
        } catch {
            if let directoryItem = directory as? SpiderwebBridgeItem,
               let childPath = try? append(name: name, toDirectoryPath: directoryItem.path)
            {
                noteFailure(for: childPath, error: error)
            }
            reply(nil, nil, error)
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        _ = newAttributes
        do {
            let directoryItem = try requireBridgeItem(directory)
            let childPath = try append(name: name, toDirectoryPath: directoryItem.path)
            guard let target = contents.string, !target.isEmpty else {
                throw POSIXError(.EINVAL)
            }
            let resolved = try withPerformanceLogging(operation: "createSymbolicLink", path: childPath) { () -> (SpiderwebBridgeItem, FSFileName) in
                try runtime.ensureBridge().symlink(target: target, linkPath: childPath)
                invalidateCachedPath(directoryItem.path)
                invalidateCachedPath(childPath)
                let child = itemForPath(childPath, attr: nil)
                let attr = try currentAttributes(for: child)
                child.cachedAttr = attr
                return (child, FSFileName(string: name.string ?? ""))
            }
            reply(resolved.0, resolved.1, nil)
        } catch {
            if let directoryItem = directory as? SpiderwebBridgeItem,
               let childPath = try? append(name: name, toDirectoryPath: directoryItem.path)
            {
                noteFailure(for: childPath, error: error)
            }
            reply(nil, nil, error)
        }
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        _ = item
        _ = name
        _ = directory
        reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: [NSLocalizedDescriptionKey: "Spiderweb native mounts do not support hard links"]))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let directoryItem = try requireBridgeItem(directory)
            try withPerformanceLogging(operation: "removeItem", path: bridgeItem.path) {
                let attr = try currentAttributes(for: bridgeItem)
                switch itemType(for: attr) {
                case .directory:
                    try runtime.ensureBridge().rmdir(path: bridgeItem.path)
                    removeCachedPath(bridgeItem.path, includeDescendants: true)
                default:
                    try runtime.ensureBridge().unlink(path: bridgeItem.path)
                    removeCachedPath(bridgeItem.path)
                }
                invalidateCachedPath(directoryItem.path)
            }
            reply(nil)
        } catch {
            if let bridgeItem = item as? SpiderwebBridgeItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(error)
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let sourceDirectoryItem = try requireBridgeItem(sourceDirectory)
            let destinationDirectoryItem = try requireBridgeItem(destinationDirectory)
            let destinationPath = try append(name: destinationName, toDirectoryPath: destinationDirectoryItem.path)
            let resolvedName = try withPerformanceLogging(operation: "renameItem", path: bridgeItem.path) {
                try runtime.ensureBridge().rename(oldPath: bridgeItem.path, newPath: destinationPath)
                invalidateCachedPath(sourceDirectoryItem.path)
                invalidateCachedPath(destinationDirectoryItem.path)
                if let overBridgeItem = overItem as? SpiderwebBridgeItem {
                    removeCachedPath(overBridgeItem.path, includeDescendants: true)
                }
                moveCachedPath(from: bridgeItem.path, to: destinationPath)
                return destinationName
            }
            reply(resolvedName, nil)
        } catch {
            if let bridgeItem = item as? SpiderwebBridgeItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(nil, error)
        }
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        _ = verifier
        do {
            let directoryItem = try requireBridgeItem(directory)
            let directoryVerifier = try withPerformanceLogging(operation: "enumerateDirectory", path: directoryItem.path) {
                let listing = try readDirectoryListing(
                    path: directoryItem.path,
                    cookie: UInt64(cookie.rawValue),
                    maxEntries: directoryPageSize
                )

                for (index, entry) in listing.entries.enumerated() {
                    let childPath = join(directoryPath: directoryItem.path, childName: entry.name)
                    let child = itemForPath(childPath, attr: entry.attr)
                    let resolvedAttr: SpiderwebRemoteAttr
                    if let entryAttr = entry.attr {
                        child.cachedAttr = entryAttr
                        resolvedAttr = entryAttr
                    } else if let fastAttr = fastEnumeratedAttributes(for: child, entryName: entry.name, parentPath: directoryItem.path) {
                        resolvedAttr = fastAttr
                    } else {
                        do {
                            resolvedAttr = try currentAttributes(for: child)
                        } catch {
                            if let fallbackAttr = child.cachedAttr {
                                logger.warning("enumerateDirectory falling back to cached attrs for \(childPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                resolvedAttr = fallbackAttr
                            } else {
                                logger.warning("enumerateDirectory skipping stalled entry \(childPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                                continue
                            }
                        }
                    }
                    let nextCookieRaw = UInt64(cookie.rawValue) + UInt64(index) + 1
                    let packed = packer.packEntry(
                        name: FSFileName(string: entry.name),
                        itemType: itemType(for: resolvedAttr),
                        itemID: child.itemIdentifier,
                        nextCookie: FSDirectoryCookie(rawValue: listing.eof && index == listing.entries.count - 1 ? 0 : nextCookieRaw),
                        attributes: attributes.map { makeAttributes(for: child, attr: resolvedAttr, desiredAttributes: $0) }
                    )
                    if !packed {
                        break
                    }
                }
                return FSDirectoryVerifier(rawValue: listing.directoryGeneration)
            }
            reply(directoryVerifier, nil)
        } catch {
            if let directoryItem = directory as? SpiderwebBridgeItem {
                noteFailure(for: directoryItem.path, error: error)
            }
            reply(verifier, error)
        }
    }

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            try withPerformanceLogging(operation: "openItem", path: bridgeItem.path) {
                let attr = try currentAttributes(for: bridgeItem)
                if itemType(for: attr) == .directory {
                    clearBlockedPath(bridgeItem.path)
                    return
                }
                _ = try ensureHandle(for: bridgeItem, modes: modes)
            }
            reply(nil)
        } catch {
            if let bridgeItem = item as? SpiderwebBridgeItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(error)
        }
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = modes
        do {
            let bridgeItem = try requireBridgeItem(item)
            try releaseHandle(for: bridgeItem)
            reply(nil)
        } catch {
            reply(error)
        }
    }

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, Error?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let bytesRead = try withPerformanceLogging(operation: "read", path: bridgeItem.path) {
                let (openState, transient) = try borrowHandle(for: bridgeItem, modes: [.read])
                defer {
                    if transient {
                        try? releaseHandle(for: bridgeItem)
                    }
                }
                let data = try runtime.ensureBridge().read(
                    handleID: openState.handleID,
                    offset: UInt64(offset),
                    length: UInt32(clamping: length)
                )
                try buffer.withUnsafeMutableBytes { rawBuffer in
                    guard data.count <= rawBuffer.count else {
                        throw SpiderwebBridgeError.invalidEnvelope
                    }
                    rawBuffer.copyBytes(from: data)
                }
                return data.count
            }
            reply(bytesRead, nil)
        } catch {
            if let bridgeItem = item as? SpiderwebBridgeItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(0, error)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let written = try withPerformanceLogging(operation: "write", path: bridgeItem.path) {
                let (openState, transient) = try borrowHandle(for: bridgeItem, modes: [.read, .write])
                defer {
                    if transient {
                        try? releaseHandle(for: bridgeItem)
                    }
                }
                guard openState.writable else {
                    throw readOnlyError(message: "Spiderweb path \(bridgeItem.path) is read-only")
                }
                let written = try runtime.ensureBridge().write(
                    handleID: openState.handleID,
                    offset: UInt64(offset),
                    data: contents
                )
                invalidateCachedPath(bridgeItem.path)
                clearBlockedPath(bridgeItem.path)
                return Int(written)
            }
            reply(written, nil)
        } catch {
            if let bridgeItem = item as? SpiderwebBridgeItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(0, error)
        }
    }

    private func requireBridgeItem(_ item: FSItem) throws -> SpiderwebBridgeItem {
        guard let bridgeItem = item as? SpiderwebBridgeItem else {
            throw SpiderwebBridgeError.invalidMountedResourceType("unexpected FSItem subclass")
        }
        return bridgeItem
    }

    private func refreshVolumeStatistics() throws {
        try ensurePathIsNotBlocked("/")
        let stats = try runtime.ensureBridge().statfs(path: "/")
        stateLock.lock()
        volumeStatsCache = stats
        blockedPaths.removeValue(forKey: "/")
        stateLock.unlock()
    }

    private func currentAttributes(for item: SpiderwebBridgeItem) throws -> SpiderwebRemoteAttr {
        if let cached = item.cachedAttr, shouldUseCachedAttributes(for: item) {
            return cached
        }
        if let hinted = hintedAttributes(for: item) {
            item.cachedAttr = hinted
            clearBlockedPath(item.path)
            return hinted
        }
        return try refreshAttributes(for: item)
    }

    private func refreshAttributes(for item: SpiderwebBridgeItem) throws -> SpiderwebRemoteAttr {
        try ensurePathIsNotBlocked(item.path)
        let attr = try runtime.ensureBridge().getattr(path: item.path)
        item.cachedAttr = attr
        clearBlockedPath(item.path)
        stateLock.lock()
        invalidatedPaths.remove(normalize(path: item.path))
        stateLock.unlock()
        return attr
    }

    private func itemForPath(_ path: String, attr: SpiderwebRemoteAttr?) -> SpiderwebBridgeItem {
        let normalizedPath = normalize(path: path)
        stateLock.lock()
        defer { stateLock.unlock() }

        if let existing = pathToItem[normalizedPath] {
            if let attr {
                existing.cachedAttr = attr
            }
            return existing
        }

        let identifier: FSItem.Identifier
        if normalizedPath == "/" {
            identifier = .rootDirectory
        } else {
            let rawValue = nextItemIdentifier
            nextItemIdentifier += 1
            identifier = FSItem.Identifier(rawValue: rawValue) ?? .invalid
        }

        let item = SpiderwebBridgeItem(path: normalizedPath, itemIdentifier: identifier, cachedAttr: attr)
        pathToItem[normalizedPath] = item
        return item
    }

    private func attributeSnapshotRequest() -> FSItem.GetAttributesRequest {
        let request = FSItem.GetAttributesRequest()
        request.wantedAttributes = [
            .type,
            .mode,
            .linkCount,
            .uid,
            .gid,
            .flags,
            .size,
            .allocSize,
            .fileID,
            .parentID,
            .accessTime,
            .modifyTime,
            .changeTime,
            .birthTime,
            .backupTime,
            .addedTime,
            .inhibitKernelOffloadedIO,
        ]
        return request
    }

    private func requestedUnsupportedAttributeMutation(_ newAttributes: FSItem.SetAttributesRequest) -> Bool {
        newAttributes.isValid(.type) ||
            newAttributes.isValid(.linkCount) ||
            newAttributes.isValid(.allocSize) ||
            newAttributes.isValid(.fileID) ||
            newAttributes.isValid(.parentID)
    }

    private func requestedSoftMetadataMutation(_ newAttributes: FSItem.SetAttributesRequest) -> Bool {
        newAttributes.isValid(.mode) ||
            newAttributes.isValid(.accessTime) ||
            newAttributes.isValid(.modifyTime) ||
            newAttributes.isValid(.uid) ||
            newAttributes.isValid(.gid) ||
            newAttributes.isValid(.flags) ||
            newAttributes.isValid(.birthTime) ||
            newAttributes.isValid(.backupTime) ||
            newAttributes.isValid(.addedTime)
    }

    private func hasIgnoredMetadataMutation(_ newAttributes: FSItem.SetAttributesRequest) -> Bool {
        newAttributes.isValid(.changeTime) ||
            newAttributes.isValid(.birthTime) ||
            newAttributes.isValid(.backupTime) ||
            newAttributes.isValid(.addedTime)
    }

    private func makeSetAttrRequest(_ newAttributes: FSItem.SetAttributesRequest) -> SpiderwebSetAttrRequest {
        let rawFlags: UInt32? = if newAttributes.isValid(.flags) {
            newAttributes.flags
        } else {
            nil
        }
        if let rawFlags {
            let ignoredFlags = rawFlags & ~supportedBSDFlags
            if ignoredFlags != 0 {
                logger.notice("Ignoring unsupported BSD flags in setattr request: raw=\(rawFlags) ignored=\(ignoredFlags)")
            }
        }
        return SpiderwebSetAttrRequest(
            mode: newAttributes.isValid(.mode) ? (newAttributes.mode & UInt32(modeAllBits)) : nil,
            uid: newAttributes.isValid(.uid) ? newAttributes.uid : nil,
            gid: newAttributes.isValid(.gid) ? newAttributes.gid : nil,
            flags: rawFlags.map { $0 & supportedBSDFlags },
            accessTimeNS: newAttributes.isValid(.accessTime) ? nanoseconds(from: newAttributes.accessTime) : nil,
            modifyTimeNS: newAttributes.isValid(.modifyTime) ? nanoseconds(from: newAttributes.modifyTime) : nil
        )
    }

    private func describeSetAttributesRequest(_ newAttributes: FSItem.SetAttributesRequest) -> String {
        var parts: [String] = []
        if newAttributes.isValid(.size) { parts.append("size=\(newAttributes.size)") }
        if newAttributes.isValid(.mode) { parts.append("mode=\(String(newAttributes.mode, radix: 8))") }
        if newAttributes.isValid(.accessTime) { parts.append("accessTime=\(nanoseconds(from: newAttributes.accessTime))") }
        if newAttributes.isValid(.modifyTime) { parts.append("modifyTime=\(nanoseconds(from: newAttributes.modifyTime))") }
        if newAttributes.isValid(.uid) { parts.append("uid=\(newAttributes.uid)") }
        if newAttributes.isValid(.gid) { parts.append("gid=\(newAttributes.gid)") }
        if newAttributes.isValid(.flags) { parts.append("flags=\(newAttributes.flags)") }
        if newAttributes.isValid(.birthTime) { parts.append("birthTime=\(nanoseconds(from: newAttributes.birthTime))") }
        if newAttributes.isValid(.backupTime) { parts.append("backupTime=\(nanoseconds(from: newAttributes.backupTime))") }
        if newAttributes.isValid(.addedTime) { parts.append("addedTime=\(nanoseconds(from: newAttributes.addedTime))") }
        return parts.isEmpty ? "<none>" : parts.joined(separator: ", ")
    }

    private func describeIgnoredMetadataRequest(_ newAttributes: FSItem.SetAttributesRequest) -> String {
        var parts: [String] = []
        if newAttributes.isValid(.changeTime) { parts.append("changeTime=\(nanoseconds(from: newAttributes.changeTime))") }
        if newAttributes.isValid(.birthTime) { parts.append("birthTime=\(nanoseconds(from: newAttributes.birthTime))") }
        if newAttributes.isValid(.backupTime) { parts.append("backupTime=\(nanoseconds(from: newAttributes.backupTime))") }
        if newAttributes.isValid(.addedTime) { parts.append("addedTime=\(nanoseconds(from: newAttributes.addedTime))") }
        return parts.isEmpty ? "<none>" : parts.joined(separator: ", ")
    }

    private func requireXattrName(_ name: FSFileName) throws -> String {
        if let string = name.string, !string.isEmpty {
            return string
        }
        throw POSIXError(.EINVAL)
    }

    private func unsupportedXattrReadError(path: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOATTR),
            userInfo: [NSLocalizedDescriptionKey: "Extended attributes are not exposed on Spiderweb native mounts for \(path)"]
        )
    }

    private func unsupportedXattrWriteError(path: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOTSUP),
            userInfo: [NSLocalizedDescriptionKey: "Extended attributes are not supported on Spiderweb native mounts for \(path)"]
        )
    }

    private func linuxXattrFlags(for policy: FSVolume.SetXattrPolicy) -> UInt32 {
        switch policy {
        case .alwaysSet:
            return 0
        case .mustCreate:
            return 0x1
        case .mustReplace:
            return 0x2
        case .delete:
            return 0
        @unknown default:
            return 0
        }
    }

    private var supportedBSDFlags: UInt32 {
        UInt32(UF_HIDDEN | UF_IMMUTABLE)
    }

    private var writeLikeAccessMask: FSVolume.AccessMask {
        [
            .writeData,
            .appendData,
            .addFile,
            .addSubdirectory,
            .delete,
            .deleteChild,
            .writeAttributes,
            .writeXattr,
            .writeSecurity,
            .takeOwnership,
        ]
    }

    private func invalidateCachedPath(_ path: String, includeDescendants: Bool = false, invalidateParentDirectory: Bool = true) {
        let normalizedPath = normalize(path: path)
        stateLock.lock()
        invalidateCachedPathLocked(normalizedPath, includeDescendants: includeDescendants, invalidateParentDirectory: invalidateParentDirectory)
        stateLock.unlock()
    }

    private func invalidateCachedPathLocked(_ normalizedPath: String, includeDescendants: Bool, invalidateParentDirectory: Bool) {
        let prefix = normalizedPath == "/" ? "/" : normalizedPath + "/"
        let affectedPaths = pathToItem.keys.filter { cachedPath in
            cachedPath == normalizedPath || (includeDescendants && cachedPath.hasPrefix(prefix))
        }
        if affectedPaths.isEmpty {
            blockedPaths.removeValue(forKey: normalizedPath)
            invalidatedPaths.remove(normalizedPath)
        } else {
            for path in affectedPaths {
                pathToItem[path]?.cachedAttr = nil
                blockedPaths.removeValue(forKey: path)
                invalidatedPaths.remove(path)
            }
        }
        if includeDescendants {
            clearDirectoryCacheTreeLocked(forPath: normalizedPath)
        } else {
            clearDirectoryCacheLocked(forPath: normalizedPath)
        }
        if invalidateParentDirectory {
            clearDirectoryCacheLocked(forPath: parentPath(of: normalizedPath))
        }
    }

    private func removeCachedPath(_ path: String, includeDescendants: Bool = false) {
        let normalizedPath = normalize(path: path)
        let prefix = normalizedPath == "/" ? "/" : normalizedPath + "/"
        var handleIDsToRelease: [UInt64] = []
        stateLock.lock()
        let removedPaths = pathToItem.keys.filter { cachedPath in
            cachedPath == normalizedPath || (includeDescendants && cachedPath.hasPrefix(prefix))
        }
        for removedPath in removedPaths {
            if let item = pathToItem.removeValue(forKey: removedPath),
               let handleID = openStates.removeValue(forKey: item.itemIdentifier.rawValue)?.handleID
            {
                handleIDsToRelease.append(handleID)
            }
            blockedPaths.removeValue(forKey: removedPath)
            invalidatedPaths.remove(removedPath)
        }
        clearDirectoryCacheTreeLocked(forPath: normalizedPath)
        clearDirectoryCacheLocked(forPath: parentPath(of: normalizedPath))
        stateLock.unlock()
        for handleID in handleIDsToRelease {
            try? runtime.ensureBridge().release(handleID: handleID)
        }
    }

    private func moveCachedPath(from oldPath: String, to newPath: String) {
        let normalizedOldPath = normalize(path: oldPath)
        let normalizedNewPath = normalize(path: newPath)
        let oldPrefix = normalizedOldPath == "/" ? "/" : normalizedOldPath + "/"
        stateLock.lock()
        let movedEntries = pathToItem.keys
            .filter { cachedPath in
                cachedPath == normalizedOldPath || cachedPath.hasPrefix(oldPrefix)
            }
            .sorted()
        for sourcePath in movedEntries {
            guard let item = pathToItem.removeValue(forKey: sourcePath) else {
                continue
            }
            let suffix = sourcePath == normalizedOldPath ? "" : String(sourcePath.dropFirst(normalizedOldPath.count))
            let destinationPath = suffix.isEmpty ? normalizedNewPath : normalizedNewPath + suffix
            item.path = destinationPath
            item.cachedAttr = nil
            pathToItem[destinationPath] = item
            blockedPaths.removeValue(forKey: sourcePath)
            blockedPaths.removeValue(forKey: destinationPath)
            invalidatedPaths.remove(sourcePath)
            invalidatedPaths.remove(destinationPath)
        }
        clearDirectoryCacheTreeLocked(forPath: normalizedOldPath)
        clearDirectoryCacheTreeLocked(forPath: normalizedNewPath)
        clearDirectoryCacheLocked(forPath: parentPath(of: normalizedOldPath))
        clearDirectoryCacheLocked(forPath: parentPath(of: normalizedNewPath))
        stateLock.unlock()
    }

    private func ensureHandle(
        for item: SpiderwebBridgeItem,
        modes: FSVolume.OpenModes,
        retain: Bool = true
    ) throws -> SpiderwebBridgeOpenState {
        let normalizedPath = normalize(path: item.path)
        stateLock.lock()
        if var existing = openStates[item.itemIdentifier.rawValue] {
            let requestedModes = existing.modes.union(modes)
            let needsUpgrade = requestedModes.contains(.write) && !existing.modes.contains(.write)
            let needsRefresh = invalidatedPaths.contains(normalizedPath)
            if !needsUpgrade && !needsRefresh {
                if retain {
                    existing.retainCount += 1
                    existing.modes = requestedModes
                    openStates[item.itemIdentifier.rawValue] = existing
                }
                stateLock.unlock()
                return existing
            }
            let oldHandleID = existing.handleID
            let upgradedRetainCount = existing.retainCount + (retain ? 1 : 0)
            if needsRefresh {
                logger.notice(
                    "Refreshing open handle for invalidated path \(normalizedPath, privacy: .public) oldHandle=\(oldHandleID)"
                )
            }
            stateLock.unlock()

            try ensurePathIsNotBlocked(item.path)
            let response = try runtime.ensureBridge().open(path: item.path, flags: openFlags(for: requestedModes))
            try? runtime.ensureBridge().release(handleID: oldHandleID)
            let upgradedState = SpiderwebBridgeOpenState(
                handleID: response.handleID,
                modes: requestedModes,
                writable: response.writable,
                retainCount: upgradedRetainCount
            )

            stateLock.lock()
            openStates[item.itemIdentifier.rawValue] = upgradedState
            blockedPaths.removeValue(forKey: normalizedPath)
            invalidatedPaths.remove(normalizedPath)
            stateLock.unlock()
            return upgradedState
        }
        stateLock.unlock()

        try ensurePathIsNotBlocked(item.path)
        let response = try runtime.ensureBridge().open(path: item.path, flags: openFlags(for: modes))
        let state = SpiderwebBridgeOpenState(
            handleID: response.handleID,
            modes: modes,
            writable: response.writable,
            retainCount: retain ? 1 : 0
        )

        stateLock.lock()
        openStates[item.itemIdentifier.rawValue] = state
        blockedPaths.removeValue(forKey: normalizedPath)
        invalidatedPaths.remove(normalizedPath)
        stateLock.unlock()
        return state
    }

    private func borrowHandle(for item: SpiderwebBridgeItem, modes: FSVolume.OpenModes) throws -> (SpiderwebBridgeOpenState, Bool) {
        stateLock.lock()
        let existing = openStates[item.itemIdentifier.rawValue]
        stateLock.unlock()

        if existing != nil {
            return (try ensureHandle(for: item, modes: modes, retain: false), false)
        }
        return (try ensureHandle(for: item, modes: modes), true)
    }

    private func releaseHandle(for item: SpiderwebBridgeItem) throws {
        stateLock.lock()
        guard var existing = openStates[item.itemIdentifier.rawValue] else {
            stateLock.unlock()
            return
        }
        existing.retainCount -= 1
        if existing.retainCount > 0 {
            openStates[item.itemIdentifier.rawValue] = existing
            stateLock.unlock()
            return
        }
        openStates.removeValue(forKey: item.itemIdentifier.rawValue)
        stateLock.unlock()

        try runtime.ensureBridge().release(handleID: existing.handleID)
    }

    private func releaseAllOpenHandles() {
        stateLock.lock()
        let handles = Array(openStates.values)
        openStates.removeAll()
        stateLock.unlock()

        for handle in handles {
            try? runtime.ensureBridge().release(handleID: handle.handleID)
        }
    }

    private func openFlags(for modes: FSVolume.OpenModes) -> UInt32 {
        if modes.contains(.write) && modes.contains(.read) {
            return UInt32(O_RDWR)
        }
        if modes.contains(.write) {
            return UInt32(O_WRONLY)
        }
        return UInt32(O_RDONLY)
    }

    private func makeAttributes(
        for item: SpiderwebBridgeItem,
        attr: SpiderwebRemoteAttr,
        desiredAttributes: FSItem.GetAttributesRequest
    ) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        if desiredAttributes.isAttributeWanted(.type) {
            attributes.type = itemType(for: attr)
        }
        if desiredAttributes.isAttributeWanted(.mode) {
            attributes.mode = attr.mode
        }
        if desiredAttributes.isAttributeWanted(.linkCount) {
            attributes.linkCount = attr.linkCount
        }
        if desiredAttributes.isAttributeWanted(.uid) {
            attributes.uid = attr.uid
        }
        if desiredAttributes.isAttributeWanted(.gid) {
            attributes.gid = attr.gid
        }
        if desiredAttributes.isAttributeWanted(.flags) {
            attributes.flags = attr.flags ?? 0
        }
        if desiredAttributes.isAttributeWanted(.size) {
            attributes.size = attr.size
        }
        if desiredAttributes.isAttributeWanted(.allocSize) {
            attributes.allocSize = attr.size
        }
        if desiredAttributes.isAttributeWanted(.fileID) {
            attributes.fileID = item.itemIdentifier
        }
        if desiredAttributes.isAttributeWanted(.parentID) {
            attributes.parentID = parentIdentifier(for: item.path)
        }
        if desiredAttributes.isAttributeWanted(.accessTime) {
            attributes.accessTime = makeTimespec(fromNanoseconds: attr.accessTimeNS)
        }
        if desiredAttributes.isAttributeWanted(.modifyTime) {
            attributes.modifyTime = makeTimespec(fromNanoseconds: attr.modifyTimeNS)
        }
        if desiredAttributes.isAttributeWanted(.changeTime) {
            attributes.changeTime = makeTimespec(fromNanoseconds: attr.changeTimeNS)
        }
        if desiredAttributes.isAttributeWanted(.birthTime) {
            attributes.birthTime = makeTimespec(fromNanoseconds: attr.changeTimeNS)
        }
        if desiredAttributes.isAttributeWanted(.backupTime) {
            attributes.backupTime = makeTimespec(fromNanoseconds: attr.changeTimeNS)
        }
        if desiredAttributes.isAttributeWanted(.addedTime) {
            attributes.addedTime = makeTimespec(fromNanoseconds: attr.changeTimeNS)
        }
        if desiredAttributes.isAttributeWanted(.inhibitKernelOffloadedIO) {
            attributes.inhibitKernelOffloadedIO = runtime.isWritablePath(item.path)
        }
        return attributes
    }

    private func itemType(for attr: SpiderwebRemoteAttr) -> FSItem.ItemType {
        switch attr.kindCode {
        case 2:
            return .directory
        case 3:
            return .symlink
        default:
            return .file
        }
    }

    private func fastEnumeratedAttributes(for item: SpiderwebBridgeItem, entryName: String, parentPath: String) -> SpiderwebRemoteAttr? {
        _ = entryName
        _ = parentPath
        if let attr = item.cachedAttr, shouldUseCachedAttributes(for: item) {
            return attr
        }
        return nil
    }

    private func shouldUseCachedAttributes(for item: SpiderwebBridgeItem) -> Bool {
        guard item.cachedAttr != nil else {
            return false
        }
        guard let fetchedAt = item.cachedAttrFetchedAt else {
            return false
        }
        if Date().timeIntervalSince(fetchedAt) > attributeCacheTTL {
            item.cachedAttr = nil
            return false
        }
        let normalizedPath = normalize(path: item.path)
        stateLock.lock()
        let invalidated = invalidatedPaths.contains(normalizedPath)
        stateLock.unlock()
        if invalidated {
            return false
        }
        return true
    }

    private func parentIdentifier(for path: String) -> FSItem.Identifier {
        if path == "/" {
            return .parentOfRoot
        }
        let parentPath = parentPath(of: path)
        stateLock.lock()
        defer { stateLock.unlock() }
        return pathToItem[parentPath]?.itemIdentifier ?? .rootDirectory
    }

    private func append(name: FSFileName, toDirectoryPath directoryPath: String) throws -> String {
        let component = try fsNameString(name)
        if component == "." {
            return directoryPath
        }
        if component == ".." {
            return parentPath(of: directoryPath)
        }
        return join(directoryPath: directoryPath, childName: component)
    }

    private func fsNameString(_ name: FSFileName) throws -> String {
        if let string = name.string, !string.isEmpty {
            return string
        }
        throw SpiderwebBridgeError.invalidFilenameEncoding
    }

    private func normalize(path: String) -> String {
        guard !path.isEmpty, path != "/" else {
            return "/"
        }
        var normalized = path
        if !normalized.hasPrefix("/") {
            normalized = "/" + normalized
        }
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func parentPath(of path: String) -> String {
        let normalized = normalize(path: path)
        if normalized == "/" {
            return "/"
        }
        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
    }

    private func lastPathComponent(of path: String) -> String {
        let normalized = normalize(path: path)
        if normalized == "/" {
            return "/"
        }
        return URL(fileURLWithPath: normalized).lastPathComponent
    }

    private func ensurePathIsNotBlocked(_ path: String) throws {
        let normalized = normalize(path: path)
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let blockedUntil = blockedPaths[normalized] else {
            return
        }
        if blockedUntil <= Date() {
            blockedPaths.removeValue(forKey: normalized)
            return
        }
        let remainingMS = max(1, Int(blockedUntil.timeIntervalSinceNow * 1000))
        throw timeoutError(operationName: normalized, timeoutMS: UInt64(remainingMS))
    }

    private func clearBlockedPath(_ path: String) {
        stateLock.lock()
        blockedPaths.removeValue(forKey: normalize(path: path))
        stateLock.unlock()
    }

    private func applyMountedInvalidation(_ invalidation: SpiderwebMountedInvalidation) {
        let normalizedPath = normalize(path: invalidation.path)
        logger.notice(
            "Applying mounted invalidation for \(normalizedPath, privacy: .public) kind \(String(describing: invalidation.kind), privacy: .public)"
        )
        stateLock.lock()
        defer { stateLock.unlock() }

        switch invalidation.kind {
        case .directory:
            applyInvalidationLocked(to: normalizedPath, includeDescendants: true, invalidateParentDirectory: true)
        case .attr, .data, .all:
            applyInvalidationLocked(to: normalizedPath, includeDescendants: false, invalidateParentDirectory: true)
        }
    }

    private func applyInvalidationLocked(to normalizedPath: String, includeDescendants: Bool, invalidateParentDirectory: Bool) {
        let prefix = normalizedPath == "/" ? "/" : normalizedPath + "/"
        let affectedPaths = pathToItem.keys.filter { path in
            path == normalizedPath || (includeDescendants && path.hasPrefix(prefix))
        }
        if affectedPaths.isEmpty {
            blockedPaths.removeValue(forKey: normalizedPath)
            invalidatedPaths.insert(normalizedPath)
        } else {
            for path in affectedPaths {
                pathToItem[path]?.cachedAttr = nil
                blockedPaths.removeValue(forKey: path)
                invalidatedPaths.insert(path)
            }
        }
        if includeDescendants {
            clearDirectoryCacheTreeLocked(forPath: normalizedPath)
        } else {
            clearDirectoryCacheLocked(forPath: normalizedPath)
        }
        if invalidateParentDirectory {
            clearDirectoryCacheLocked(forPath: parentPath(of: normalizedPath))
        }
    }

    private func noteFailure(for path: String, error: Error) {
        guard isBridgeTimeoutError(error), failFastCooldownMS > 0 else {
            return
        }
        let normalized = normalize(path: path)
        stateLock.lock()
        blockedPaths[normalized] = Date().addingTimeInterval(Double(failFastCooldownMS) / 1000.0)
        stateLock.unlock()
        logger.warning("Fail-fast blocking \(normalized, privacy: .public) for \(self.failFastCooldownMS)ms after timeout")
    }

    private func makeTimespec(fromNanoseconds value: Int64) -> timespec {
        let seconds = value / 1_000_000_000
        var nanoseconds = value % 1_000_000_000
        if nanoseconds < 0 {
            nanoseconds += 1_000_000_000
        }
        return timespec(tv_sec: Int(seconds), tv_nsec: Int(nanoseconds))
    }

    private func nanoseconds(from value: timespec) -> Int64 {
        Int64(value.tv_sec) * 1_000_000_000 + Int64(value.tv_nsec)
    }

    private func readDirectoryListing(path: String, cookie: UInt64, maxEntries: UInt32) throws -> SpiderwebRemoteDirectoryListing {
        let normalizedPath = normalize(path: path)
        if let cached = cachedDirectoryListing(path: normalizedPath, cookie: cookie, maxEntries: maxEntries) {
            return cached
        }

        try ensurePathIsNotBlocked(normalizedPath)
        let bridge = try runtime.ensureBridge()
        let listing = try bridge.readdir(path: normalizedPath, cookie: cookie, maxEntries: maxEntries)
        clearBlockedPath(normalizedPath)
        stateLock.lock()
        invalidatedPaths.remove(normalizedPath)
        stateLock.unlock()
        storeDirectoryListing(listing, path: normalizedPath, cookie: cookie, maxEntries: maxEntries)
        return listing
    }

    private func hintedAttributes(for item: SpiderwebBridgeItem) -> SpiderwebRemoteAttr? {
        let normalizedPath = normalize(path: item.path)
        if let synthetic = runtime.syntheticAttrHint(path: normalizedPath) {
            return synthetic
        }
        guard normalizedPath != "/" else {
            return nil
        }
        guard let entry = cachedDirectoryEntry(
            named: lastPathComponent(of: normalizedPath),
            inDirectoryPath: parentPath(of: normalizedPath)
        ) else {
            return nil
        }
        return entry.attr
    }

    private func cachedDirectoryEntry(named name: String, inDirectoryPath directoryPath: String) -> SpiderwebRemoteDirectoryListing.Entry? {
        let normalizedDirectoryPath = normalize(path: directoryPath)
        guard let listing = cachedDirectoryListing(path: normalizedDirectoryPath, cookie: 0, maxEntries: directoryPageSize) else {
            return nil
        }
        return listing.entries.first { $0.name == name }
    }

    private func cachedDirectoryListing(path: String, cookie: UInt64, maxEntries: UInt32) -> SpiderwebRemoteDirectoryListing? {
        let cacheKey = directoryCacheKey(path: path, cookie: cookie, maxEntries: maxEntries)
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let entry = directoryCache[cacheKey] else {
            return nil
        }
        guard Date().timeIntervalSince(entry.fetchedAt) <= directoryCacheTTL else {
            directoryCache.removeValue(forKey: cacheKey)
            return nil
        }
        if invalidatedPaths.contains(path) {
            directoryCache.removeValue(forKey: cacheKey)
            return nil
        }
        return entry.listing
    }

    private func storeDirectoryListing(_ listing: SpiderwebRemoteDirectoryListing, path: String, cookie: UInt64, maxEntries: UInt32) {
        let cacheKey = directoryCacheKey(path: path, cookie: cookie, maxEntries: maxEntries)
        stateLock.lock()
        directoryCache[cacheKey] = SpiderwebDirectoryCacheEntry(fetchedAt: Date(), listing: listing)
        stateLock.unlock()
    }

    private func directoryCacheKey(path: String, cookie: UInt64, maxEntries: UInt32) -> String {
        "\(path)#\(cookie)#\(maxEntries)"
    }

    private func clearDirectoryCacheLocked(forPath path: String) {
        let prefix = "\(path)#"
        directoryCache.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { directoryCache.removeValue(forKey: $0) }
    }

    private func clearDirectoryCacheTreeLocked(forPath path: String) {
        let normalizedPath = normalize(path: path)
        let descendantPrefix = normalizedPath == "/" ? "/" : normalizedPath + "/"
        directoryCache.keys
            .filter { key in
                guard let cachePath = key.split(separator: "#", maxSplits: 1).first.map(String.init) else {
                    return false
                }
                return cachePath == normalizedPath || cachePath.hasPrefix(descendantPrefix)
            }
            .forEach { directoryCache.removeValue(forKey: $0) }
    }

    private func withPerformanceLogging<T>(operation: String, path: String? = nil, _ work: () throws -> T) throws -> T {
        guard spiderwebFSKitPerfLoggingEnabled else {
            return try work()
        }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let before = runtime.performanceSnapshot()
        do {
            let value = try work()
            logPerformance(operation: operation, path: path, startedAt: startedAt, before: before, after: runtime.performanceSnapshot(), error: nil)
            return value
        } catch {
            logPerformance(operation: operation, path: path, startedAt: startedAt, before: before, after: runtime.performanceSnapshot(), error: error)
            throw error
        }
    }

    private func logPerformance(
        operation: String,
        path: String?,
        startedAt: UInt64,
        before: SpiderwebRemoteOperationSnapshot,
        after: SpiderwebRemoteOperationSnapshot,
        error: Error?
    ) {
        let delta = after.delta(since: before)
        let durationMS = Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000.0
        guard delta.total > 0 || durationMS >= 25.0 || error != nil else {
            return
        }

        let pathDescription = path ?? "-"
        let message = "FSKit \(operation) path=\(pathDescription) duration_ms=\(durationMS) lookup=\(delta.lookup) getattr=\(delta.getattr) readdir=\(delta.readdir)"
        if let error {
            logger.warning("\(message, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        } else {
            logger.debug("\(message, privacy: .public)")
        }
    }
}
