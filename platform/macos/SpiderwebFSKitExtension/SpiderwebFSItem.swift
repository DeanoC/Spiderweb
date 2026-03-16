/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A class that defines a custom item for use by the passthrough file system.
*/

import Foundation
import ExtensionFoundation
import FSKit
import OSLog

/// Defined item open modes.
enum SpiderwebFSItemOpenMode: Int32 {
    /// Close mode
    case close = -1
    /// Read-only mode
    case readOnly = 0
    /// Read and write mode
    case readWrite = 1
}

/// A SpiderwebFSItem represents a file system item.
class SpiderwebFSItem: FSItem {

    /// File descriptor of the item
    var fileDescriptor: Int32
    /// Open mode of the item
    var openMode: SpiderwebFSItemOpenMode
    /// Parent item (for a root item, the parent is nil)
    var parent: SpiderwebFSItem?
    /// Name of the item
    var name: String
    /// Item type
    var itemType: FSItem.ItemType
    /// Inode of the item (used to cache items in SpiderwebFSVolume)
    var inode: UInt64
    /// Dispatch queue for changing the item's SpiderwebFSItemOpenMode
    var openModeQueue: DispatchQueue

    /// Creates a new instance of SpiderwebFSItem, to create the root item.
    /// - Parameters:
    ///   - name: The name of the item.
    ///   - fileDescriptor: The file descriptor of the item.
    ///   - type: The type of the item.
    ///   - openFlags: The open mode of the item.
    init(name: String, fileDescriptor: Int32, type: FSItem.ItemType, openFlags: SpiderwebFSItemOpenMode) {
        self.name           = name
        self.parent         = nil
        self.fileDescriptor = fileDescriptor
        self.itemType       = type
        self.openMode       = openFlags
        self.inode          = 0
        self.openModeQueue = DispatchQueue(label: "com.apple.fskit.passthroughfs.item.\(name).openmode.queue")
        super.init()
        try? self.initInode()
    }

    /// Creates a new instance of SpiderwebFSItem.
    /// - Parameters:
    ///   - name: The name of the item.
    ///   - parent: The parent item.
    ///   - type: The type of the item.
    init(name: String, parent: SpiderwebFSItem, type: FSItem.ItemType) throws {
        self.name           = name
        self.parent         = parent
        self.openMode       = .close
        self.fileDescriptor = -1
        self.itemType       = type
        self.inode          = 0
        self.openModeQueue  = DispatchQueue(label: "com.apple.fskit.passthroughfs.item.\(name).openmode.queue")
        super.init()
        try self.upgradeOpenMode(mode: .readOnly)
        try self.initInode()
        try self.closeItem()
    }

    /// Initializes the inode number of the item.
    private func initInode() throws {
        var statResult = stat()
        _ = try throwErrno { fstat(self.fileDescriptor, &statResult) }
        self.inode = statResult.st_ino
    }

    /// Opens the item with given mode using `openat`, and if successful, returns a new file descriptor, otherwise throwing errno.
    ///
    /// In order for `openat` to work, the file system needs the parent's item file descriptor. If the parent doesn't have one,
    /// this method opens the parent item to get its file descriptor. After opening the item,
    /// this closes the parent item file descriptor, if it wasn't open before.
    private func openWithMode(mode: SpiderwebFSItemOpenMode) throws -> Int32 {
        guard let parent = self.parent else {
            Logger.passthroughfs.error("\(#function): The parent is nil, can't open the item (\(self.name))")
            return -1
        }
        var parentFD = parent.fileDescriptor
        let oldParentFD = parentFD

        // Check if the parent is open; if not, open it also.
        if oldParentFD == -1 {
            try parent.upgradeOpenMode(mode: .readOnly)
            parentFD = parent.fileDescriptor
        }

        // Convert SpiderwebFSItemOpenMode to O_RDONLY/O_RDWR.
        var convertedMode = O_RDONLY
        if mode == .readWrite {
            convertedMode = O_RDWR
        }
        // Open the file.
        let fileDescriptor = try throwErrno { openat(parentFD, self.name, convertedMode | O_SYMLINK) }

        // If the parent was closed, before opening the file, close it.
        if oldParentFD == -1 {
            try parent.closeItem()
        }

        // Return the file descriptor of the item.
        return fileDescriptor
    }

    /// Upgrades the open mode of the item to the given mode.
    ///
    /// Upgrade means that the item can go from .close to .readOnly to .readWrite.
    /// If the item was opened to a .readOnly and needs to upgrade to .readWrite, this method creates a new file descriptor for the .readWrite mode,
    /// and closes the old .readOnly file descriptor.
    func upgradeOpenMode(mode: SpiderwebFSItemOpenMode) throws {
        if mode == .close {
            Logger.passthroughfs.error("\(#function): Can't pass .close as mode")
            throw POSIXError(.EINVAL)
        }
        if (self.fileDescriptor != -1) && (self.openMode == .readWrite || self.openMode == mode) {
            // The item already has a file descriptor and mode is set, so there is nothing to do.
            return
        }

        try self.openModeQueue.sync {
            let oldFD = self.fileDescriptor
            try self.fileDescriptor = self.openWithMode(mode: mode)

            // With a new fileDescriptor set, close the old file descriptor if it exists.
            if oldFD > 0 {
                _ = try throwErrno { Darwin.close(oldFD) }
            }
            self.openMode = mode
        }
    }

    /// Closes the item by calling `close`.
    func closeItem() throws {
        try self.openModeQueue.sync {
            if self.fileDescriptor == -1 || self.openMode == .close {
                return
            }
            _ = try throwErrno { Darwin.close(self.fileDescriptor) }
            self.fileDescriptor = -1
            self.openMode = .close
        }
    }

}
