/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class defines a custom volume for use by the passthrough file system.
*/

import Foundation
import ExtensionFoundation
import FSKit
import OSLog

let maxSymlinkSize: Int = 4096
let modeAllBits: Int32 = 0o7777

/// A PassthroughFSVolume represents a volume in the passthrough file system.
class PassthroughFSVolume: FSVolume,
                           FSVolume.ReadWriteOperations,
                           FSVolume.RenameOperations,
                           FSVolume.PreallocateOperations,
                           FSVolume.OpenCloseOperations {

    /// The default UUID for the PassthroughFSVolume.
    static let defaultVolumeUUID = UUID()

    /// The root item of the volume.
    var rootItem: PassthroughFSItem

    /// The item cache stores items previously looked up or created;
    /// items are removed from the dictionary when the volume reclaims or removes the item.
    var itemCache: [UInt64: PassthroughFSItem]

    /// The item cache is accessed concurrently so the volume needs to serialize access to it.
    var itemCacheQueue: DispatchQueue

    /// Creates a new PassthroughFSVolume.
    /// - Parameter rootPath: The path to the root directory of the volume.
    init(rootPath: String) throws {
        let rootFD      = try throwErrno { Darwin.open(rootPath, O_RDONLY) }
        self.rootItem   = PassthroughFSItem(name: ".", fileDescriptor: rootFD, type: .directory, openFlags: .readOnly)
        self.itemCache = [:]
        self.itemCacheQueue = DispatchQueue(label: "com.apple.fskit.passthroughfs.itemcache.queue")
        super.init(volumeID: FSVolume.Identifier(uuid: PassthroughFSVolume.defaultVolumeUUID), volumeName: createVolumeNameFromPath(rootPath))
        Logger.passthroughfs.info("\(#function): Created a new volume with ID(\(self.volumeID)) and name(\(self.name)) on path(\(rootPath))")
    }

    /// The PassthroughFS file system doesn't support setting a volume name, so this method does nothing and invokes its reply handler.
    public func setVolumeName(_ name: FSFileName, replyHandler: @escaping (FSFileName?, (any Error)?) -> Void) {
        return replyHandler(name, nil)
    }

    /// Prealocates disk space for the given item using `fcntl`.
    /// - Parameters:
    ///   - item: The item to preallocate space for.
    ///   - offset: The file offset at which to preallocate space.
    ///   - length: The length of the preallocated space.
    ///   - flags: The preallocation flags.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func preallocateSpace(for item: FSItem,
                                 at offset: off_t,
                                 length: Int,
                                 flags: FSVolume.PreallocateFlags,
                                 replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }
        guard ptItem.itemType == .file else {
            Logger.passthroughfs.error("\(#function): Can only preallocate a file")
            return replyHandler(0, POSIXError(.EPERM))
        }

        var preallocStruct = fstore_t()
        preallocStruct.fst_bytesalloc = 0
        preallocStruct.fst_flags = UInt32(flags.rawValue)
        preallocStruct.fst_length = Int64(length)
        preallocStruct.fst_offset = Int64(offset)
        preallocStruct.fst_posmode = F_PEOFPOSMODE

        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .readWrite)
        }
        var err: Error?
        if fcntl(ptItem.fileDescriptor, F_PREALLOCATE, &preallocStruct) == -1 {
            err = posixErrno
        }
        if oldFD < 0 {
            try? ptItem.closeItem()
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(Int(preallocStruct.fst_bytesalloc), nil)
    }

    /// Reads the contents of the given file item using `pread`.
    /// - Parameters:
    ///   - item: The file item to read from.
    ///   - offset: The file offset at which to begin reading.
    ///   - length: The number of bytes to read.
    ///   - buffer: The buffer into which to read the data.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func read(from item: FSItem,
                     at offset: off_t,
                     length: Int,
                     into buffer: FSMutableFileDataBuffer,
                     replyHandler: @escaping (Int, Error?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }
        let oldFD = ptItem.fileDescriptor
        if oldFD < 0 {
            try? ptItem.upgradeOpenMode(mode: .readOnly)
        }
        var err: Error?
        var actuallyRead = 0
        buffer.withUnsafeMutableBytes { rawBufferPointer in
            actuallyRead = pread(ptItem.fileDescriptor, rawBufferPointer.baseAddress, length, offset)

            // Check if the read operation was successful.
            if actuallyRead == -1 {
                err = posixErrno
            }
        }

        if oldFD < 0 {
            try? ptItem.closeItem()
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(actuallyRead, nil)

    }

    /// Writes contents to the given file item using `pwrite`.
    /// - Parameters:
    ///   - contents: The data to write to the file item.
    ///   - item: The file item to write to.
    ///   - offset: The file offset at which to begin writing.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func write(contents: Data,
                      to item: FSItem,
                      at offset: off_t,
                      replyHandler: @escaping (Int, (any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(0, POSIXError(.EINVAL))
        }

        guard ptItem.itemType != .directory else {
            Logger.passthroughfs.error("\(#function): Can't write to a folder")
            return replyHandler(0, POSIXError(.EISDIR))
        }

        let bytesPtr: UnsafeMutablePointer<UInt8> = UnsafeMutablePointer<UInt8>.allocate(capacity: contents.count)
        contents.copyBytes(to: bytesPtr, count: contents.count)

        var err: Error?
        let actuallyWritten = pwrite(ptItem.fileDescriptor, bytesPtr, contents.count, off_t(offset))
        bytesPtr.deallocate()
        if actuallyWritten == -1 {
            err = posixErrno
        }
        guard err == nil else {
            return replyHandler(0, err)
        }
        return replyHandler(actuallyWritten, nil)
    }

    /// Performs an `open` operation on the given file item.
    /// - Parameters:
    ///   - item: The file item to open.
    ///   - modes: The open modes.
    ///   - replyHandler: The reply handler to invoke with the result.
    public func openItem(_ item: FSItem,
                         modes: FSVolume.OpenModes,
                         replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            // root item is opened when creating the volume.
            return replyHandler(nil)
        }

        var ptfsMode: PassthroughFSItemOpenMode = .close
        if modes.contains(.read) {
            ptfsMode = .readOnly
        }
        if modes.contains(.write) {
            ptfsMode = .readWrite
        }

        do {
            try ptItem.upgradeOpenMode(mode: ptfsMode)
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Performs a `close` operation on the given file item.
    /// - Parameters:
    ///   - item: The file item to close.
    ///   - modes: The open modes (ignored for PassthroughFS).
    ///   - replyHandler: The reply handler to invoke with the result.
    public func closeItem(_ item: FSItem,
                          modes: FSVolume.OpenModes,
                          replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? PassthroughFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            // Root item is closed in deactivate volume.
            return replyHandler(nil)
        }

        do {
            try ptItem.closeItem()
        } catch {
            return replyHandler(error)
        }
        return replyHandler(nil)
    }

    /// Get maximum link count using `fpathconf`.
    public var maximumLinkCount: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_LINK_MAX))
    }

    /// Get maximum name length using `fpathconf`.
    public var maximumNameLength: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_NAME_MAX))
    }

    /// Get whether the volume restricts ownership changes based on authorization using `fpathconf`.
    public var restrictsOwnershipChanges: Bool {
        return fpathconf(self.rootItem.fileDescriptor, _PC_CHOWN_RESTRICTED) == 1
    }

    /// Get whether the volume truncates files longer than its maximum supported length using `fpathconf`.
    public var truncatesLongNames: Bool {
        return fpathconf(self.rootItem.fileDescriptor, _PC_NO_TRUNC) == 0
    }

    /// Get the maximum file size in bits using `fpathconf`.
    public var maximumFileSizeInBits: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_FILESIZEBITS))
    }

    /// Get the maximum extended attribute size in bits using `fpathconf`.
    public var maximumXattrSizeInBits: Int {
        return Int(fpathconf(self.rootItem.fileDescriptor, _PC_XATTR_SIZE_BITS))
    }
}

private struct SpiderwebOpenState {
    var handleID: UInt64
    var modes: FSVolume.OpenModes
    var retainCount: Int
}

final class SpiderwebFSItem: FSItem {
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

final class SpiderwebFSVolume:
    FSVolume,
    FSVolume.Operations,
    FSVolume.OpenCloseOperations,
    FSVolume.ReadWriteOperations
{
    private let logger = Logger.spiderwebfs
    private let runtime: SpiderwebMountRuntime
    private let stateLock = NSLock()
    private let failFastCooldownMS = spiderwebFailFastCooldownMS

    private var pathToItem: [String: SpiderwebFSItem] = [:]
    private var nextItemIdentifier: UInt64 = 1024
    private var openStates: [UInt64: SpiderwebOpenState] = [:]
    private var volumeStatsCache = syntheticStatFS
    private var blockedPaths: [String: Date] = [:]

    private let rootItem: SpiderwebFSItem

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

    let maximumLinkCount = 1
    let maximumNameLength = 255
    let restrictsOwnershipChanges = false
    let truncatesLongNames = false

    init(requestURL: URL) throws {
        runtime = try SpiderwebMountRuntime(requestURL: requestURL)
        let bridge = try runtime.ensureBridge()
        let rootAttr = try bridge.getattr(path: "/")
        rootItem = SpiderwebFSItem(path: "/", itemIdentifier: .rootDirectory, cachedAttr: rootAttr)
        super.init(volumeID: FSVolume.Identifier(), volumeName: FSFileName(string: runtime.request.volumeNameOrDefault))
        pathToItem["/"] = rootItem
        try refreshVolumeStatistics()
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
        do {
            _ = try runtime.ensureBridge()
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

    func mount(options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = options
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
        _ = flags
        do {
            try refreshVolumeStatistics()
            reply(nil)
        } catch {
            reply(error)
        }
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        _ = desiredAttributes
        do {
            let bridgeItem = try requireBridgeItem(item)
            let attr = try refreshAttributes(for: bridgeItem)
            reply(makeAttributes(for: bridgeItem, attr: attr), nil)
        } catch {
            reply(nil, error)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        _ = newAttributes
        _ = item
        reply(nil, readOnlyError(message: "Spiderweb native sample is read-only for now"))
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        do {
            let directoryItem = try requireBridgeItem(directory)
            let childPath = try append(name: name, toDirectoryPath: directoryItem.path)
            try ensurePathIsNotBlocked(childPath)
            let attr = try runtime.ensureBridge().getattr(path: childPath)
            clearBlockedPath(childPath)
            let child = itemForPath(childPath, attr: attr)
            reply(child, FSFileName(string: name.string ?? ""), nil)
        } catch {
            if let directoryItem = directory as? SpiderwebFSItem,
               let childPath = try? append(name: name, toDirectoryPath: directoryItem.path)
            {
                noteFailure(for: childPath, error: error)
            }
            reply(nil, nil, error)
        }
    }

    func reclaimItem(_ item: FSItem, replyHandler reply: @escaping (Error?) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let bridgeItem = item as? SpiderwebFSItem else {
            reply(nil)
            return
        }
        if bridgeItem.path != "/" {
            pathToItem.removeValue(forKey: bridgeItem.path)
            openStates.removeValue(forKey: bridgeItem.itemIdentifier.rawValue)
        }
        reply(nil)
    }

    func readSymbolicLink(_ item: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        _ = item
        reply(nil, CocoaError(.featureUnsupported))
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        _ = name
        _ = type
        _ = directory
        _ = newAttributes
        reply(nil, nil, readOnlyError(message: "Spiderweb native sample is read-only for now"))
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes newAttributes: FSItem.SetAttributesRequest, linkContents contents: FSFileName, replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        _ = name
        _ = directory
        _ = newAttributes
        _ = contents
        reply(nil, nil, readOnlyError(message: "Spiderweb native sample is read-only for now"))
    }

    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem, replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        _ = item
        _ = name
        _ = directory
        reply(nil, readOnlyError(message: "Spiderweb native sample is read-only for now"))
    }

    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = item
        _ = name
        _ = directory
        reply(readOnlyError(message: "Spiderweb native sample is read-only for now"))
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?, replyHandler reply: @escaping (FSFileName?, (any Error)?) -> Void) {
        _ = item
        _ = sourceDirectory
        _ = sourceName
        _ = destinationName
        _ = destinationDirectory
        _ = overItem
        reply(nil, readOnlyError(message: "Spiderweb native sample is read-only for now"))
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker, replyHandler reply: @escaping (FSDirectoryVerifier, (any Error)?) -> Void) {
        _ = verifier
        do {
            let directoryItem = try requireBridgeItem(directory)
            try ensurePathIsNotBlocked(directoryItem.path)
            let listing = try runtime.ensureBridge().readdir(
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
            if let directoryItem = directory as? SpiderwebFSItem {
                noteFailure(for: directoryItem.path, error: error)
            }
            reply(verifier, error)
        }
    }

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes, replyHandler reply: @escaping ((any Error)?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            _ = try ensureHandle(for: bridgeItem, modes: modes)
            reply(nil)
        } catch {
            if let bridgeItem = item as? SpiderwebFSItem {
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
            let openState = try ensureHandle(for: bridgeItem, modes: [.read])
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
            reply(data.count, nil)
        } catch {
            if let bridgeItem = item as? SpiderwebFSItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(0, error)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t, replyHandler reply: @escaping (Int, (any Error)?) -> Void) {
        _ = contents
        _ = item
        _ = offset
        reply(0, readOnlyError(message: "Spiderweb native sample is read-only for now"))
    }

    private func requireBridgeItem(_ item: FSItem) throws -> SpiderwebFSItem {
        guard let bridgeItem = item as? SpiderwebFSItem else {
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

    private func currentAttributes(for item: SpiderwebFSItem) throws -> SpiderwebRemoteAttr {
        if let cached = item.cachedAttr {
            return cached
        }
        return try refreshAttributes(for: item)
    }

    private func refreshAttributes(for item: SpiderwebFSItem) throws -> SpiderwebRemoteAttr {
        try ensurePathIsNotBlocked(item.path)
        let attr = try runtime.ensureBridge().getattr(path: item.path)
        item.cachedAttr = attr
        clearBlockedPath(item.path)
        return attr
    }

    private func itemForPath(_ path: String, attr: SpiderwebRemoteAttr?) -> SpiderwebFSItem {
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

        let item = SpiderwebFSItem(path: normalizedPath, itemIdentifier: identifier, cachedAttr: attr)
        pathToItem[normalizedPath] = item
        return item
    }

    private func ensureHandle(for item: SpiderwebFSItem, modes: FSVolume.OpenModes) throws -> SpiderwebOpenState {
        stateLock.lock()
        if var existing = openStates[item.itemIdentifier.rawValue] {
            existing.retainCount += 1
            existing.modes.formUnion(modes)
            openStates[item.itemIdentifier.rawValue] = existing
            stateLock.unlock()
            return existing
        }
        stateLock.unlock()

        try ensurePathIsNotBlocked(item.path)
        let response = try runtime.ensureBridge().open(path: item.path, flags: openFlags(for: modes))
        let state = SpiderwebOpenState(handleID: response.handleID, modes: modes, retainCount: 1)

        stateLock.lock()
        openStates[item.itemIdentifier.rawValue] = state
        blockedPaths.removeValue(forKey: normalize(path: item.path))
        stateLock.unlock()
        return state
    }

    private func releaseHandle(for item: SpiderwebFSItem) throws {
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

    private func makeAttributes(for item: SpiderwebFSItem, attr: SpiderwebRemoteAttr) -> FSItem.Attributes {
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
        default:
            return .file
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
}
