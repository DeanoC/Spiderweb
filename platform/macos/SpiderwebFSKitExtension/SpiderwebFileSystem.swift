/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The custom class that implements a simplified file system.
*/

import Darwin
import Foundation
import FSKit
import OSLog

extension Logger {
    static let passthroughfs = Logger(subsystem: "com.apple.fskit.SpiderwebFSKit", category: "default")
    static let spiderwebfs = Logger(subsystem: "com.apple.fskit.SpiderwebFSKit", category: "spiderweb")
}

/// Returns the current `errno` value as a `POSIXError`.
var posixErrno: POSIXError {
    POSIXError(POSIXError.Code(rawValue: errno) ?? .EINVAL)
}

/// Returns the result of the given block, or throws an error if `errno` is nonzero.
/// - Parameter block: The block to execute.
func throwErrno<T: SignedInteger>(_ block: () throws -> T) throws -> T {
    let ret = try block()
    guard ret >= 0 else {
        guard errno != 0 else {
            Logger.passthroughfs.error("Call to block failed, and errno is not set")
            return ret
        }
        throw posixErrno
    }
    return ret
}

/// Returns a volume name made from the directory name of given path with a `_passthroughfs` suffix.
/// - Parameter path: The path to use to generate a volume name.
func createVolumeNameFromPath(_ path: String) -> FSFileName {
    let dirName = (path as NSString).lastPathComponent
    return FSFileName(string: dirName + "_passthrough")
}

private enum MountedResourceKind {
    case passthroughDirectory
    case spiderwebRequest
}

private func classifyMountedResource(_ url: URL) throws -> MountedResourceKind {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
    if values.isDirectory == true {
        return .passthroughDirectory
    }
    if url.pathExtension.lowercased() == "json" {
        return .spiderwebRequest
    }
    throw POSIXError(.ENOTSUP)
}

private func withSecurityScopedAccess<T>(to url: URL, _ body: () throws -> T) throws -> T {
    guard url.startAccessingSecurityScopedResource() else {
        throw POSIXError(.EACCES)
    }
    defer { url.stopAccessingSecurityScopedResource() }
    return try body()
}

/// A file system that either passes through a local directory or mounts a Spiderweb request JSON.
@objc
class SpiderwebFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
    private var passthroughResource: FSPathURLResource?

    public override init() {
        Logger.passthroughfs.debug("\(#function): init")
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.debug("\(#function): Invalid resource type")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        for opt in options.taskOptions {
            if opt.contains("-f") {
                return replyHandler(nil, POSIXError(.ENOTSUP))
            }
        }

        do {
            switch try classifyMountedResource(urlResource.url) {
            case .passthroughDirectory:
                guard urlResource.url.startAccessingSecurityScopedResource() else {
                    Logger.passthroughfs.error("\(#function): Can't start accessing security scoped resource")
                    return replyHandler(nil, POSIXError(.EACCES))
                }
                passthroughResource = urlResource
                containerStatus = .ready
                replyHandler(try SpiderwebFSVolume(rootPath: urlResource.url.path), nil)

            case .spiderwebRequest:
                passthroughResource = nil
                containerStatus = .ready
                replyHandler(try SpiderwebBridgeVolume(requestURL: urlResource.url), nil)
            }
        } catch {
            passthroughResource?.url.stopAccessingSecurityScopedResource()
            passthroughResource = nil
            replyHandler(nil, error)
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = options
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.error("\(#function): Can't cast resource")
            return reply(POSIXError(.EINVAL))
        }

        if let loadedResource = passthroughResource {
            guard loadedResource.url == urlResource.url else {
                Logger.passthroughfs.error("\(#function): Invalid resource was given to unload")
                return reply(POSIXError(.EINVAL))
            }
            loadedResource.url.stopAccessingSecurityScopedResource()
            passthroughResource = nil
        }

        reply(nil)
    }

    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.passthroughfs.debug("\(#function): Can't cast resource")
            return replyHandler(nil, POSIXError(.ENODEV))
        }

        do {
            let name: String
            switch try classifyMountedResource(urlResource.url) {
            case .passthroughDirectory:
                name = createVolumeNameFromPath(urlResource.url.path).string ?? "Spiderweb FSKit"
            case .spiderwebRequest:
                name = try withSecurityScopedAccess(to: urlResource.url) {
                    try SpiderwebMountRequest.load(from: urlResource.url).volumeNameOrDefault
                }
            }

            let containerUUID = NSUUID()
            let containerIdentifier = FSContainerIdentifier(uuid: containerUUID as UUID)
            replyHandler(FSProbeResult.usable(name: name, containerID: containerIdentifier), nil)
        } catch {
            replyHandler(nil, error)
        }
    }
}

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

    var volumeNameOrDefault: String {
        if let volumeName, !volumeName.isEmpty {
            return volumeName
        }
        let trimmed = launchConfig.mountpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = URL(fileURLWithPath: "/" + trimmed).lastPathComponent
        return base.isEmpty ? "Spiderweb" : base
    }
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

struct SpiderwebRemoteDirectoryListing: Decodable {
    struct Entry: Decodable {
        let name: String
        let attr: SpiderwebRemoteAttr?
    }

    let entries: [Entry]
    let nextCookie: UInt64
    let eof: Bool
    let directoryGeneration: UInt64

    private enum CodingKeys: String, CodingKey {
        case entries = "ents"
        case next
        case nextCookie = "next_cookie"
        case eof
        case directoryGeneration = "dir_gen"
    }

    init(entries: [Entry], nextCookie: UInt64, eof: Bool, directoryGeneration: UInt64) {
        self.entries = entries
        self.nextCookie = nextCookie
        self.eof = eof
        self.directoryGeneration = directoryGeneration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entries = try container.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        nextCookie = try container.decodeIfPresent(UInt64.self, forKey: .nextCookie)
            ?? container.decodeIfPresent(UInt64.self, forKey: .next)
            ?? 0
        eof = try container.decodeIfPresent(Bool.self, forKey: .eof) ?? (nextCookie == 0)
        directoryGeneration = try container.decodeIfPresent(UInt64.self, forKey: .directoryGeneration) ?? 1
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

enum SpiderwebBridgeError: LocalizedError {
    case invalidURL(String)
    case invalidEnvelope
    case invalidFilenameEncoding
    case invalidMountedResourceType(String)
    case unexpectedMessage(String)
    case missingNamespaceBinding
    case unsupportedFrame

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid Spiderweb namespace URL: \(value)"
        case .invalidEnvelope:
            return "Spiderweb returned an invalid envelope"
        case .invalidFilenameEncoding:
            return "SpiderwebFS currently requires UTF-8 path components"
        case .invalidMountedResourceType(let value):
            return "Unsupported mounted resource type \(value)"
        case .unexpectedMessage(let value):
            return "Unexpected Spiderweb message: \(value)"
        case .missingNamespaceBinding:
            return "Spiderweb mount request is missing launch_config.namespace"
        case .unsupportedFrame:
            return "Spiderweb returned an unsupported websocket frame"
        }
    }
}

final class SpiderwebMountRuntime {
    let request: SpiderwebMountRequest

    private let requestURL: URL
    private let bridge: SpiderwebNamespaceBridge
    private var scopedAccessActive = false

    init(requestURL: URL) throws {
        self.requestURL = requestURL
        guard requestURL.startAccessingSecurityScopedResource() else {
            throw POSIXError(.EACCES)
        }
        scopedAccessActive = true
        do {
            request = try SpiderwebMountRequest.load(from: requestURL)
            bridge = SpiderwebNamespaceBridge(request: request)
        } catch {
            requestURL.stopAccessingSecurityScopedResource()
            scopedAccessActive = false
            throw error
        }
    }

    deinit {
        shutdown()
    }

    func ensureBridge() throws -> SpiderwebNamespaceBridge {
        try bridge.launchIfNeeded()
        try bridge.requireMountedRPCBridge()
        return bridge
    }

    func shutdown() {
        bridge.stop()
        if scopedAccessActive {
            requestURL.stopAccessingSecurityScopedResource()
            scopedAccessActive = false
        }
    }
}

private let spiderwebControlProtocol = "unified-v2"
private let spiderwebAcheronRuntimeVersion = "acheron-1"

let syntheticStatFS = SpiderwebRemoteStatFS(
    blockSize: 65_536,
    fragmentSize: 65_536,
    totalBlocks: 1,
    freeBlocks: 1,
    availableBlocks: 1,
    totalFiles: 1_048_576,
    freeFiles: 1_048_575,
    availableFiles: 1_048_575,
    maximumNameLength: 4_096
)

private struct SpiderwebNamespaceStat {
    enum Kind {
        case directory
        case file
    }

    let id: UInt64
    let kind: Kind
    let size: UInt64
    let mode: UInt32
    let writable: Bool
}

private struct SpiderwebNamespaceHandleState {
    var path: String
    var fid: UInt32
    var flags: UInt32
    var writable: Bool
}

private enum SpiderwebProtocolFailure: LocalizedError {
    case invalidURL(String)
    case invalidEnvelope
    case unexpectedMessage(String)
    case unsupportedFrame
    case missingNamespaceBinding

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "Invalid namespace URL: \(value)"
        case .invalidEnvelope:
            return "Spiderweb returned an invalid envelope"
        case .unexpectedMessage(let value):
            return "Spiderweb returned an unexpected message: \(value)"
        case .unsupportedFrame:
            return "Spiderweb returned a non-text websocket frame"
        case .missingNamespaceBinding:
            return "Spiderweb native mounts currently require launch_config.namespace"
        }
    }
}

actor SpiderwebNamespaceSession {
    private let logger = Logger.spiderwebfs
    private let request: SpiderwebMountRequest

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var nextControlID: UInt64 = 1
    private var nextTag: UInt32 = 1
    private var nextHandleID: UInt64 = 1
    private var rootAttached = false
    private var openHandles: [UInt64: SpiderwebNamespaceHandleState] = [:]

    init(request: SpiderwebMountRequest) {
        self.request = request
    }

    func launchIfNeeded() async throws {
        if webSocketTask != nil {
            return
        }
        try await connectFresh()
    }

    func shutdown() async {
        await tearDown()
    }

    func ping() async throws {
        _ = try await getattr(path: "/")
    }

    func getattr(path: String) async throws -> SpiderwebRemoteAttr {
        let stat = try await withReconnect { session in
            try await session.statPath(path)
        }
        return remoteAttr(from: stat)
    }

    func readdir(path: String, cookie: UInt64, maxEntries: UInt32) async throws -> SpiderwebRemoteDirectoryListing {
        try await withReconnect { session in
            try await session.readDirectory(path: path, cookie: cookie, maxEntries: maxEntries)
        }
    }

    func statfs(path: String) async throws -> SpiderwebRemoteStatFS {
        _ = path
        try await launchIfNeeded()
        return syntheticStatFS
    }

    func open(path: String, flags: UInt32) async throws -> SpiderwebOpenHandleResponse {
        try await withReconnect { session in
            try await session.openFile(path: path, flags: flags)
        }
    }

    func read(handleID: UInt64, offset: UInt64, length: UInt32) async throws -> Data {
        try await withReconnect { session in
            try await session.readFile(handleID: handleID, offset: offset, length: length)
        }
    }

    func release(handleID: UInt64) async throws {
        try await withReconnect { session in
            try await session.closeFile(handleID: handleID)
        }
    }

    private func withReconnect<T>(_ operation: (SpiderwebNamespaceSession) async throws -> T) async throws -> T {
        do {
            try await launchIfNeeded()
            return try await operation(self)
        } catch {
            if !isRecoverableTransportError(error) {
                throw error
            }
            logger.warning("Reconnecting Spiderweb namespace session after transport error: \(error.localizedDescription, privacy: .public)")
            try await reconnect()
            return try await operation(self)
        }
    }

    private func connectFresh() async throws {
        guard let namespace = request.launchConfig.namespace else {
            throw SpiderwebProtocolFailure.missingNamespaceBinding
        }
        guard let url = URL(string: namespace.namespaceURL) else {
            throw SpiderwebProtocolFailure.invalidURL(namespace.namespaceURL)
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.waitsForConnectivity = true
        let urlSession = URLSession(configuration: sessionConfiguration)
        var urlRequest = URLRequest(url: url)
        if let authToken = namespace.authToken, !authToken.isEmpty {
            urlRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        let task = urlSession.webSocketTask(with: urlRequest)
        task.resume()

        self.urlSession = urlSession
        self.webSocketTask = task
        self.rootAttached = false

        try await negotiateControlAndAttach(namespace: namespace)
    }

    private func reconnect() async throws {
        let existingHandles = openHandles
        await tearDown()
        try await connectFresh()

        if existingHandles.isEmpty {
            return
        }

        var restored: [UInt64: SpiderwebNamespaceHandleState] = [:]
        for (handleID, state) in existingHandles {
            let response = try await openFile(path: state.path, flags: state.flags)
            guard let refreshed = openHandles.removeValue(forKey: response.handleID) else {
                continue
            }
            restored[handleID] = refreshed
        }
        openHandles = restored
    }

    private func tearDown() async {
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        rootAttached = false
        openHandles.removeAll()
    }

    private func negotiateControlAndAttach(namespace: SpiderwebMountRequest.LaunchConfig.Namespace) async throws {
        _ = try await sendControlRequest(
            type: "control.version",
            expectedType: "control.version_ack",
            payload: ["protocol": spiderwebControlProtocol]
        )

        _ = try await sendControlRequest(
            type: "control.connect",
            expectedType: "control.connect_ack",
            payload: [:]
        )

        _ = try await sendControlRequest(
            type: "control.agent_ensure",
            expectedType: "control.agent_ensure",
            payload: ["agent_id": namespace.agentID]
        )

        var attachPayload: [String: Any] = [
            "session_key": namespace.sessionKey,
            "agent_id": namespace.agentID,
            "project_id": namespace.projectID,
        ]
        if let projectToken = namespace.projectToken, !projectToken.isEmpty {
            attachPayload["project_token"] = projectToken
        }
        _ = try await sendControlRequest(
            type: "control.session_attach",
            expectedType: "control.session_attach",
            payload: attachPayload
        )

        _ = try await sendAcheronRequest(
            type: "acheron.t_version",
            expectedType: "acheron.r_version",
            fields: [
                "msize": 1_048_576,
                "version": spiderwebAcheronRuntimeVersion,
            ]
        )
        _ = try await sendAcheronRequest(
            type: "acheron.t_attach",
            expectedType: "acheron.r_attach",
            fields: ["fid": 1]
        )
        rootAttached = true
    }

    private func sendControlRequest(type: String, expectedType: String, payload: [String: Any]) async throws -> [String: Any] {
        let requestID = nextControlRequestID()
        let envelope: [String: Any] = [
            "channel": "control",
            "type": type,
            "id": requestID,
            "payload": payload,
        ]
        try await sendEnvelope(envelope)
        while true {
            let envelope = try await receiveEnvelope()
            guard stringValue(envelope["channel"]) == "control" else {
                continue
            }
            guard stringValue(envelope["id"]) == requestID else {
                continue
            }
            let messageType = stringValue(envelope["type"]) ?? ""
            if messageType == "control.error" {
                throw mapControlError(envelope)
            }
            guard messageType == expectedType else {
                throw SpiderwebProtocolFailure.unexpectedMessage(messageType)
            }
            return envelope
        }
    }

    private func sendAcheronRequest(type: String, expectedType: String, fields: [String: Any]) async throws -> [String: Any] {
        let tag = nextAcheronTag()
        var envelope: [String: Any] = [
            "channel": "acheron",
            "type": type,
            "tag": tag,
        ]
        for (key, value) in fields {
            envelope[key] = value
        }
        try await sendEnvelope(envelope)
        while true {
            let envelope = try await receiveEnvelope()
            guard stringValue(envelope["channel"]) == "acheron" else {
                continue
            }
            guard uint32Value(envelope["tag"]) == tag else {
                continue
            }
            let messageType = stringValue(envelope["type"]) ?? ""
            if messageType == "acheron.error" || messageType == "acheron.err_fs" {
                throw mapAcheronError(envelope)
            }
            guard messageType == expectedType else {
                throw SpiderwebProtocolFailure.unexpectedMessage(messageType)
            }
            return envelope
        }
    }

    private func sendEnvelope(_ envelope: [String: Any]) async throws {
        guard let task = webSocketTask else {
            throw URLError(.networkConnectionLost)
        }
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [])
        guard let text = String(data: data, encoding: .utf8) else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }
        try await task.send(.string(text))
    }

    private func receiveEnvelope() async throws -> [String: Any] {
        guard let task = webSocketTask else {
            throw URLError(.networkConnectionLost)
        }
        let message = try await task.receive()
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            guard let value = String(data: data, encoding: .utf8) else {
                throw SpiderwebProtocolFailure.unsupportedFrame
            }
            text = value
        @unknown default:
            throw SpiderwebProtocolFailure.unsupportedFrame
        }
        guard
            let data = text.data(using: .utf8),
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }
        return raw
    }

    private func statPath(_ path: String) async throws -> SpiderwebNamespaceStat {
        let fid = try await walkPathToNewFid(path)
        defer { Task { try? await self.clunk(fid: fid) } }
        return try await statFid(fid: fid)
    }

    private func statFid(fid: UInt32) async throws -> SpiderwebNamespaceStat {
        let envelope = try await sendAcheronRequest(
            type: "acheron.t_stat",
            expectedType: "acheron.r_stat",
            fields: ["fid": fid]
        )
        guard let payload = envelope["payload"] as? [String: Any] else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }
        return try parseNamespaceStat(payload: payload)
    }

    private func readDirectory(path: String, cookie: UInt64, maxEntries: UInt32) async throws -> SpiderwebRemoteDirectoryListing {
        let stat = try await statPath(path)
        guard stat.kind == .directory else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR), userInfo: [NSLocalizedDescriptionKey: "Not a directory"])
        }

        let fid = try await walkPathToNewFid(path)
        defer { Task { try? await self.clunk(fid: fid) } }
        try await openFid(fid: fid, mode: "r")
        let listingData = try await readAll(fid: fid, initialOffset: 0, maxBytes: 1_048_576)
        let listingText = String(data: listingData, encoding: .utf8) ?? ""

        var names = [".", ".."]
        for line in listingText.split(separator: "\n", omittingEmptySubsequences: true) {
            names.append(String(line))
        }

        let startIndex = Int(clamping: cookie)
        if startIndex >= names.count {
            return SpiderwebRemoteDirectoryListing(entries: [], nextCookie: 0, eof: true, directoryGeneration: 1)
        }

        let maxCount = maxEntries == 0 ? 0 : Int(maxEntries)
        let endIndex = min(names.count, startIndex + maxCount)
        let eof = endIndex >= names.count
        var entries: [SpiderwebRemoteDirectoryListing.Entry] = []
        for name in names[startIndex..<endIndex] {
            entries.append(.init(name: name, attr: nil))
        }
        return SpiderwebRemoteDirectoryListing(
            entries: entries,
            nextCookie: eof ? 0 : UInt64(endIndex),
            eof: eof,
            directoryGeneration: 1
        )
    }

    private func openFile(path: String, flags: UInt32) async throws -> SpiderwebOpenHandleResponse {
        let stat = try await statPath(path)
        let fid = try await walkPathToNewFid(path)
        do {
            try await openFid(fid: fid, mode: flagsRequireWrite(flags) ? "rw" : "r")
        } catch {
            try? await clunk(fid: fid)
            throw error
        }

        let handleID = nextHandleID
        nextHandleID &+= 1
        openHandles[handleID] = SpiderwebNamespaceHandleState(
            path: path,
            fid: fid,
            flags: flags,
            writable: stat.writable
        )
        return SpiderwebOpenHandleResponse(handleID: handleID, writable: stat.writable)
    }

    private func closeFile(handleID: UInt64) async throws {
        guard let state = openHandles.removeValue(forKey: handleID) else {
            return
        }
        try await clunk(fid: state.fid)
    }

    private func readFile(handleID: UInt64, offset: UInt64, length: UInt32) async throws -> Data {
        guard let state = openHandles[handleID] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb handle"])
        }
        return try await readFid(fid: state.fid, offset: offset, count: length)
    }

    private func walkPathToNewFid(_ path: String) async throws -> UInt32 {
        guard rootAttached else {
            throw URLError(.networkConnectionLost)
        }

        let normalized = normalizeAbsolutePath(path)
        let segments = normalized == "/" ? [] : normalized
            .split(separator: "/")
            .filter { !$0.isEmpty && $0 != "." }
            .map(String.init)

        let fid = nextFid()
        _ = try await sendAcheronRequest(
            type: "acheron.t_walk",
            expectedType: "acheron.r_walk",
            fields: [
                "fid": 1,
                "newfid": fid,
                "path": segments,
            ]
        )
        return fid
    }

    private func openFid(fid: UInt32, mode: String) async throws {
        _ = try await sendAcheronRequest(
            type: "acheron.t_open",
            expectedType: "acheron.r_open",
            fields: [
                "fid": fid,
                "mode": mode,
            ]
        )
    }

    private func clunk(fid: UInt32) async throws {
        _ = try await sendAcheronRequest(
            type: "acheron.t_clunk",
            expectedType: "acheron.r_clunk",
            fields: ["fid": fid]
        )
    }

    private func readAll(fid: UInt32, initialOffset: UInt64, maxBytes: Int) async throws -> Data {
        var result = Data()
        var offset = initialOffset
        while result.count < maxBytes {
            let remaining = maxBytes - result.count
            let count = UInt32(min(remaining, 64 * 1024))
            let chunk = try await readFid(fid: fid, offset: offset, count: count)
            if chunk.isEmpty {
                break
            }
            result.append(chunk)
            offset += UInt64(chunk.count)
            if chunk.count < Int(count) {
                break
            }
        }
        return result
    }

    private func readFid(fid: UInt32, offset: UInt64, count: UInt32) async throws -> Data {
        let envelope = try await sendAcheronRequest(
            type: "acheron.t_read",
            expectedType: "acheron.r_read",
            fields: [
                "fid": fid,
                "offset": offset,
                "count": count,
            ]
        )
        guard
            let payload = envelope["payload"] as? [String: Any],
            let dataB64 = stringValue(payload["data_b64"]),
            let data = Data(base64Encoded: dataB64)
        else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }
        return data
    }

    private func parseNamespaceStat(payload: [String: Any]) throws -> SpiderwebNamespaceStat {
        guard
            let id = uint64Value(payload["id"]),
            let size = uint64Value(payload["size"]),
            let mode = uint32Value(payload["mode"]),
            let kindString = stringValue(payload["kind"])
        else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }

        let kind: SpiderwebNamespaceStat.Kind
        switch kindString {
        case "dir":
            kind = .directory
        case "file":
            kind = .file
        default:
            throw SpiderwebProtocolFailure.unexpectedMessage(kindString)
        }

        return SpiderwebNamespaceStat(
            id: id,
            kind: kind,
            size: size,
            mode: mode,
            writable: boolValue(payload["writable"]) ?? false
        )
    }

    private func remoteAttr(from stat: SpiderwebNamespaceStat) -> SpiderwebRemoteAttr {
        let kindCode: UInt8 = stat.kind == .directory ? 2 : 1
        let mode = stat.mode == 0
            ? (stat.kind == .directory ? UInt32(0o040755) : UInt32(0o100644))
            : stat.mode
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        return SpiderwebRemoteAttr(
            id: stat.id,
            kindCode: kindCode,
            mode: mode,
            linkCount: stat.kind == .directory ? 2 : 1,
            uid: UInt32(getuid()),
            gid: UInt32(getgid()),
            size: stat.size,
            accessTimeNS: now,
            modifyTimeNS: now,
            changeTimeNS: now
        )
    }

    private func nextControlRequestID() -> String {
        defer { nextControlID &+= 1 }
        return "swift-control-\(nextControlID)"
    }

    private func nextAcheronTag() -> UInt32 {
        defer { nextTag &+= 1 }
        if nextTag == 0 {
            nextTag = 1
        }
        return nextTag
    }

    private func nextFid() -> UInt32 {
        defer { nextTag &+= 1 }
        if nextTag <= 1 {
            nextTag = 2
        }
        return nextTag
    }
}

final class SpiderwebNamespaceBridge {
    private let session: SpiderwebNamespaceSession

    init(request: SpiderwebMountRequest) {
        session = SpiderwebNamespaceSession(request: request)
    }

    func launchIfNeeded() throws {
        try perform(operationName: "launchIfNeeded") { [session] in
            try await session.launchIfNeeded()
        }
    }

    func stop() {
        Task {
            await session.shutdown()
        }
    }

    func requireMountedRPCBridge() throws {
        try perform(operationName: "ping") { [session] in
            try await session.ping()
        }
    }

    func getattr(path: String) throws -> SpiderwebRemoteAttr {
        try perform(operationName: "getattr(\(path))") { [session] in
            try await session.getattr(path: path)
        }
    }

    func readdir(path: String, cookie: UInt64, maxEntries: UInt32) throws -> SpiderwebRemoteDirectoryListing {
        try perform(operationName: "readdir(\(path))") { [session] in
            try await session.readdir(path: path, cookie: cookie, maxEntries: maxEntries)
        }
    }

    func statfs(path: String) throws -> SpiderwebRemoteStatFS {
        try perform(operationName: "statfs(\(path))") { [session] in
            try await session.statfs(path: path)
        }
    }

    func open(path: String, flags: UInt32) throws -> SpiderwebOpenHandleResponse {
        try perform(operationName: "open(\(path))") { [session] in
            try await session.open(path: path, flags: flags)
        }
    }

    func read(handleID: UInt64, offset: UInt64, length: UInt32) throws -> Data {
        try perform(operationName: "read(handle:\(handleID))") { [session] in
            try await session.read(handleID: handleID, offset: offset, length: length)
        }
    }

    func release(handleID: UInt64) throws {
        try perform(operationName: "release(handle:\(handleID))") { [session] in
            try await session.release(handleID: handleID)
        }
    }

    private func perform<T>(operationName: String, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
        do {
            return try runBlocking(operationName: operationName, operation)
        } catch {
            if isBridgeTimeoutError(error) {
                stop()
            }
            throw error
        }
    }
}

private let spiderwebBridgeTimeoutMS: UInt64 = {
    let value = ProcessInfo.processInfo.environment["SPIDERWEB_FSKIT_TIMEOUT_MS"]
        ?? ProcessInfo.processInfo.environment["SPIDERWEB_TIMEOUT_MS"]
    if let value, let parsed = UInt64(value), parsed > 0 {
        return parsed
    }
    return 2_000
}()

let spiderwebFailFastCooldownMS: UInt64 = {
    let value = ProcessInfo.processInfo.environment["SPIDERWEB_FSKIT_FAIL_FAST_MS"]
        ?? ProcessInfo.processInfo.environment["SPIDERWEB_FAIL_FAST_MS"]
    if let value, let parsed = UInt64(value) {
        return parsed
    }
    return 10_000
}()

private func runBlocking<T>(operationName: String, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var outcome: Result<T, Error>?
    let task = Task {
        do {
            let value = try await operation()
            lock.lock()
            outcome = .success(value)
            lock.unlock()
        } catch {
            lock.lock()
            outcome = .failure(error)
            lock.unlock()
        }
        semaphore.signal()
    }

    let deadline = DispatchTime.now() + .milliseconds(Int(spiderwebBridgeTimeoutMS))
    guard semaphore.wait(timeout: deadline) == .success else {
        task.cancel()
        throw timeoutError(operationName: operationName, timeoutMS: spiderwebBridgeTimeoutMS)
    }

    lock.lock()
    defer { lock.unlock() }
    return try outcome!.get()
}

func join(directoryPath: String, childName: String) -> String {
    let normalizedDirectory = normalizeAbsolutePath(directoryPath)
    if normalizedDirectory == "/" {
        return "/" + childName
    }
    return normalizedDirectory + "/" + childName
}

func normalizeAbsolutePath(_ path: String) -> String {
    if path.isEmpty || path == "/" {
        return "/"
    }
    if path.count > 1 && path.hasSuffix("/") {
        return path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }
    return path
}

private func flagsRequireWrite(_ flags: UInt32) -> Bool {
    (flags & 0x3) != 0
}

private func stringValue(_ value: Any?) -> String? {
    value as? String
}

private func uint32Value(_ value: Any?) -> UInt32? {
    switch value {
    case let number as NSNumber:
        return number.uint32Value
    case let number as UInt32:
        return number
    case let number as UInt64:
        return UInt32(exactly: number)
    default:
        return nil
    }
}

private func uint64Value(_ value: Any?) -> UInt64? {
    switch value {
    case let number as NSNumber:
        return number.uint64Value
    case let number as UInt64:
        return number
    case let number as UInt32:
        return UInt64(number)
    default:
        return nil
    }
}

private func boolValue(_ value: Any?) -> Bool? {
    value as? Bool
}

private func mapControlError(_ envelope: [String: Any]) -> NSError {
    let details = envelope["error"] as? [String: Any]
    let code = stringValue(details?["code"]) ?? "control_error"
    let message = stringValue(details?["message"]) ?? "Spiderweb control request failed"
    return mapCodeToNSError(code: code, message: message)
}

private func mapAcheronError(_ envelope: [String: Any]) -> NSError {
    let details = envelope["error"] as? [String: Any]
    if let errno = (details?["errno"] as? NSNumber)?.int32Value {
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: stringValue(details?["message"]) ?? "Spiderweb filesystem request failed"]
        )
    }
    let code = stringValue(details?["code"]) ?? "acheron_error"
    let message = stringValue(details?["message"]) ?? "Spiderweb acheron request failed"
    return mapCodeToNSError(code: code, message: message)
}

private func mapCodeToNSError(code: String, message: String) -> NSError {
    let posixCode: Int32
    switch code {
    case "enoent":
        posixCode = ENOENT
    case "eacces":
        posixCode = EACCES
    case "enotdir":
        posixCode = ENOTDIR
    case "eisdir":
        posixCode = EISDIR
    case "eexist":
        posixCode = EEXIST
    case "enodata":
        posixCode = ENODATA
    case "enospc":
        posixCode = ENOSPC
    case "erange":
        posixCode = ERANGE
    case "eagain":
        posixCode = EAGAIN
    case "exdev":
        posixCode = EXDEV
    case "erofs":
        posixCode = EROFS
    case "enosys":
        posixCode = ENOSYS
    case "einval":
        posixCode = EINVAL
    default:
        posixCode = EIO
    }
    return NSError(domain: NSPOSIXErrorDomain, code: Int(posixCode), userInfo: [NSLocalizedDescriptionKey: message])
}

func readOnlyError(message: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS), userInfo: [NSLocalizedDescriptionKey: message])
}

func timeoutError(operationName: String, timeoutMS: UInt64) -> NSError {
    NSError(
        domain: NSPOSIXErrorDomain,
        code: Int(ETIMEDOUT),
        userInfo: [NSLocalizedDescriptionKey: "Spiderweb operation \(operationName) timed out after \(timeoutMS)ms"]
    )
}

func isBridgeTimeoutError(_ error: Error) -> Bool {
    let nsError = error as NSError
    return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ETIMEDOUT)
}

private func isRecoverableTransportError(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .timedOut:
            return true
        default:
            return false
        }
    }
    return false
}
