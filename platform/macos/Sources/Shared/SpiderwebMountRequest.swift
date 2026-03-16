import Darwin
import FSKit
import Foundation

struct SpiderwebMountRequest: Codable {
    struct LaunchConfig: Codable {
        struct Endpoint: Codable {
            let name: String
            let url: String
            let exportName: String?
            let mountPath: String
            let authToken: String?

            private enum CodingKeys: String, CodingKey {
                case name
                case url
                case exportName = "export_name"
                case mountPath = "mount_path"
                case authToken = "auth_token"
            }
        }

        struct Namespace: Codable {
            let namespaceURL: String
            let authToken: String?
            let projectID: String
            let agentID: String
            let sessionKey: String
            let projectToken: String?

            private enum CodingKeys: String, CodingKey {
                case namespaceURL = "namespace_url"
                case authToken = "auth_token"
                case projectID = "project_id"
                case agentID = "agent_id"
                case sessionKey = "session_key"
                case projectToken = "project_token"
            }
        }

        let schema: Int
        let mountpoint: String
        let workspaceSyncIntervalMS: UInt64
        let namespaceKeepaliveIntervalMS: UInt64
        let endpoints: [Endpoint]
        let namespace: Namespace?

        private enum CodingKeys: String, CodingKey {
            case schema
            case mountpoint
            case workspaceSyncIntervalMS = "workspace_sync_interval_ms"
            case namespaceKeepaliveIntervalMS = "namespace_keepalive_interval_ms"
            case endpoints
            case namespace
        }
    }

    let schema: Int
    let volumeName: String?
    let launchConfig: LaunchConfig

    private enum CodingKeys: String, CodingKey {
        case schema
        case volumeName = "volume_name"
        case launchConfig = "launch_config"
    }

    static func load(from url: URL) throws -> SpiderwebMountRequest {
        try JSONDecoder().decode(SpiderwebMountRequest.self, from: Data(contentsOf: url))
    }

    static func load(from resource: FSResource) throws -> SpiderwebMountRequest {
        return try load(from: try mountedResourceURL(from: resource))
    }

    var volumeNameOrDefault: String {
        if let volumeName, !volumeName.isEmpty {
            return volumeName
        }

        let trimmed = launchConfig.mountpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = URL(fileURLWithPath: "/" + trimmed).lastPathComponent
        return base.isEmpty ? "Spiderweb" : base
    }
}

func mountedResourceURL(from resource: FSResource) throws -> URL {
    let object = resource as AnyObject
    if let url = object.value(forKey: "url") as? URL {
        return url
    }
    let resourceClass = NSStringFromClass(type(of: object))
    throw SpiderwebFSKitBridgeError.invalidMountedResourceType(resourceClass)
}

struct SpiderwebRemoteAttr: Codable {
    let id: UInt64
    let kindCode: UInt8
    let mode: UInt32
    let linkCount: UInt32
    let uid: UInt32
    let gid: UInt32
    let size: UInt64
    let accessTimeNS: Int64
    let modifyTimeNS: Int64
    let changeTimeNS: Int64

    private enum CodingKeys: String, CodingKey {
        case id
        case kindCode = "k"
        case mode = "m"
        case linkCount = "n"
        case uid = "u"
        case gid = "g"
        case size = "sz"
        case accessTimeNS = "at"
        case modifyTimeNS = "mt"
        case changeTimeNS = "ct"
    }
}

struct SpiderwebRemoteDirectoryListing: Codable {
    struct Entry: Codable {
        let name: String
        let attr: SpiderwebRemoteAttr?
    }

    let entries: [Entry]
    let nextCookie: UInt64
    let eof: Bool
    let directoryGeneration: UInt64

    private enum CodingKeys: String, CodingKey {
        case entries = "ents"
        case nextCookie = "next_cookie"
        case eof
        case directoryGeneration = "dir_gen"
    }
}

struct SpiderwebRemoteStatFS: Codable {
    let blockSize: UInt64
    let fragmentSize: UInt64
    let totalBlocks: UInt64
    let freeBlocks: UInt64
    let availableBlocks: UInt64
    let totalFiles: UInt64
    let freeFiles: UInt64
    let availableFiles: UInt64
    let maximumNameLength: UInt64

    private enum CodingKeys: String, CodingKey {
        case blockSize = "bsize"
        case fragmentSize = "frsize"
        case totalBlocks = "blocks"
        case freeBlocks = "bfree"
        case availableBlocks = "bavail"
        case totalFiles = "files"
        case freeFiles = "ffree"
        case availableFiles = "favail"
        case maximumNameLength = "namemax"
    }
}

struct SpiderwebOpenHandleResponse {
    let handleID: UInt64
    let writable: Bool
}

enum SpiderwebFSKitBridgeError: LocalizedError {
    case bridgeFailure(String)
    case invalidMountedResourceType(String)
    case invalidFilenameEncoding

    var errorDescription: String? {
        switch self {
        case .bridgeFailure(let message):
            return message
        case .invalidMountedResourceType(let resourceClass):
            return "SpiderwebFSKit received unsupported mounted resource type \(resourceClass)"
        case .invalidFilenameEncoding:
            return "SpiderwebFSKit currently requires UTF-8 path components"
        }
    }
}

enum SpiderwebFSKitPaths {
    static let appGroupIdentifier = "group.com.deanoc.spiderweb.fskit"
    static let supportDirectoryName = "SpiderwebFSKit"

    static func fallbackContainerURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    static func sharedContainerURL() -> URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            } catch {
                NSLog(
                    "SpiderwebFSKit app group unavailable at %@ (%@); falling back to Application Support.",
                    url.path,
                    error.localizedDescription
                )
            }
        }
        return fallbackContainerURL()
    }
}

enum SpiderwebFSKitDebug {
    private static let lock = NSLock()

    static func log(_ message: String, file: StaticString = #fileID, function: StaticString = #function, line: UInt = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] pid=\(getpid()) \(file):\(line) \(function) \(message)\n"
        let baseURL = SpiderwebFSKitPaths.sharedContainerURL()
        let logURL = baseURL.appendingPathComponent("debug.log", isDirectory: false)

        lock.lock()
        defer { lock.unlock() }

        do {
            let data = Data(entry.utf8)
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: data)
                return
            }
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("SpiderwebFSKit debug logging failed: %@", error.localizedDescription)
        }
    }
}

struct SpiderwebRequestSummary: Identifiable {
    let id: String
    let url: URL
    let volumeName: String
    let mountpoint: String
    let modifiedAt: Date
}

struct SpiderwebNativeStatusSnapshot: Codable {
    let version: UInt8
    let registered: Bool
    let moduleEnabled: Bool
    let ready: Bool
    let filesystemBundlePresent: Bool
    let mountHelperPresent: Bool
    let runtimeReady: Bool
    let updatedAtMS: Int64

    private enum CodingKeys: String, CodingKey {
        case version
        case registered
        case moduleEnabled = "module_enabled"
        case ready
        case filesystemBundlePresent = "filesystem_bundle_present"
        case mountHelperPresent = "mount_helper_present"
        case runtimeReady = "runtime_ready"
        case updatedAtMS = "updated_at_ms"
    }
}

final class SpiderwebFSKitStateStore {
    private let fileManager: FileManager
    let baseURL: URL

    init(
        fileManager: FileManager = .default,
        baseURL: URL = SpiderwebFSKitPaths.sharedContainerURL()
    ) {
        self.fileManager = fileManager
        self.baseURL = baseURL
    }

    var requestsDirectoryURL: URL {
        baseURL.appendingPathComponent("Requests", isDirectory: true)
    }

    var nativeStatusURL: URL {
        baseURL.appendingPathComponent("native-status.json", isDirectory: false)
    }

    func prepareDirectories() throws {
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: requestsDirectoryURL, withIntermediateDirectories: true)
    }

    func recentRequests(limit: Int = 8) -> [SpiderwebRequestSummary] {
        do {
            try prepareDirectories()
            let urls = try fileManager.contentsOfDirectory(
                at: requestsDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )

            return urls.compactMap { url in
                guard let request = try? SpiderwebMountRequest.load(from: url) else {
                    return nil
                }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return SpiderwebRequestSummary(
                    id: url.lastPathComponent,
                    url: url,
                    volumeName: request.volumeNameOrDefault,
                    mountpoint: request.launchConfig.mountpoint,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(limit)
            .map { $0 }
        } catch {
            return []
        }
    }

    func nativeStatusSnapshot() -> SpiderwebNativeStatusSnapshot? {
        do {
            try prepareDirectories()
            let data = try Data(contentsOf: nativeStatusURL)
            return try JSONDecoder().decode(SpiderwebNativeStatusSnapshot.self, from: data)
        } catch {
            return nil
        }
    }
}
