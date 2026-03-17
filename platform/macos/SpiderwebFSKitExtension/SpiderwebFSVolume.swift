/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class defines a custom volume for use by the passthrough file system.
*/

import Darwin
import Foundation
import ExtensionFoundation
import FSKit
import OSLog

let maxSymlinkSize: Int = 4096
let modeAllBits: Int32 = 0o7777

/// A SpiderwebFSVolume represents a volume in the passthrough file system.
class SpiderwebFSVolume: FSVolume,
                           FSVolume.ReadWriteOperations,
                           FSVolume.RenameOperations,
                           FSVolume.PreallocateOperations,
                           FSVolume.OpenCloseOperations {

    /// The default UUID for the SpiderwebFSVolume.
    static let defaultVolumeUUID = UUID()

    /// The root item of the volume.
    var rootItem: SpiderwebFSItem

    /// The item cache stores items previously looked up or created;
    /// items are removed from the dictionary when the volume reclaims or removes the item.
    var itemCache: [UInt64: SpiderwebFSItem]

    /// The item cache is accessed concurrently so the volume needs to serialize access to it.
    var itemCacheQueue: DispatchQueue

    /// Creates a new SpiderwebFSVolume.
    /// - Parameter rootPath: The path to the root directory of the volume.
    init(rootPath: String) throws {
        let rootFD      = try throwErrno { Darwin.open(rootPath, O_RDONLY) }
        self.rootItem   = SpiderwebFSItem(name: ".", fileDescriptor: rootFD, type: .directory, openFlags: .readOnly)
        self.itemCache = [:]
        self.itemCacheQueue = DispatchQueue(label: "com.apple.fskit.passthroughfs.itemcache.queue")
        super.init(volumeID: FSVolume.Identifier(uuid: SpiderwebFSVolume.defaultVolumeUUID), volumeName: createVolumeNameFromPath(rootPath))
        Logger.passthroughfs.info("\(#function): Created a new volume with ID(\(self.volumeID)) and name(\(self.name)) on path(\(rootPath))")
    }

    /// The SpiderwebFSKit file system doesn't support setting a volume name, so this method does nothing and invokes its reply handler.
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
        guard let ptItem = item as? SpiderwebFSItem else {
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
        guard let ptItem = item as? SpiderwebFSItem else {
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
        guard let ptItem = item as? SpiderwebFSItem else {
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
        guard let ptItem = item as? SpiderwebFSItem else {
            Logger.passthroughfs.error("\(#function): Can't cast item")
            return replyHandler(POSIXError(.EINVAL))
        }
        guard ptItem != self.rootItem else {
            // root item is opened when creating the volume.
            return replyHandler(nil)
        }

        var ptfsMode: SpiderwebFSItemOpenMode = .close
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
    ///   - modes: The open modes (ignored for SpiderwebFSKit).
    ///   - replyHandler: The reply handler to invoke with the result.
    public func closeItem(_ item: FSItem,
                          modes: FSVolume.OpenModes,
                          replyHandler: @escaping ((any Error)?) -> Void) {
        guard let ptItem = item as? SpiderwebFSItem else {
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

private struct SpiderwebBridgeOpenState {
    var handleID: UInt64
    var modes: FSVolume.OpenModes
    var writable: Bool
    var retainCount: Int
}

final class SpiderwebBridgeItem: FSItem {
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

final class SpiderwebBridgeVolume:
    FSVolume,
    FSVolume.Operations,
    FSVolume.OpenCloseOperations,
    FSVolume.ReadWriteOperations
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

    private let rootItem: SpiderwebBridgeItem

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
        rootItem = SpiderwebBridgeItem(path: "/", itemIdentifier: .rootDirectory, cachedAttr: rootAttr)
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
        do {
            let bridgeItem = try requireBridgeItem(item)
            let attr = try refreshAttributes(for: bridgeItem)
            reply(makeAttributes(for: bridgeItem, attr: attr, desiredAttributes: desiredAttributes), nil)
        } catch {
            reply(nil, error)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem, replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        do {
            let bridgeItem = try requireBridgeItem(item)
            let bridge = try runtime.ensureBridge()

            if requestedUnsupportedAttributeMutation(newAttributes) {
                reply(nil, POSIXError(.EINVAL))
                return
            }

            if newAttributes.isValid(.size) {
                try bridge.truncate(path: bridgeItem.path, size: newAttributes.size)
                invalidateCachedPath(bridgeItem.path)
                let attr = try refreshAttributes(for: bridgeItem)
                reply(makeAttributes(for: bridgeItem, attr: attr, desiredAttributes: attributeSnapshotRequest()), nil)
                return
            }

            if requestedSoftMetadataMutation(newAttributes) {
                guard bridge.isWritablePath(bridgeItem.path) else {
                    reply(nil, readOnlyError(message: "Spiderweb path \(bridgeItem.path) is read-only"))
                    return
                }
                logger.notice("Ignoring metadata-only update for writable Spiderweb path \(bridgeItem.path, privacy: .public)")
                invalidateCachedPath(bridgeItem.path)
                let attr = try refreshAttributes(for: bridgeItem)
                reply(makeAttributes(for: bridgeItem, attr: attr, desiredAttributes: attributeSnapshotRequest()), nil)
                return
            }

            reply(nil, CocoaError(.featureUnsupported))
        } catch {
            if let bridgeItem = item as? SpiderwebBridgeItem {
                noteFailure(for: bridgeItem.path, error: error)
            }
            reply(nil, error)
        }
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
            if let directoryItem = directory as? SpiderwebBridgeItem,
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

        guard let bridgeItem = item as? SpiderwebBridgeItem else {
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
        do {
            let directoryItem = try requireBridgeItem(directory)
            let childPath = try append(name: name, toDirectoryPath: directoryItem.path)

            switch type {
            case .directory:
                try runtime.ensureBridge().mkdir(path: childPath)
            case .file:
                let mode = newAttributes.isValid(.mode) ? newAttributes.mode : UInt32(0o644)
                _ = try runtime.ensureBridge().create(path: childPath, mode: mode, flags: UInt32(O_RDWR))
                if newAttributes.isValid(.size), newAttributes.size > 0 {
                    try runtime.ensureBridge().truncate(path: childPath, size: newAttributes.size)
                }
            default:
                reply(nil, nil, CocoaError(.featureUnsupported))
                return
            }

            invalidateCachedPath(directoryItem.path)
            invalidateCachedPath(childPath)
            let attr = try runtime.ensureBridge().getattr(path: childPath)
            let child = itemForPath(childPath, attr: attr)
            reply(child, FSFileName(string: name.string ?? ""), nil)
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
        do {
            let bridgeItem = try requireBridgeItem(item)
            let directoryItem = try requireBridgeItem(directory)
            let attr = try currentAttributes(for: bridgeItem)
            switch itemType(for: attr) {
            case .directory:
                try runtime.ensureBridge().rmdir(path: bridgeItem.path)
            default:
                try runtime.ensureBridge().unlink(path: bridgeItem.path)
            }
            invalidateCachedPath(directoryItem.path)
            removeCachedPath(bridgeItem.path)
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

            try runtime.ensureBridge().rename(oldPath: bridgeItem.path, newPath: destinationPath)
            invalidateCachedPath(sourceDirectoryItem.path)
            invalidateCachedPath(destinationDirectoryItem.path)
            if let overBridgeItem = overItem as? SpiderwebBridgeItem {
                removeCachedPath(overBridgeItem.path)
            }
            moveCachedPath(from: bridgeItem.path, to: destinationPath)
            reply(destinationName, nil)
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
                if let fastAttr = fastEnumeratedAttributes(for: child, entryName: entry.name, parentPath: directoryItem.path) {
                    resolvedAttr = fastAttr
                } else {
                    do {
                        resolvedAttr = try currentAttributes(for: child)
                    } catch {
                        if let fallbackAttr = entry.attr ?? child.cachedAttr ?? syntheticFallbackAttr(forPath: childPath, entryName: entry.name) {
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
            reply(FSDirectoryVerifier(rawValue: listing.directoryGeneration), nil)
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
            _ = try ensureHandle(for: bridgeItem, modes: modes)
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
            reply(data.count, nil)
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
            let (openState, transient) = try borrowHandle(for: bridgeItem, modes: [.read, .write])
            defer {
                if transient {
                    try? releaseHandle(for: bridgeItem)
                }
            }
            guard openState.writable else {
                reply(0, readOnlyError(message: "Spiderweb path \(bridgeItem.path) is read-only"))
                return
            }
            let written = try runtime.ensureBridge().write(
                handleID: openState.handleID,
                offset: UInt64(offset),
                data: contents
            )
            bridgeItem.cachedAttr = nil
            clearBlockedPath(bridgeItem.path)
            reply(Int(written), nil)
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
        if let cached = item.cachedAttr {
            return cached
        }
        return try refreshAttributes(for: item)
    }

    private func refreshAttributes(for item: SpiderwebBridgeItem) throws -> SpiderwebRemoteAttr {
        try ensurePathIsNotBlocked(item.path)
        do {
            let attr = try runtime.ensureBridge().getattr(path: item.path)
            item.cachedAttr = attr
            clearBlockedPath(item.path)
            return attr
        } catch {
            let entryName = URL(fileURLWithPath: item.path).lastPathComponent
            let parent = parentPath(of: item.path)
            if isBridgeTimeoutError(error),
               shouldUseSyntheticEnumeration(in: parent),
               let fallbackAttr = syntheticFallbackAttr(forPath: item.path, entryName: entryName)
            {
                logger.warning("refreshAttributes falling back to synthetic attrs for \(item.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                item.cachedAttr = fallbackAttr
                noteFailure(for: item.path, error: error)
                return fallbackAttr
            }
            throw error
        }
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
        ]
        return request
    }

    private func requestedUnsupportedAttributeMutation(_ newAttributes: FSItem.SetAttributesRequest) -> Bool {
        newAttributes.isValid(.type) ||
            newAttributes.isValid(.linkCount) ||
            newAttributes.isValid(.allocSize) ||
            newAttributes.isValid(.fileID) ||
            newAttributes.isValid(.parentID) ||
            newAttributes.isValid(.changeTime)
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

    private func invalidateCachedPath(_ path: String) {
        let normalizedPath = normalize(path: path)
        stateLock.lock()
        if let item = pathToItem[normalizedPath] {
            item.cachedAttr = nil
        }
        blockedPaths.removeValue(forKey: normalizedPath)
        stateLock.unlock()
    }

    private func removeCachedPath(_ path: String) {
        let normalizedPath = normalize(path: path)
        stateLock.lock()
        if let item = pathToItem.removeValue(forKey: normalizedPath) {
            openStates.removeValue(forKey: item.itemIdentifier.rawValue)
        }
        blockedPaths.removeValue(forKey: normalizedPath)
        stateLock.unlock()
    }

    private func moveCachedPath(from oldPath: String, to newPath: String) {
        let normalizedOldPath = normalize(path: oldPath)
        let normalizedNewPath = normalize(path: newPath)
        stateLock.lock()
        if let item = pathToItem.removeValue(forKey: normalizedOldPath) {
            item.path = normalizedNewPath
            item.cachedAttr = nil
            pathToItem[normalizedNewPath] = item
        }
        blockedPaths.removeValue(forKey: normalizedOldPath)
        blockedPaths.removeValue(forKey: normalizedNewPath)
        stateLock.unlock()
    }

    private func ensureHandle(
        for item: SpiderwebBridgeItem,
        modes: FSVolume.OpenModes,
        retain: Bool = true
    ) throws -> SpiderwebBridgeOpenState {
        stateLock.lock()
        if var existing = openStates[item.itemIdentifier.rawValue] {
            let requestedModes = existing.modes.union(modes)
            let needsUpgrade = requestedModes.contains(.write) && !existing.modes.contains(.write)
            if !needsUpgrade {
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
            blockedPaths.removeValue(forKey: normalize(path: item.path))
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
        blockedPaths.removeValue(forKey: normalize(path: item.path))
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
        if let attr = item.cachedAttr {
            return attr
        }
        if let attr = syntheticFallbackAttr(forPath: item.path, entryName: entryName), shouldUseSyntheticEnumeration(in: parentPath) {
            item.cachedAttr = attr
            return attr
        }
        return nil
    }

    private func syntheticFallbackAttr(forPath path: String, entryName: String) -> SpiderwebRemoteAttr? {
        let normalizedPath = normalize(path: path)
        let kindCode: UInt8
        let mode: UInt32

        if isLikelyDirectoryEntry(path: normalizedPath, entryName: entryName) {
            kindCode = 2
            mode = 0o040755
        } else {
            kindCode = 1
            mode = 0o100644
        }

        let nowNS = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        return SpiderwebRemoteAttr(
            id: syntheticIdentifier(forPath: normalizedPath),
            kindCode: kindCode,
            mode: mode,
            linkCount: kindCode == 2 ? 2 : 1,
            uid: UInt32(getuid()),
            gid: UInt32(getgid()),
            size: 0,
            accessTimeNS: nowNS,
            modifyTimeNS: nowNS,
            changeTimeNS: nowNS
        )
    }

    private func shouldUseSyntheticEnumeration(in directoryPath: String) -> Bool {
        let normalized = normalize(path: directoryPath)
        return normalized == "/" ||
            normalized == "/agents" ||
            normalized == "/debug" ||
            normalized == "/global" ||
            normalized.hasPrefix("/global/") ||
            normalized == "/meta" ||
            normalized.hasPrefix("/meta/") ||
            normalized == "/projects" ||
            normalized.hasPrefix("/projects/") ||
            normalized == "/services" ||
            normalized.hasPrefix("/services/")
    }

    private func isLikelyDirectoryEntry(path: String, entryName: String) -> Bool {
        if entryName == "." || entryName == ".." {
            return true
        }
        let normalized = normalize(path: path)
        if normalized == "/" {
            return !entryName.contains(".")
        }
        if entryName.contains(".") {
            return false
        }
        return true
    }

    private func syntheticIdentifier(forPath path: String) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(path)
        return UInt64(bitPattern: Int64(hasher.finalize()))
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
