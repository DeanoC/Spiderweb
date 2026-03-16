import Darwin
import ExtensionFoundation
import Foundation
import FSKit
import OSLog

@available(macOS 15.4, *)
@main
struct SpiderwebFSKitExtension: UnaryFileSystemExtension {
    let fileSystem = SpiderwebUnaryFileSystem()
}

@available(macOS 15.4, *)
final class SpiderwebUnaryFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    private let runtime = SpiderwebFSKitRuntime()

    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        do {
            let request = try runtime.currentRequest(resource: resource)
            SpiderwebFSKitDebug.log("probeResource succeeded for \(NSStringFromClass(type(of: resource as AnyObject)))")
            replyHandler(.usable(name: request.volumeNameOrDefault, containerID: FSContainerIdentifier(uuid: UUID())), nil)
        } catch {
            SpiderwebFSKitDebug.log("probeResource failed for \(NSStringFromClass(type(of: resource as AnyObject))): \(error.localizedDescription)")
            replyHandler(nil, error)
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        _ = options
        do {
            let volume = try SpiderwebFSKitVolume(runtime: runtime, volumeName: runtime.currentVolumeName(resource: resource))
            SpiderwebFSKitDebug.log("loadResource succeeded for \(NSStringFromClass(type(of: resource as AnyObject)))")
            replyHandler(volume, nil)
        } catch {
            SpiderwebFSKitDebug.log("loadResource failed for \(NSStringFromClass(type(of: resource as AnyObject))): \(error.localizedDescription)")
            replyHandler(nil, error)
        }
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = resource
        _ = options
        SpiderwebFSKitDebug.log("unloadResource called for \(NSStringFromClass(type(of: resource as AnyObject)))")
        runtime.shutdown()
        reply(nil)
    }

    func didFinishLoading() {
        SpiderwebFSKitDebug.log("extension finished loading")
        NSLog("SpiderwebFSKit extension loaded.")
    }
}

@available(macOS 15.4, *)
final class SpiderwebFSKitRuntime {
    private let lock = NSLock()
    private var activeRequest: SpiderwebMountRequest?
    private var activeNamespaceBridge: SpiderwebNamespaceBridge?
    private var scopedResourceURL: URL?
    private var scopedAccessActive = false

    func ensureNamespaceBridge(for resource: FSResource? = nil) throws -> SpiderwebNamespaceBridge {
        lock.lock()
        defer { lock.unlock() }

        if let activeNamespaceBridge {
            SpiderwebFSKitDebug.log("reusing active Spiderweb namespace bridge")
            try activeNamespaceBridge.launchIfNeeded()
            try activeNamespaceBridge.requireMountedRPCBridge()
            return activeNamespaceBridge
        }

        let request = try resolveRequest(resource: resource)
        SpiderwebFSKitDebug.log("resolved request for mountpoint \(request.launchConfig.mountpoint)")
        let bridge = SpiderwebNamespaceBridge(request: request)
        try bridge.launchIfNeeded()
        try bridge.requireMountedRPCBridge()

        SpiderwebFSKitDebug.log("swift namespace bridge ready for mountpoint \(request.launchConfig.mountpoint)")
        activeRequest = request
        activeNamespaceBridge = bridge
        return bridge
    }

    func currentRequest(resource: FSResource? = nil) throws -> SpiderwebMountRequest {
        lock.lock()
        defer { lock.unlock() }

        if let activeRequest {
            return activeRequest
        }
        let request = try resolveRequest(resource: resource)
        activeRequest = request
        return request
    }

    func currentVolumeName(resource: FSResource? = nil) throws -> String {
        try currentRequest(resource: resource).volumeNameOrDefault
    }

    func shutdown() {
        lock.lock()
        defer { lock.unlock() }

        SpiderwebFSKitDebug.log("runtime shutdown")
        activeNamespaceBridge?.stop()
        activeNamespaceBridge = nil
        activeRequest = nil
        if scopedAccessActive, let scopedResourceURL {
            scopedResourceURL.stopAccessingSecurityScopedResource()
        }
        scopedResourceURL = nil
        scopedAccessActive = false
    }

    private func resolveRequest(resource: FSResource?) throws -> SpiderwebMountRequest {
        if let activeRequest {
            return activeRequest
        }
        guard let resource else {
            throw SpiderwebFSKitBridgeError.invalidMountedResourceType("missing resource")
        }
        let resourceURL = try mountedResourceURL(from: resource)

        if !scopedAccessActive {
            guard resourceURL.startAccessingSecurityScopedResource() else {
                throw POSIXError(.EACCES)
            }
            scopedResourceURL = resourceURL
            scopedAccessActive = true
        }

        let request: SpiderwebMountRequest
        if resourceURL.pathExtension == "json" {
            request = try SpiderwebMountRequest.load(from: resourceURL)
        } else {
            let activeRequestURL = SpiderwebFSKitPaths.sharedContainerURL()
                .appendingPathComponent("current-request.json", isDirectory: false)
            request = try SpiderwebMountRequest.load(from: activeRequestURL)
        }
        activeRequest = request
        return request
    }
}

@available(macOS 15.4, *)
private struct SpiderwebOpenState {
    var handleID: UInt64
    var modes: FSVolume.OpenModes
    var retainCount: Int
    var writable: Bool
}

@available(macOS 15.4, *)
final class SpiderwebFSKitVolume:
    FSVolume,
    FSVolume.Operations,
    FSVolume.OpenCloseOperations,
    FSVolume.ReadWriteOperations,
    FSVolume.XattrOperations
{
    private let logger = Logger(subsystem: "com.deanoc.spiderweb.fskit.app", category: "spiderwebfs")
    private let runtime: SpiderwebFSKitRuntime
    private let stateLock = NSLock()
    private let failFastCooldownMS = spiderwebFailFastCooldownMS

    private var pathToItem: [String: SpiderwebFSKitItem] = [:]
    private var nextItemIdentifier: UInt64 = 1024
    private var openStates: [UInt64: SpiderwebOpenState] = [:]
    private var blockedPaths: [String: Date] = [:]
    private var volumeStatsCache = SpiderwebRemoteStatFS(
        blockSize: 4096,
        fragmentSize: 4096,
        totalBlocks: 1024,
        freeBlocks: 512,
        availableBlocks: 512,
        totalFiles: 16384,
        freeFiles: 16000,
        availableFiles: 16000,
        maximumNameLength: 255
    )

    let supportedVolumeCapabilities: FSVolume.SupportedCapabilities = {
        let capabilities = FSVolume.SupportedCapabilities()
        capabilities.supportsPersistentObjectIDs = true
        capabilities.supportsSymbolicLinks = true
        capabilities.supportsSparseFiles = false
        capabilities.supportsHiddenFiles = true
        capabilities.supportsFastStatFS = true
        capabilities.caseFormat = .sensitive
        return capabilities
    }()

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

    let maximumLinkCount = 1
    let maximumNameLength = 255
    let restrictsOwnershipChanges = false
    let truncatesLongNames = false
    var xattrOperationsInhibited = false
    var isOpenCloseInhibited = false

    private let rootItem: SpiderwebFSKitItem

    init(runtime: SpiderwebFSKitRuntime, volumeName: String) throws {
        self.runtime = runtime
        let bridge = try runtime.ensureNamespaceBridge()
        let rootAttr = try bridge.getattr(path: "/")
        let rootID = FSItem.Identifier.rootDirectory
        self.rootItem = SpiderwebFSKitItem(path: "/", itemIdentifier: rootID, cachedAttr: rootAttr)
        super.init(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: volumeName))
        pathToItem["/"] = rootItem
        try refreshVolumeStatistics()
    }

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try refreshVolumeStatistics()
            reply(nil)
        } catch {
            reply(error)
        }
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        releaseAllOpenHandles()
        runtime.shutdown()
        reply()
    }

    func synchronize(flags: FSSyncFlags, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            try refreshVolumeStatistics()
            reply(nil)
        } catch {
            reply(error)
        }
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let attr = try refreshAttributes(for: bridgeItem)
            reply(makeAttributes(for: bridgeItem, attr: attr), nil)
        } catch {
            reply(nil, error)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, (any Error)?) -> Void) {
        _ = newAttributes
        _ = item
        reply(nil, readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet"))
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        do {
            let directoryItem = try requireBridgeItem(directory)
            let childPath = try append(name: name, toDirectoryPath: directoryItem.path)
            try ensurePathIsNotBlocked(childPath)
            let attr = try runtime.ensureNamespaceBridge().getattr(path: childPath)
            clearBlockedPath(childPath)
            let child = itemForPath(childPath, attr: attr)
            reply(child, FSFileName(string: name.string ?? ""), nil)
        } catch {
            if let directoryItem = directory as? SpiderwebFSKitItem,
               let childPath = try? append(name: name, toDirectoryPath: directoryItem.path)
            {
                noteFailure(for: childPath, error: error)
            }
            reply(nil, nil, error)
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let bridgeItem = item as? SpiderwebFSKitItem else {
            reply(nil)
            return
        }
        if bridgeItem.path != "/" {
            pathToItem.removeValue(forKey: bridgeItem.path)
            openStates.removeValue(forKey: bridgeItem.itemIdentifier.rawValue)
        }
        reply(nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        reply(nil, CocoaError(.featureUnsupported))
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        _ = name
        _ = type
        _ = directory
        _ = newAttributes
        reply(nil, nil, readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet"))
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler reply: @escaping (FSItem?, FSFileName?, (any Error)?) -> Void) {
        _ = newAttributes
        _ = name
        _ = directory
        _ = contents
        reply(nil, nil, readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet"))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        _ = item
        _ = name
        _ = directory
        reply(nil, CocoaError(.featureUnsupported))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = item
        _ = name
        _ = directory
        reply(readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet"))
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        _ = item
        _ = sourceDirectory
        _ = sourceName
        _ = destinationName
        _ = destinationDirectory
        _ = overItem
        reply(nil, readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet"))
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        _ = verifier
        do {
            let directoryItem = try requireBridgeItem(directory)
            try ensurePathIsNotBlocked(directoryItem.path)
            let listing = try runtime.ensureNamespaceBridge().readdir(
                path: directoryItem.path,
                cookie: UInt64(cookie.rawValue),
                maxEntries: 256
            )
            clearBlockedPath(directoryItem.path)

            for (index, entry) in listing.entries.enumerated() {
                let childPath = join(directoryPath: directoryItem.path, childName: entry.name)
                let child = itemForPath(childPath, attr: entry.attr)
                let resolvedAttr: SpiderwebRemoteAttr
                do {
                    resolvedAttr = try currentAttributes(for: child)
                } catch {
                    if let fallbackAttr = entry.attr ?? child.cachedAttr {
                        logger.warning("enumerateDirectory falling back to cached attrs for \(childPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        resolvedAttr = fallbackAttr
                    } else {
                        logger.warning("enumerateDirectory skipping stalled entry \(childPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        continue
                    }
                }
                let nextCookieRaw = UInt64(cookie.rawValue) + UInt64(index) + 1
                let packed = packer.packEntry(
                    name: FSFileName(string: entry.name),
                    itemType: itemType(for: resolvedAttr),
                    itemID: child.itemIdentifier,
                    nextCookie: FSDirectoryCookie(rawValue: listing.eof && index == listing.entries.count - 1 ? 0 : nextCookieRaw),
                    attributes: attributes == nil ? nil : makeAttributes(for: child, attr: resolvedAttr)
                )
                if !packed {
                    break
                }
            }
            reply(FSDirectoryVerifier(rawValue: listing.directoryGeneration), nil)
        } catch {
            if let directoryItem = directory as? SpiderwebFSKitItem {
                noteFailure(for: directoryItem.path, error: error)
            }
            reply(verifier, error)
        }
    }

    func activate(options: FSTaskOptions, replyHandler reply: @escaping (FSItem?, (any Error)?) -> Void) {
        _ = options
        do {
            _ = try runtime.ensureNamespaceBridge()
            let attr = try refreshAttributes(for: rootItem)
            rootItem.cachedAttr = attr
            reply(rootItem, nil)
        } catch {
            reply(nil, error)
        }
    }

    func deactivate(options: FSDeactivateOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = options
        releaseAllOpenHandles()
        runtime.shutdown()
        reply(nil)
    }

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            _ = try ensureHandle(for: bridgeItem, modes: modes)
            reply(nil)
        } catch {
            if let bridgeItem = item as? SpiderwebFSKitItem {
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

    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let openState = try ensureHandle(for: bridgeItem, modes: [.read])
            let data = try runtime.ensureNamespaceBridge().read(
                handleID: openState.handleID,
                offset: UInt64(offset),
                length: UInt32(clamping: length)
            )
            try buffer.withUnsafeMutableBytes { rawBuffer in
                guard data.count <= rawBuffer.count else {
                    throw SpiderwebFSKitBridgeError.bridgeFailure("Read buffer too small for Spiderweb response")
                }
                rawBuffer.copyBytes(from: data)
            }
            reply(data.count, nil)
        } catch {
            if let bridgeItem = item as? SpiderwebFSKitItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(0, error)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        _ = contents
        _ = item
        _ = offset
        reply(0, readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet"))
    }

    func getXattr(named name: FSFileName, of item: FSItem, replyHandler reply: @escaping (Data?, (any Error)?) -> Void) {
        _ = name
        _ = item
        reply(nil, noAttributeError(message: "No extended attributes available"))
    }

    func setXattr(named name: FSFileName, to value: Data?, on item: FSItem, policy: FSVolume.SetXattrPolicy, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = name
        _ = value
        _ = item
        _ = policy
        reply(readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet"))
    }

    func listXattrs(of item: FSItem, replyHandler reply: @escaping ([FSFileName]?, (any Error)?) -> Void) {
        _ = item
        reply([], nil)
    }

    private func requireBridgeItem(_ item: FSItem) throws -> SpiderwebFSKitItem {
        guard let bridgeItem = item as? SpiderwebFSKitItem else {
            throw SpiderwebFSKitBridgeError.bridgeFailure("Received unexpected FSItem subclass")
        }
        return bridgeItem
    }

    private func refreshVolumeStatistics() throws {
        try ensurePathIsNotBlocked("/")
        let stats = try runtime.ensureNamespaceBridge().statfs(path: "/")
        stateLock.lock()
        volumeStatsCache = stats
        blockedPaths.removeValue(forKey: "/")
        stateLock.unlock()
    }

    private func currentAttributes(for item: SpiderwebFSKitItem) throws -> SpiderwebRemoteAttr {
        if let cachedAttr = item.cachedAttr {
            return cachedAttr
        }
        return try refreshAttributes(for: item)
    }

    private func refreshAttributes(for item: SpiderwebFSKitItem) throws -> SpiderwebRemoteAttr {
        try ensurePathIsNotBlocked(item.path)
        let attr = try runtime.ensureNamespaceBridge().getattr(path: item.path)
        item.cachedAttr = attr
        clearBlockedPath(item.path)
        return attr
    }

    private func itemForPath(_ path: String, attr: SpiderwebRemoteAttr?) -> SpiderwebFSKitItem {
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

        let item = SpiderwebFSKitItem(path: normalizedPath, itemIdentifier: identifier, cachedAttr: attr)
        pathToItem[normalizedPath] = item
        return item
    }

    private func ensureHandle(for item: SpiderwebFSKitItem, modes: FSVolume.OpenModes) throws -> SpiderwebOpenState {
        stateLock.lock()
        if var existing = openStates[item.itemIdentifier.rawValue] {
            if handle(existing, satisfies: modes) {
                existing.retainCount += 1
                existing.modes.formUnion(modes)
                openStates[item.itemIdentifier.rawValue] = existing
                stateLock.unlock()
                return existing
            }
        }
        stateLock.unlock()

        try ensurePathIsNotBlocked(item.path)
        let response = try runtime.ensureNamespaceBridge().open(path: item.path, flags: openFlags(for: modes))
        let state = SpiderwebOpenState(handleID: response.handleID, modes: modes, retainCount: 1, writable: response.writable)

        stateLock.lock()
        openStates[item.itemIdentifier.rawValue] = state
        blockedPaths.removeValue(forKey: normalize(path: item.path))
        stateLock.unlock()
        return state
    }

    private func releaseHandle(for item: SpiderwebFSKitItem) throws {
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

        try runtime.ensureNamespaceBridge().release(handleID: existing.handleID)
    }

    private func releaseAllOpenHandles() {
        stateLock.lock()
        let handles = Array(openStates.values)
        openStates.removeAll()
        stateLock.unlock()

        for handle in handles {
            try? runtime.ensureNamespaceBridge().release(handleID: handle.handleID)
        }
    }

    private func handle(_ state: SpiderwebOpenState, satisfies requestedModes: FSVolume.OpenModes) -> Bool {
        if requestedModes.contains(.write) {
            return state.writable
        }
        return true
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

    private func makeAttributes(for item: SpiderwebFSKitItem, attr: SpiderwebRemoteAttr) -> FSItem.Attributes {
        let attributes = FSItem.Attributes()
        attributes.type = itemType(for: attr)
        attributes.mode = attr.mode
        attributes.linkCount = attr.linkCount
        attributes.uid = attr.uid
        attributes.gid = attr.gid
        attributes.size = attr.size
        attributes.allocSize = attr.size
        attributes.fileID = item.itemIdentifier
        attributes.parentID = parentIdentifier(for: item.path)
        attributes.accessTime = makeTimespec(fromNanoseconds: attr.accessTimeNS)
        attributes.modifyTime = makeTimespec(fromNanoseconds: attr.modifyTimeNS)
        attributes.changeTime = makeTimespec(fromNanoseconds: attr.changeTimeNS)
        attributes.birthTime = makeTimespec(fromNanoseconds: attr.changeTimeNS)
        attributes.backupTime = makeTimespec(fromNanoseconds: attr.changeTimeNS)
        attributes.addedTime = makeTimespec(fromNanoseconds: attr.changeTimeNS)
        return attributes
    }

    private func itemType(for attr: SpiderwebRemoteAttr) -> FSItem.ItemType {
        switch attr.kindCode {
        case 2:
            return .directory
        case 3:
            return .symlink
        case 1:
            return .file
        default:
            let fileTypeBits = attr.mode & UInt32(S_IFMT)
            switch fileTypeBits {
            case UInt32(S_IFDIR):
                return .directory
            case UInt32(S_IFLNK):
                return .symlink
            default:
                return .file
            }
        }
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
        throw SpiderwebFSKitBridgeError.invalidFilenameEncoding
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

    private func join(directoryPath: String, childName: String) -> String {
        let base = normalize(path: directoryPath)
        if base == "/" {
            return "/" + childName
        }
        return base + "/" + childName
    }

    private func parentPath(of path: String) -> String {
        let normalized = normalize(path: path)
        if normalized == "/" {
            return "/"
        }
        let parent = URL(fileURLWithPath: normalized).deletingLastPathComponent().path
        return parent.isEmpty ? "/" : parent
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

    private func normalizedCreateMode(from attributes: FSItem.SetAttributesRequest, defaultMode: UInt32) -> UInt32 {
        if attributes.isValid(.mode) && attributes.mode != 0 {
            return attributes.mode
        }
        return defaultMode
    }
}

@available(macOS 15.4, *)
final class SpiderwebFSKitItem: FSItem {
    var path: String
    let itemIdentifier: FSItem.Identifier
    var cachedAttr: SpiderwebRemoteAttr?

    init(path: String, itemIdentifier: FSItem.Identifier, cachedAttr: SpiderwebRemoteAttr?) {
        self.path = path
        self.itemIdentifier = itemIdentifier
        self.cachedAttr = cachedAttr
        super.init()
    }
}
