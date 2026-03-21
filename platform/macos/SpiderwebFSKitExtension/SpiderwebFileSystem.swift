/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The Spiderweb-specific FSKit file system entrypoint.
*/

import Darwin
import Foundation
import FSKit
import OSLog

extension Logger {
    static let spiderwebfs = Logger(subsystem: "com.deanoc.spiderweb.fskit", category: "filesystem")
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
            Logger.spiderwebfs.error("Call to block failed, and errno is not set")
            return ret
        }
        throw posixErrno
    }
    return ret
}

private func validateMountedRequestURL(_ url: URL) throws {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
    if values.isDirectory == true {
        throw POSIXError(.ENOTSUP)
    }
    guard url.pathExtension.lowercased() == "json" else {
        throw POSIXError(.ENOTSUP)
    }
}

/// A file system that mounts Spiderweb request JSONs.
@objc
class SpiderwebFileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
    private var mountedRequestResource: FSPathURLResource?

    public override init() {
        Logger.spiderwebfs.debug("\(#function): init")
    }

    public func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.spiderwebfs.debug("\(#function): Invalid resource type")
            return replyHandler(nil, POSIXError(.EINVAL))
        }

        for opt in options.taskOptions {
            if opt.contains("-f") {
                return replyHandler(nil, POSIXError(.ENOTSUP))
            }
        }

        do {
            try validateMountedRequestURL(urlResource.url)
            mountedRequestResource = urlResource
            containerStatus = .ready
            replyHandler(try SpiderwebBridgeVolume(requestURL: urlResource.url), nil)
        } catch {
            mountedRequestResource = nil
            replyHandler(nil, error)
        }
    }

    public func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler reply: @escaping ((any Error)?) -> Void) {
        _ = options
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.spiderwebfs.error("\(#function): Can't cast resource")
            return reply(POSIXError(.EINVAL))
        }

        if let loadedResource = mountedRequestResource {
            guard loadedResource.url == urlResource.url else {
                Logger.spiderwebfs.error("\(#function): Invalid resource was given to unload")
                return reply(POSIXError(.EINVAL))
            }
            mountedRequestResource = nil
        }

        reply(nil)
    }

    public func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, (any Error)?) -> Void) {
        guard let urlResource = resource as? FSPathURLResource else {
            Logger.spiderwebfs.debug("\(#function): Can't cast resource")
            return replyHandler(nil, POSIXError(.ENODEV))
        }

        do {
            try validateMountedRequestURL(urlResource.url)
            // Keep probe cheap and deterministic. The real request file is loaded in
            // `loadResource`; reading/parsing it here has proven fragile in FSKit's
            // synchronous probe callback.
            let basename = urlResource.url.deletingPathExtension().lastPathComponent
            let name = basename.isEmpty ? "Spiderweb" : basename

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
    let flags: UInt32?
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
        case flags = "fl"
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

struct SpiderwebCreateHandleResponse {
    let handleID: UInt64
    let attr: SpiderwebRemoteAttr
    let writable: Bool
}

struct SpiderwebSetAttrRequest {
    let mode: UInt32?
    let uid: UInt32?
    let gid: UInt32?
    let flags: UInt32?
    let accessTimeNS: Int64?
    let modifyTimeNS: Int64?

    var isEmpty: Bool {
        mode == nil && uid == nil && gid == nil && flags == nil && accessTimeNS == nil && modifyTimeNS == nil
    }
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
    private let bridge: SpiderwebMountedBridge
    private var scopedAccessActive = false

    init(requestURL: URL) throws {
        self.requestURL = requestURL
        guard requestURL.startAccessingSecurityScopedResource() else {
            throw POSIXError(.EACCES)
        }
        scopedAccessActive = true
        do {
            request = try SpiderwebMountRequest.load(from: requestURL)
            bridge = SpiderwebMountedBridge(request: request)
        } catch {
            requestURL.stopAccessingSecurityScopedResource()
            scopedAccessActive = false
            throw error
        }
    }

    deinit {
        shutdown()
    }

    func ensureBridge() throws -> SpiderwebMountedBridge {
        // Mounted workspace paths always resolve through Spiderweb's namespace
        // session. The mount backends do not implement their own path routing.
        return bridge
    }

    func isWritablePath(_ path: String) -> Bool {
        bridge.isWritablePath(path)
    }

    func syntheticAttrHint(path: String) -> SpiderwebRemoteAttr? {
        bridge.syntheticAttrHint(path: path)
    }

    func performanceSnapshot() -> SpiderwebRemoteOperationSnapshot {
        bridge.performanceSnapshot()
    }

    func setInvalidationHandler(_ handler: @escaping @Sendable (SpiderwebMountedInvalidation) -> Void) {
        bridge.setInvalidationHandler(handler)
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
private let spiderwebNodeFsProtocol = "unified-v2-fs"
private let spiderwebNodeFsProto: UInt32 = 2

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

private enum SpiderwebMountGraphNodeKind: String, Codable {
    case syntheticDirectory = "synthetic_directory"
    case syntheticFile = "synthetic_file"
    case alias
    case exportRoot = "export_root"
}

private enum SpiderwebSyntheticContentMode: String, Codable {
    case inlineSnapshot = "inline_snapshot"
    case deltaSnapshot = "delta_snapshot"
    case remoteRead = "remote_read"
    case remoteRW = "remote_rw"
    case writeOnlyCommand = "write_only_command"
}

private struct SpiderwebMountGraphSource: Codable {
    let id: String
    let mountPath: String
    let fsURL: String
    let exportName: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case mountPath = "mount_path"
        case fsURL = "fs_url"
        case exportName = "export_name"
    }
}

private struct SpiderwebMountGraphNode: Codable {
    let id: UInt64
    let parentID: UInt64?
    let name: String
    let path: String
    let kind: SpiderwebMountGraphNodeKind
    let mode: UInt32
    let writable: Bool
    let size: UInt64
    let canonicalNodeID: UInt64?
    let contentMode: SpiderwebSyntheticContentMode?
    let inlineContentB64: String?
    let sourceID: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case parentID = "parent_id"
        case name
        case path
        case kind
        case mode
        case writable
        case size
        case canonicalNodeID = "canonical_node_id"
        case contentMode = "content_mode"
        case inlineContentB64 = "inline_content_b64"
        case sourceID = "source_id"
    }

    var inlineContent: Data? {
        guard let inlineContentB64 else {
            return nil
        }
        return Data(base64Encoded: inlineContentB64)
    }
}

private struct SpiderwebMountGraphSnapshot: Codable {
    let mountSessionID: String
    let graphGeneration: UInt64
    let rootNodeID: UInt64
    let nodes: [SpiderwebMountGraphNode]
    let sources: [SpiderwebMountGraphSource]

    private enum CodingKeys: String, CodingKey {
        case mountSessionID = "mount_session_id"
        case graphGeneration = "graph_generation"
        case rootNodeID = "root_node_id"
        case nodes
        case sources
    }
}

private enum SpiderwebNamespaceHandleBacking {
    case inline(Data)
    case remote
}

private struct SpiderwebNamespaceHandleState {
    let path: String
    let nodeID: UInt64
    let flags: UInt32
    let writable: Bool
    let backing: SpiderwebNamespaceHandleBacking
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
    private var launchTask: Task<Void, Error>?
    private var receiveLoopTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var nextControlID: UInt64 = 1
    private var nextHandleID: UInt64 = 1
    private var openHandles: [UInt64: SpiderwebNamespaceHandleState] = [:]
    private var pendingControlResponses: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var mountGraph: SpiderwebMountGraphSnapshot?
    private var mountGraphNodesByPath: [String: SpiderwebMountGraphNode] = [:]
    private var mountGraphNodesByID: [UInt64: SpiderwebMountGraphNode] = [:]
    private var mountGraphSourcesByID: [String: SpiderwebMountGraphSource] = [:]
    private var mountGraphLoadedDirectoryDepths: [String: UInt32] = [:]
    private var mountGraphFetchedAt: Date?
    private var remoteOperationSnapshot = SpiderwebRemoteOperationSnapshot.zero

    init(request: SpiderwebMountRequest) {
        self.request = request
    }

    func launchIfNeeded() async throws {
        if webSocketTask != nil, mountGraph != nil {
            return
        }
        if let launchTask {
            try await launchTask.value
            return
        }

        let task = Task { [self] in
            try await self.connectFresh()
        }
        launchTask = task
        do {
            try await task.value
            launchTask = nil
        } catch {
            launchTask = nil
            throw error
        }
    }

    func shutdown() async {
        launchTask?.cancel()
        launchTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        await tearDown(throwing: URLError(.cancelled), preserveMountGraph: false)
    }

    func ping() async throws {
        try await ensureMountGraphLoaded()
    }

    func getattr(path: String) async throws -> SpiderwebRemoteAttr {
        let normalizedPath = normalizeAbsolutePath(path)
        return try await withReconnect { session in
            try await session.localGetattr(path: normalizedPath)
        }
    }

    func readdir(path: String, cookie: UInt64, maxEntries: UInt32) async throws -> SpiderwebRemoteDirectoryListing {
        let normalizedPath = normalizeAbsolutePath(path)
        return try await withReconnect { session in
            try await session.localReaddir(path: normalizedPath, cookie: cookie, maxEntries: maxEntries)
        }
    }

    func statfs(path: String) async throws -> SpiderwebRemoteStatFS {
        _ = path
        try await launchIfNeeded()
        return syntheticStatFS
    }

    func open(path: String, flags: UInt32) async throws -> SpiderwebOpenHandleResponse {
        let normalizedPath = normalizeAbsolutePath(path)
        return try await withReconnect { session in
            try await session.localOpen(path: normalizedPath, flags: flags)
        }
    }

    func read(handleID: UInt64, offset: UInt64, length: UInt32) async throws -> Data {
        try await withReconnect { session in
            try await session.localRead(handleID: handleID, offset: offset, length: length)
        }
    }

    func release(handleID: UInt64) async throws {
        try await withReconnect { session in
            try await session.localRelease(handleID: handleID)
        }
    }

    func write(handleID: UInt64, offset: UInt64, data: Data) async throws -> UInt32 {
        try await withReconnect { session in
            try await session.localWrite(handleID: handleID, offset: offset, data: data)
        }
    }

    func readlink(path: String) async throws -> String {
        let normalizedPath = normalizeAbsolutePath(path)
        return try await withReconnect { session in
            try await session.localReadlink(path: normalizedPath)
        }
    }

    func create(path: String, mode: UInt32, flags: UInt32) async throws -> SpiderwebCreateHandleResponse {
        let normalizedPath = normalizeAbsolutePath(path)
        return try await withReconnect { session in
            try await session.localCreate(path: normalizedPath, mode: mode, flags: flags)
        }
    }

    func truncate(path: String, size: UInt64) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        try await withReconnect { session in
            try await session.localTruncate(path: normalizedPath, size: size)
        }
    }

    func setattr(path: String, request: SpiderwebSetAttrRequest) async throws -> SpiderwebRemoteAttr {
        let normalizedPath = normalizeAbsolutePath(path)
        return try await withReconnect { session in
            try await session.localSetattr(path: normalizedPath, request: request)
        }
    }

    func getxattr(path: String, name: String) async throws -> Data {
        let normalizedPath = normalizeAbsolutePath(path)
        return try await withReconnect { session in
            try await session.localGetxattr(path: normalizedPath, name: name)
        }
    }

    func setxattr(path: String, name: String, value: Data, flags: UInt32) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        try await withReconnect { session in
            try await session.localSetxattr(path: normalizedPath, name: name, value: value, flags: flags)
        }
    }

    func listxattrs(path: String) async throws -> [String] {
        let normalizedPath = normalizeAbsolutePath(path)
        return try await withReconnect { session in
            try await session.localListxattrs(path: normalizedPath)
        }
    }

    func removexattr(path: String, name: String) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        try await withReconnect { session in
            try await session.localRemovexattr(path: normalizedPath, name: name)
        }
    }

    func unlink(path: String) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        try await withReconnect { session in
            try await session.localUnlink(path: normalizedPath)
        }
    }

    func mkdir(path: String) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        try await withReconnect { session in
            try await session.localMkdir(path: normalizedPath)
        }
    }

    func rmdir(path: String) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        try await withReconnect { session in
            try await session.localRmdir(path: normalizedPath)
        }
    }

    func rename(oldPath: String, newPath: String) async throws {
        let normalizedOldPath = normalizeAbsolutePath(oldPath)
        let normalizedNewPath = normalizeAbsolutePath(newPath)
        try await withReconnect { session in
            try await session.localRename(oldPath: normalizedOldPath, newPath: normalizedNewPath)
        }
    }

    func symlink(target: String, linkPath: String) async throws {
        let normalizedPath = normalizeAbsolutePath(linkPath)
        try await withReconnect { session in
            try await session.localSymlink(target: target, linkPath: normalizedPath)
        }
    }

    private func withReconnect<T>(_ operation: (SpiderwebNamespaceSession) async throws -> T) async throws -> T {
        do {
            if webSocketTask != nil || mountGraph == nil {
                try await launchIfNeeded()
            }
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
        connectionGeneration &+= 1
        let generation = connectionGeneration
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop(generation: generation)
        }

        do {
            try await negotiateControlAndAttach(namespace: namespace)
        } catch {
            await tearDown(throwing: error, preserveMountGraph: mountGraph != nil)
            throw error
        }
    }

    private func reconnect() async throws {
        await tearDown(throwing: URLError(.networkConnectionLost), preserveMountGraph: true)
        try await connectFresh()
    }

    private func tearDown(throwing error: Error, preserveMountGraph: Bool) async {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        openHandles.removeAll()
        mountGraphFetchedAt = nil
        if !preserveMountGraph {
            clearMountGraph()
        }
        failPendingResponses(throwing: error)
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
        try await refreshMountGraph(force: true)
    }

    private func sendControlRequest(type: String, expectedType: String, payload: [String: Any]) async throws -> [String: Any] {
        let requestID = nextControlRequestID()
        let envelope: [String: Any] = [
            "channel": "control",
            "type": type,
            "id": requestID,
            "payload": payload,
        ]
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pendingControlResponses[requestID] = continuation
            Task {
                do {
                    try await self.sendEnvelope(envelope)
                } catch {
                    self.failPendingControlResponse(id: requestID, throwing: error)
                }
            }
        }
        let messageType = stringValue(response["type"]) ?? ""
        if messageType == "control.error" {
            throw mapControlError(response)
        }
        guard messageType == expectedType else {
            throw SpiderwebProtocolFailure.unexpectedMessage(messageType)
        }
        return response
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

    private func runReceiveLoop(generation: UInt64) async {
        do {
            while !Task.isCancelled {
                let envelope = try await receiveEnvelope()
                processIncomingEnvelope(envelope, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            await handleReceiveLoopFailure(error, generation: generation)
        }
    }

    private func processIncomingEnvelope(_ envelope: [String: Any], generation: UInt64) {
        guard generation == connectionGeneration else {
            return
        }

        let channel = stringValue(envelope["channel"]) ?? ""
        guard channel == "control" else {
            return
        }

        let messageType = stringValue(envelope["type"]) ?? ""
        if messageType == "control.mount_graph_delta_v2" {
            mountGraphFetchedAt = nil
            return
        }

        guard let requestID = stringValue(envelope["id"]),
              let continuation = pendingControlResponses.removeValue(forKey: requestID)
        else {
            return
        }
        continuation.resume(returning: envelope)
    }

    private func handleReceiveLoopFailure(_ error: Error, generation: UInt64) async {
        guard generation == connectionGeneration else {
            return
        }
        await tearDown(throwing: error, preserveMountGraph: true)
    }

    private func ensureMountGraphLoaded() async throws {
        if mountGraphNeedsRefresh() {
            try await refreshMountGraph(force: true)
        }
    }

    private func refreshMountGraph(force: Bool) async throws {
        if !mountGraphNeedsRefresh(force: force) {
            return
        }
        let snapshot = try await requestMountGraph(path: "/", depth: spiderwebNamespaceInitialSnapshotDepth)
        replaceMountGraph(with: snapshot, scopePath: "/", depth: spiderwebNamespaceInitialSnapshotDepth, replaceAll: true)
        mountGraphFetchedAt = Date()
    }

    private func mountGraphNeedsRefresh(force: Bool = false) -> Bool {
        if force || mountGraph == nil {
            return true
        }
        guard let fetchedAt = mountGraphFetchedAt else {
            return true
        }
        return Date().timeIntervalSince(fetchedAt) >= spiderwebNamespaceCacheTTL
    }

    private func requestMountGraph(path: String, depth: UInt32) async throws -> SpiderwebMountGraphSnapshot {
        remoteOperationSnapshot.readdir &+= 1
        remoteOperationSnapshot.getattr &+= 1
        let response = try await sendControlRequest(
            type: "control.mount_attach_v2",
            expectedType: "control.mount_attach_v2",
            payload: [
                "path": normalizeAbsolutePath(path),
                "depth": depth,
            ]
        )
        guard let payload = response["payload"] else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }
        return try decodeMountGraphSnapshot(payload)
    }

    private func replaceMountGraph(
        with snapshot: SpiderwebMountGraphSnapshot,
        scopePath: String,
        depth: UInt32,
        replaceAll: Bool
    ) {
        let normalizedScopePath = normalizeAbsolutePath(scopePath)
        mountGraph = SpiderwebMountGraphSnapshot(
            mountSessionID: snapshot.mountSessionID,
            graphGeneration: snapshot.graphGeneration,
            rootNodeID: snapshot.rootNodeID,
            nodes: [],
            sources: snapshot.sources
        )

        if replaceAll {
            mountGraphNodesByPath.removeAll(keepingCapacity: false)
            mountGraphNodesByID.removeAll(keepingCapacity: false)
            mountGraphLoadedDirectoryDepths.removeAll(keepingCapacity: false)
            for node in snapshot.nodes {
                let normalizedPath = normalizeAbsolutePath(node.path)
                let normalizedNode = SpiderwebMountGraphNode(
                    id: node.id,
                    parentID: node.parentID,
                    name: node.name,
                    path: normalizedPath,
                    kind: node.kind,
                    mode: node.mode,
                    writable: node.writable,
                    size: node.size,
                    canonicalNodeID: node.canonicalNodeID,
                    contentMode: node.contentMode,
                    inlineContentB64: node.inlineContentB64,
                    sourceID: node.sourceID
                )
                mountGraphNodesByPath[normalizedPath] = normalizedNode
                mountGraphNodesByID[normalizedNode.id] = normalizedNode
            }
        } else {
            clearMountGraphSubtree(at: normalizedScopePath)

            var mergedIDRemap: [UInt64: UInt64] = [:]
            var nextMergedID = nextMergedMountGraphNodeID()

            for node in snapshot.nodes {
                let normalizedPath = normalizeAbsolutePath(node.path)
                let inScope = pathMatchesPrefixBoundary(normalizedPath, normalizedScopePath)
                if !inScope, let existing = mountGraphNodesByPath[normalizedPath] {
                    mergedIDRemap[node.id] = existing.id
                    continue
                }

                let mergedParentID = node.parentID.flatMap { mergedIDRemap[$0] ?? $0 }
                let mergedNode = SpiderwebMountGraphNode(
                    id: nextMergedID,
                    parentID: mergedParentID,
                    name: node.name,
                    path: normalizedPath,
                    kind: node.kind,
                    mode: node.mode,
                    writable: node.writable,
                    size: node.size,
                    canonicalNodeID: node.canonicalNodeID,
                    contentMode: node.contentMode,
                    inlineContentB64: node.inlineContentB64,
                    sourceID: node.sourceID
                )
                nextMergedID &+= 1
                mergedIDRemap[node.id] = mergedNode.id
                mountGraphNodesByPath[normalizedPath] = mergedNode
                mountGraphNodesByID[mergedNode.id] = mergedNode
            }
        }
        for source in snapshot.sources {
            mountGraphSourcesByID[normalizeAbsolutePath(source.id)] = source
        }
        markLoadedDirectoryDepths(scopePath: normalizedScopePath, depth: depth, nodes: snapshot.nodes)
    }

    private func nextMergedMountGraphNodeID() -> UInt64 {
        guard let currentMax = mountGraphNodesByID.keys.max() else {
            return 1
        }
        return currentMax &+ 1
    }

    private func clearMountGraphSubtree(at path: String) {
        let normalizedPath = normalizeAbsolutePath(path)
        let descendantPrefix = normalizedPath == "/" ? "/" : normalizedPath + "/"
        let pathsToRemove = mountGraphNodesByPath.keys.filter { currentPath in
            currentPath == normalizedPath || currentPath.hasPrefix(descendantPrefix)
        }
        for currentPath in pathsToRemove {
            if let removed = mountGraphNodesByPath.removeValue(forKey: currentPath) {
                mountGraphNodesByID.removeValue(forKey: removed.id)
            }
        }
        let loadedPathsToRemove = mountGraphLoadedDirectoryDepths.keys.filter { currentPath in
            currentPath == normalizedPath || currentPath.hasPrefix(descendantPrefix)
        }
        for currentPath in loadedPathsToRemove {
            mountGraphLoadedDirectoryDepths.removeValue(forKey: currentPath)
        }
    }

    private func markLoadedDirectoryDepths(scopePath: String, depth: UInt32, nodes: [SpiderwebMountGraphNode]) {
        guard depth > 0 else {
            return
        }
        for node in nodes where node.kind == .syntheticDirectory || node.kind == .exportRoot {
            let normalizedPath = normalizeAbsolutePath(node.path)
            guard let relativeDepth = relativeMountGraphDepth(from: scopePath, to: normalizedPath) else {
                continue
            }
            guard relativeDepth <= depth else {
                continue
            }
            let loadedDepth = depth - relativeDepth
            guard loadedDepth > 0 || normalizedPath == scopePath else {
                continue
            }
            let existingDepth = mountGraphLoadedDirectoryDepths[normalizedPath] ?? 0
            mountGraphLoadedDirectoryDepths[normalizedPath] = max(existingDepth, loadedDepth)
        }
    }

    private func relativeMountGraphDepth(from scopePath: String, to path: String) -> UInt32? {
        let normalizedScope = normalizeAbsolutePath(scopePath)
        let normalizedPath = normalizeAbsolutePath(path)
        if normalizedScope == normalizedPath {
            return 0
        }
        guard pathMatchesPrefixBoundary(normalizedPath, normalizedScope) else {
            return nil
        }
        let suffix = normalizedPath.dropFirst(normalizedScope.count + (normalizedScope == "/" ? 0 : 1))
        let segments = suffix.split(separator: "/").count
        return UInt32(segments)
    }

    private func ensureDirectoryChildrenLoaded(at path: String, minimumDepth: UInt32 = 1) async throws {
        guard minimumDepth > 0 else {
            return
        }
        try await ensureMountGraphLoaded()
        let normalizedPath = normalizeAbsolutePath(path)
        if (mountGraphLoadedDirectoryDepths[normalizedPath] ?? 0) >= minimumDepth {
            return
        }
        let snapshot = try await requestMountGraph(path: normalizedPath, depth: minimumDepth)
        replaceMountGraph(with: snapshot, scopePath: normalizedPath, depth: minimumDepth, replaceAll: normalizedPath == "/")
        mountGraphFetchedAt = Date()
    }

    private func clearMountGraph() {
        mountGraph = nil
        mountGraphNodesByPath.removeAll(keepingCapacity: false)
        mountGraphNodesByID.removeAll(keepingCapacity: false)
        mountGraphSourcesByID.removeAll(keepingCapacity: false)
        mountGraphLoadedDirectoryDepths.removeAll(keepingCapacity: false)
        mountGraphFetchedAt = nil
    }

    private func decodeMountGraphSnapshot(_ payload: Any) throws -> SpiderwebMountGraphSnapshot {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        return try JSONDecoder().decode(SpiderwebMountGraphSnapshot.self, from: data)
    }

    private func resolveMountGraphNode(path: String) async throws -> SpiderwebMountGraphNode {
        try await ensureMountGraphLoaded()
        let normalizedPath = normalizeAbsolutePath(path)
        if normalizedPath == "/" {
            guard let node = mountGraphNodesByPath[normalizedPath] else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "Spiderweb path not found"])
            }
            return node
        }

        var currentPath = "/"
        guard var currentNode = mountGraphNodesByPath[currentPath] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "Spiderweb path not found"])
        }

        for segment in normalizedPath.split(separator: "/").map(String.init) {
            if currentNode.kind == .syntheticDirectory || currentNode.kind == .exportRoot {
                try await ensureDirectoryChildrenLoaded(at: currentPath)
            }
            let nextPath = join(directoryPath: currentPath, childName: segment)
            guard let nextNode = mountGraphNodesByPath[nextPath] else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "Spiderweb path not found"])
            }
            currentPath = nextPath
            currentNode = nextNode
        }
        return currentNode
    }

    private func localGetattr(path: String) async throws -> SpiderwebRemoteAttr {
        let node = try await resolveMountGraphNode(path: path)
        return remoteAttr(from: node)
    }

    private func localReaddir(path: String, cookie: UInt64, maxEntries: UInt32) async throws -> SpiderwebRemoteDirectoryListing {
        var directory = try await resolveMountGraphNode(path: path)
        guard directory.kind == .syntheticDirectory || directory.kind == .exportRoot else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR), userInfo: [NSLocalizedDescriptionKey: "Not a directory"])
        }

        let normalizedPath = normalizeAbsolutePath(path)
        try await ensureDirectoryChildrenLoaded(at: normalizedPath)
        directory = try await resolveMountGraphNode(path: normalizedPath)
        let childNodes = mountGraphNodesByPath.values
            .filter { $0.parentID == directory.id }
            .sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }

        let startIndex = Int(clamping: cookie)
        guard startIndex < childNodes.count else {
            return SpiderwebRemoteDirectoryListing(entries: [], nextCookie: 0, eof: true, directoryGeneration: mountGraph?.graphGeneration ?? 0)
        }

        let maxCount = maxEntries == 0 ? 0 : Int(maxEntries)
        let endIndex = min(childNodes.count, startIndex + maxCount)
        let slice = childNodes[startIndex..<endIndex]
        let entries = slice.map { child in
            SpiderwebRemoteDirectoryListing.Entry(
                name: child.name == "/" ? normalizedPath : child.name,
                attr: remoteAttr(from: child)
            )
        }
        return SpiderwebRemoteDirectoryListing(
            entries: entries,
            nextCookie: endIndex >= childNodes.count ? 0 : UInt64(endIndex),
            eof: endIndex >= childNodes.count,
            directoryGeneration: mountGraph?.graphGeneration ?? 0
        )
    }

    private func localOpen(path: String, flags: UInt32) async throws -> SpiderwebOpenHandleResponse {
        let normalizedPath = normalizeAbsolutePath(path)
        let node = try await resolveMountGraphNode(path: normalizedPath)
        if node.kind == .syntheticDirectory || node.kind == .exportRoot {
            let handleID = reserveNamespaceHandleID()
            openHandles[handleID] = SpiderwebNamespaceHandleState(
                path: normalizedPath,
                nodeID: node.id,
                flags: flags,
                writable: false,
                backing: .inline(Data())
            )
            return SpiderwebOpenHandleResponse(handleID: handleID, writable: false)
        }

        if flagsRequireWrite(flags), (flags & UInt32(O_TRUNC)) != 0 {
            try await performLocalTruncate(path: normalizedPath, size: 0, node: node)
        }

        let backing: SpiderwebNamespaceHandleBacking
        switch node.contentMode {
        case .inlineSnapshot, .deltaSnapshot:
            backing = .inline(node.inlineContent ?? Data())
        case .remoteRead, .remoteRW, .writeOnlyCommand, .none:
            backing = .remote
        }

        let handleID = reserveNamespaceHandleID()
        openHandles[handleID] = SpiderwebNamespaceHandleState(
            path: normalizedPath,
            nodeID: node.id,
            flags: flags,
            writable: node.writable,
            backing: backing
        )
        return SpiderwebOpenHandleResponse(handleID: handleID, writable: node.writable)
    }

    private func localRead(handleID: UInt64, offset: UInt64, length: UInt32) async throws -> Data {
        guard let state = openHandles[handleID] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb handle"])
        }
        switch state.backing {
        case .inline(let data):
            let start = Int(min(offset, UInt64(data.count)))
            let end = min(data.count, start + Int(length))
            return data.subdata(in: start..<end)
        case .remote:
            remoteOperationSnapshot.lookup &+= 1
            let response = try await sendControlRequest(
                type: "control.mount_file_read_v2",
                expectedType: "control.mount_file_read_v2",
                payload: [
                    "path": state.path,
                    "offset": offset,
                    "length": length,
                ]
            )
            guard
                let payload = response["payload"] as? [String: Any],
                let dataB64 = stringValue(payload["data_b64"]),
                let data = Data(base64Encoded: dataB64)
            else {
                throw SpiderwebProtocolFailure.invalidEnvelope
            }
            return data
        }
    }

    private func localRelease(handleID: UInt64) async throws {
        openHandles.removeValue(forKey: handleID)
    }

    private func localWrite(handleID: UInt64, offset: UInt64, data: Data) async throws -> UInt32 {
        guard let state = openHandles[handleID] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb handle"])
        }
        guard state.writable else {
            throw readOnlyError(message: "Spiderweb path \(state.path) is read-only")
        }
        guard case .remote = state.backing else {
            throw readOnlyError(message: "Spiderweb path \(state.path) is read-only")
        }
        remoteOperationSnapshot.lookup &+= 1
        let response = try await sendControlRequest(
            type: "control.mount_file_write_v2",
            expectedType: "control.mount_file_write_v2",
            payload: [
                "path": state.path,
                "offset": offset,
                "data_b64": data.base64EncodedString(),
            ]
        )
        guard
            let payload = response["payload"] as? [String: Any],
            let count = uint32Value(payload["n"])
        else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }
        mountGraphFetchedAt = nil
        return count
    }

    private func localReadlink(path: String) async throws -> String {
        remoteOperationSnapshot.lookup &+= 1
        let response = try await sendControlRequest(
            type: "control.mount_path_readlink_v2",
            expectedType: "control.mount_path_readlink_v2",
            payload: ["path": normalizeAbsolutePath(path)]
        )
        guard
            let payload = response["payload"] as? [String: Any],
            let target = stringValue(payload["target"])
        else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }
        return target
    }

    private func localCreate(path: String, mode: UInt32, flags: UInt32) async throws -> SpiderwebCreateHandleResponse {
        let normalizedPath = normalizeAbsolutePath(path)
        let split = try splitEndpointParentChild(normalizedPath)
        let parent = try await resolveMountGraphNode(path: split.parentPath)
        guard parent.kind == .syntheticDirectory || parent.kind == .exportRoot else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR), userInfo: [NSLocalizedDescriptionKey: "Parent is not a directory"])
        }
        if !parent.writable {
            throw readOnlyError(message: "Spiderweb path \(split.parentPath) is read-only")
        }

        remoteOperationSnapshot.lookup &+= 1
        _ = try await sendControlRequest(
            type: "control.mount_file_write_v2",
            expectedType: "control.mount_file_write_v2",
            payload: [
                "path": normalizedPath,
                "offset": UInt64(0),
                "data_b64": "",
            ]
        )

        let parentSnapshot = try await requestMountGraph(path: split.parentPath, depth: 1)
        replaceMountGraph(
            with: parentSnapshot,
            scopePath: split.parentPath,
            depth: 1,
            replaceAll: split.parentPath == "/"
        )
        mountGraphFetchedAt = Date()

        let attr: SpiderwebRemoteAttr
        let nodeID: UInt64
        let writable: Bool
        if let node = mountGraphNodesByPath[normalizedPath] {
            attr = remoteAttr(from: node)
            nodeID = node.id
            writable = node.writable
        } else {
            attr = syntheticCreatedAttr(path: normalizedPath, mode: mode)
            nodeID = attr.id
            writable = true
        }

        let handleID = reserveNamespaceHandleID()
        openHandles[handleID] = SpiderwebNamespaceHandleState(
            path: normalizedPath,
            nodeID: nodeID,
            flags: flags,
            writable: writable,
            backing: .remote
        )
        return SpiderwebCreateHandleResponse(handleID: handleID, attr: attr, writable: writable)
    }

    private func localTruncate(path: String, size: UInt64) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        let node = try await resolveMountGraphNode(path: normalizedPath)
        try await performLocalTruncate(path: normalizedPath, size: size, node: node)
    }

    private func performLocalTruncate(path: String, size: UInt64, node: SpiderwebMountGraphNode) async throws {
        if node.kind == .syntheticDirectory || node.kind == .exportRoot {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EISDIR),
                userInfo: [NSLocalizedDescriptionKey: "Spiderweb path \(path) is a directory"]
            )
        }
        if !node.writable {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }

        remoteOperationSnapshot.lookup &+= 1
        _ = try await sendControlRequest(
            type: "control.mount_file_write_v2",
            expectedType: "control.mount_file_write_v2",
            payload: [
                "path": path,
                "offset": UInt64(0),
                "data_b64": "",
                "truncate_to_size": size,
            ]
        )

        let parentPath = endpointParentPath(path)
        let parentSnapshot = try await requestMountGraph(path: parentPath, depth: 1)
        replaceMountGraph(
            with: parentSnapshot,
            scopePath: parentPath,
            depth: 1,
            replaceAll: parentPath == "/"
        )
        mountGraphFetchedAt = Date()
    }

    private func localSetattr(path: String, request: SpiderwebSetAttrRequest) async throws -> SpiderwebRemoteAttr {
        if request.isEmpty {
            return try await localGetattr(path: path)
        }
        throw unsupportedNamespaceMutation(path: path, operation: "setattr")
    }

    private func localGetxattr(path: String, name: String) async throws -> Data {
        _ = name
        throw unsupportedNamespaceMutation(path: path, operation: "getxattr")
    }

    private func localSetxattr(path: String, name: String, value: Data, flags: UInt32) async throws {
        _ = name
        _ = value
        _ = flags
        throw unsupportedNamespaceMutation(path: path, operation: "setxattr")
    }

    private func localListxattrs(path: String) async throws -> [String] {
        throw unsupportedNamespaceMutation(path: path, operation: "listxattr")
    }

    private func localRemovexattr(path: String, name: String) async throws {
        _ = name
        throw unsupportedNamespaceMutation(path: path, operation: "removexattr")
    }

    private func localUnlink(path: String) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        remoteOperationSnapshot.lookup &+= 1
        _ = try await sendControlRequest(
            type: "control.mount_path_unlink_v2",
            expectedType: "control.mount_path_unlink_v2",
            payload: ["path": normalizedPath]
        )
        try await refreshNamespaceMutationScopes([endpointParentPath(normalizedPath)])
    }

    private func localMkdir(path: String) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        remoteOperationSnapshot.lookup &+= 1
        _ = try await sendControlRequest(
            type: "control.mount_path_mkdir_v2",
            expectedType: "control.mount_path_mkdir_v2",
            payload: ["path": normalizedPath]
        )
        try await refreshNamespaceMutationScopes([endpointParentPath(normalizedPath)])
    }

    private func localRmdir(path: String) async throws {
        let normalizedPath = normalizeAbsolutePath(path)
        remoteOperationSnapshot.lookup &+= 1
        _ = try await sendControlRequest(
            type: "control.mount_path_rmdir_v2",
            expectedType: "control.mount_path_rmdir_v2",
            payload: ["path": normalizedPath]
        )
        try await refreshNamespaceMutationScopes([endpointParentPath(normalizedPath)])
    }

    private func localRename(oldPath: String, newPath: String) async throws {
        let normalizedOldPath = normalizeAbsolutePath(oldPath)
        let normalizedNewPath = normalizeAbsolutePath(newPath)
        remoteOperationSnapshot.lookup &+= 1
        _ = try await sendControlRequest(
            type: "control.mount_path_rename_v2",
            expectedType: "control.mount_path_rename_v2",
            payload: [
                "old_path": normalizedOldPath,
                "new_path": normalizedNewPath,
            ]
        )
        try await refreshNamespaceMutationScopes([
            endpointParentPath(normalizedOldPath),
            endpointParentPath(normalizedNewPath),
        ])
    }

    private func localSymlink(target: String, linkPath: String) async throws {
        let normalizedLinkPath = normalizeAbsolutePath(linkPath)
        remoteOperationSnapshot.lookup &+= 1
        _ = try await sendControlRequest(
            type: "control.mount_path_symlink_v2",
            expectedType: "control.mount_path_symlink_v2",
            payload: [
                "target": target,
                "link_path": normalizedLinkPath,
            ]
        )
        try await refreshNamespaceMutationScopes([endpointParentPath(normalizedLinkPath)])
    }

    private func refreshNamespaceMutationScopes(_ scopePaths: [String]) async throws {
        var refreshed = Set<String>()
        for rawPath in scopePaths {
            let normalizedPath = normalizeAbsolutePath(rawPath)
            if refreshed.contains(normalizedPath) {
                continue
            }
            let snapshot = try await requestMountGraph(path: normalizedPath, depth: 1)
            replaceMountGraph(
                with: snapshot,
                scopePath: normalizedPath,
                depth: 1,
                replaceAll: normalizedPath == "/"
            )
            refreshed.insert(normalizedPath)
        }
        mountGraphFetchedAt = Date()
    }

    private func reserveNamespaceHandleID() -> UInt64 {
        let handleID = nextHandleID
        nextHandleID &+= 1
        if nextHandleID == 0 {
            nextHandleID = 1
        }
        return handleID
    }

    private func remoteAttr(from node: SpiderwebMountGraphNode) -> SpiderwebRemoteAttr {
        let kindCode: UInt8 = (node.kind == .syntheticDirectory || node.kind == .exportRoot) ? 2 : 1
        let defaultMode: UInt32 = kindCode == 2 ? 0o040755 : 0o100644
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        return SpiderwebRemoteAttr(
            id: node.canonicalNodeID ?? node.id,
            kindCode: kindCode,
            mode: node.mode == 0 ? defaultMode : node.mode,
            linkCount: kindCode == 2 ? 2 : 1,
            uid: UInt32(getuid()),
            gid: UInt32(getgid()),
            flags: 0,
            size: node.size,
            accessTimeNS: now,
            modifyTimeNS: now,
            changeTimeNS: now
        )
    }

    private func nextControlRequestID() -> String {
        defer { nextControlID &+= 1 }
        return "swift-control-\(nextControlID)"
    }

    private func syntheticCreatedAttr(path: String, mode: UInt32) -> SpiderwebRemoteAttr {
        let now = Int64(Date().timeIntervalSince1970 * 1_000_000_000)
        let effectiveMode = mode == 0 ? UInt32(0o100644) : UInt32(0o100000) | (mode & 0o777)
        return SpiderwebRemoteAttr(
            id: stableSyntheticPathID(path),
            kindCode: 1,
            mode: effectiveMode,
            linkCount: 1,
            uid: UInt32(getuid()),
            gid: UInt32(getgid()),
            flags: 0,
            size: 0,
            accessTimeNS: now,
            modifyTimeNS: now,
            changeTimeNS: now
        )
    }

    private func unsupportedNamespaceMutation(path: String, operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ENOTSUP),
            userInfo: [NSLocalizedDescriptionKey: "Spiderweb namespace \(operation) is not supported for \(path)"]
        )
    }

    func remoteOperationsSnapshot() -> SpiderwebRemoteOperationSnapshot {
        remoteOperationSnapshot
    }

    private func failPendingControlResponse(id: String, throwing error: Error) {
        guard let continuation = pendingControlResponses.removeValue(forKey: id) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failPendingResponses(throwing error: Error) {
        let controlContinuations = pendingControlResponses.values
        pendingControlResponses.removeAll()
        for continuation in controlContinuations {
            continuation.resume(throwing: error)
        }
    }
}

private struct SpiderwebEndpointResolvedNode {
    let nodeID: UInt64
    let attr: SpiderwebRemoteAttr?
}

enum SpiderwebMountedInvalidationKind: Sendable {
    case attr
    case data
    case all
    case directory
}

struct SpiderwebMountedInvalidation: Sendable {
    let path: String
    let kind: SpiderwebMountedInvalidationKind
}

private struct SpiderwebEndpointExportSelection {
    let rootNodeID: UInt64
    let readOnly: Bool?
    let caseSensitive: Bool?
    let symlink: Bool?
}

private struct SpiderwebEndpointHandleState {
    let path: String
    let nodeID: UInt64
    let flags: UInt32
    let writable: Bool
}

struct SpiderwebEndpointInvalidation {
    let nodeID: UInt64
    let kind: SpiderwebMountedInvalidationKind
}

private struct SpiderwebTimedCacheEntry<Value> {
    let value: Value
    let fetchedAt: Date
}

private struct SpiderwebEndpointChildCacheKey: Hashable {
    let parentNodeID: UInt64
    let name: String
}

private struct SpiderwebNamespaceDirectoryCacheKey: Hashable {
    let path: String
    let cookie: UInt64
    let maxEntries: UInt32
}

private struct SpiderwebEndpointDirectoryCacheKey: Hashable {
    let path: String
    let cookie: UInt64
    let maxEntries: UInt32
}

struct SpiderwebRemoteOperationSnapshot {
    var lookup: UInt64 = 0
    var getattr: UInt64 = 0
    var readdir: UInt64 = 0

    static let zero = SpiderwebRemoteOperationSnapshot()

    func delta(since earlier: SpiderwebRemoteOperationSnapshot) -> SpiderwebRemoteOperationSnapshot {
        SpiderwebRemoteOperationSnapshot(
            lookup: lookup &- earlier.lookup,
            getattr: getattr &- earlier.getattr,
            readdir: readdir &- earlier.readdir
        )
    }

    func adding(_ other: SpiderwebRemoteOperationSnapshot) -> SpiderwebRemoteOperationSnapshot {
        SpiderwebRemoteOperationSnapshot(
            lookup: lookup &+ other.lookup,
            getattr: getattr &+ other.getattr,
            readdir: readdir &+ other.readdir
        )
    }

    var total: UInt64 {
        lookup &+ getattr &+ readdir
    }
}

private let spiderwebEndpointCacheTTL: TimeInterval = 5.0
private let spiderwebNamespaceCacheTTL: TimeInterval = 5.0
private let spiderwebNamespaceInitialSnapshotDepth: UInt32 = 1

actor SpiderwebFsEndpointSession {
    private let config: SpiderwebMountRequest.LaunchConfig.Endpoint

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var launchTask: Task<Void, Error>?
    private var receiveLoopTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var nextTag: UInt32 = 1
    private var exportSelection: SpiderwebEndpointExportSelection?
    private var openHandles: [UInt64: SpiderwebEndpointHandleState] = [:]
    private var nodePaths: [UInt64: String] = [:]
    private var invalidationHandler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?
    private var pendingResponses: [UInt32: CheckedContinuation<[String: Any], Error>] = [:]
    private var resolvedPathCache: [String: SpiderwebTimedCacheEntry<SpiderwebEndpointResolvedNode>] = [:]
    private var childLookupCache: [SpiderwebEndpointChildCacheKey: SpiderwebTimedCacheEntry<SpiderwebEndpointResolvedNode>] = [:]
    private var negativeLookupCache: [SpiderwebEndpointChildCacheKey: Date] = [:]
    private var nodeAttrCache: [UInt64: SpiderwebTimedCacheEntry<SpiderwebRemoteAttr>] = [:]
    private var directoryPageCache: [SpiderwebEndpointDirectoryCacheKey: SpiderwebTimedCacheEntry<SpiderwebRemoteDirectoryListing>] = [:]
    private var inFlightResolutions: [String: Task<SpiderwebEndpointResolvedNode, Error>] = [:]
    private var inFlightLookups: [SpiderwebEndpointChildCacheKey: Task<SpiderwebEndpointResolvedNode, Error>] = [:]
    private var inFlightAttrs: [UInt64: Task<SpiderwebRemoteAttr, Error>] = [:]
    private var inFlightReaddirs: [SpiderwebEndpointDirectoryCacheKey: Task<SpiderwebRemoteDirectoryListing, Error>] = [:]
    private var remoteOperationSnapshot = SpiderwebRemoteOperationSnapshot.zero

    init(config: SpiderwebMountRequest.LaunchConfig.Endpoint) {
        self.config = config
    }

    func setInvalidationHandler(_ handler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?) {
        invalidationHandler = handler
    }

    func launchIfNeeded() async throws {
        if webSocketTask != nil, exportSelection != nil {
            return
        }
        if let launchTask {
            try await launchTask.value
            return
        }

        let task = Task { [self] in
            try await self.connectFresh()
        }
        launchTask = task
        do {
            try await task.value
            launchTask = nil
        } catch {
            launchTask = nil
            throw error
        }
    }

    func shutdown() async {
        launchTask?.cancel()
        launchTask = nil
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        resetEndpointState(throwing: URLError(.cancelled))
    }

    func ping() async throws {
        _ = try await statfs(path: "/")
    }

    func getattr(path: String) async throws -> SpiderwebRemoteAttr {
        try await launchIfNeeded()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        if let cached = cachedResolvedNode(path: normalizedPath), let attr = cached.attr {
            return attr
        }

        let resolved = try await resolveNode(normalizedPath)
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        if let attr = resolved.attr {
            return attr
        }
        let attr = try await getattrNode(nodeID: resolved.nodeID)
        cacheResolvedNode(path: normalizedPath, resolved: SpiderwebEndpointResolvedNode(nodeID: attr.id, attr: attr))
        return attr
    }

    func readdir(path: String, cookie: UInt64, maxEntries: UInt32) async throws -> SpiderwebRemoteDirectoryListing {
        try await launchIfNeeded()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let cacheKey = SpiderwebEndpointDirectoryCacheKey(path: normalizedPath, cookie: cookie, maxEntries: maxEntries)
        if let cached = cachedDirectoryPage(for: cacheKey) {
            return cached
        }
        if let task = inFlightReaddirs[cacheKey] {
            return try await task.value
        }

        let task = Task { [self] in
            try await self.performReaddir(path: normalizedPath, cookie: cookie, maxEntries: maxEntries)
        }
        inFlightReaddirs[cacheKey] = task
        defer { inFlightReaddirs.removeValue(forKey: cacheKey) }
        return try await task.value
    }

    func statfs(path: String) async throws -> SpiderwebRemoteStatFS {
        try await launchIfNeeded()
        let resolved = try await resolveNode(path)
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_statfs",
            expectedType: "acheron.r_fs_statfs",
            node: resolved.nodeID,
            handle: nil,
            payload: [:]
        )
        return try parseFsStatfs(envelope)
    }

    func readSymbolicLink(path: String) async throws -> String {
        try await launchIfNeeded()
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_readlink",
            expectedType: "acheron.r_fs_readlink",
            node: resolved.nodeID,
            handle: nil,
            payload: [:]
        )
        return try parseFsReadlinkTarget(envelope)
    }

    func readlink(path: String) async throws -> String {
        try await readSymbolicLink(path: path)
    }

    func open(path: String, flags: UInt32) async throws -> SpiderwebOpenHandleResponse {
        try await launchIfNeeded()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let resolved = try await resolveNode(normalizedPath)
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_open",
            expectedType: "acheron.r_fs_open",
            node: resolved.nodeID,
            handle: nil,
            payload: ["flags": flags]
        )
        let response = try parseFsOpenHandle(envelope)
        openHandles[response.handleID] = SpiderwebEndpointHandleState(
            path: normalizedPath,
            nodeID: resolved.nodeID,
            flags: flags,
            writable: response.writable
        )
        return response
    }

    func read(handleID: UInt64, offset: UInt64, length: UInt32) async throws -> Data {
        try await launchIfNeeded()
        guard openHandles[handleID] != nil else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb endpoint handle"])
        }
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_read",
            expectedType: "acheron.r_fs_read",
            node: nil,
            handle: handleID,
            payload: [
                "off": offset,
                "len": length,
            ]
        )
        return try parseFsReadData(envelope)
    }

    func release(handleID: UInt64) async throws {
        try await launchIfNeeded()
        openHandles.removeValue(forKey: handleID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_close",
            expectedType: "acheron.r_fs_close",
            node: nil,
            handle: handleID,
            payload: [:]
        )
    }

    func write(handleID: UInt64, offset: UInt64, data: Data) async throws -> UInt32 {
        try await launchIfNeeded()
        guard let handle = openHandles[handleID] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb endpoint handle"])
        }
        guard handle.writable else {
            throw readOnlyError(message: "Spiderweb path \(handle.path) is read-only")
        }
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_write",
            expectedType: "acheron.r_fs_write",
            node: nil,
            handle: handleID,
            payload: [
                "off": offset,
                "data_b64": data.base64EncodedString(),
            ]
        )
        let written = try parseFsWriteCount(envelope)
        invalidateCachesForMutation(path: handle.path, parentPath: endpointParentPath(handle.path), includeDescendants: false)
        return written
    }

    func create(path: String, mode: UInt32, flags: UInt32) async throws -> SpiderwebCreateHandleResponse {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let split = try splitEndpointParentChild(normalizedPath)
        let parent = try await resolveNode(split.parentPath)
        rememberNode(path: split.parentPath, nodeID: parent.nodeID)
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_create",
            expectedType: "acheron.r_fs_create",
            node: parent.nodeID,
            handle: nil,
            payload: [
                "name": split.name,
                "mode": mode,
                "flags": flags,
            ]
        )
        let created = try parseFsCreateResponse(envelope)
        invalidateCachesForMutation(path: normalizedPath, parentPath: split.parentPath, includeDescendants: false)
        cacheResolvedNode(path: normalizedPath, resolved: SpiderwebEndpointResolvedNode(nodeID: created.attr.id, attr: created.attr))
        openHandles[created.handleID] = SpiderwebEndpointHandleState(
            path: normalizedPath,
            nodeID: created.attr.id,
            flags: flags,
            writable: created.writable
        )
        return created
    }

    func truncate(path: String, size: UInt64) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let resolved = try await resolveNode(normalizedPath)
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_truncate",
            expectedType: "acheron.r_fs_truncate",
            node: resolved.nodeID,
            handle: nil,
            payload: ["sz": size]
        )
        invalidateCachesForMutation(path: normalizedPath, parentPath: endpointParentPath(normalizedPath), includeDescendants: false)
    }

    func setattr(path: String, request: SpiderwebSetAttrRequest) async throws -> SpiderwebRemoteAttr {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let resolved = try await resolveNode(normalizedPath)
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        guard !request.isEmpty else {
            if let attr = resolved.attr {
                return attr
            }
            let attr = try await getattrNode(nodeID: resolved.nodeID)
            cacheResolvedNode(path: normalizedPath, resolved: SpiderwebEndpointResolvedNode(nodeID: attr.id, attr: attr))
            return attr
        }
        var payload: [String: Any] = [:]
        if let mode = request.mode {
            payload["mode"] = mode
        }
        if let uid = request.uid {
            payload["uid"] = uid
        }
        if let gid = request.gid {
            payload["gid"] = gid
        }
        if let flags = request.flags {
            payload["flags"] = flags
        }
        if let accessTimeNS = request.accessTimeNS {
            payload["at_ns"] = accessTimeNS
        }
        if let modifyTimeNS = request.modifyTimeNS {
            payload["mt_ns"] = modifyTimeNS
        }
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_setattr",
            expectedType: "acheron.r_fs_setattr",
            node: resolved.nodeID,
            handle: nil,
            payload: payload
        )
        let attr = try parseFsWrappedAttr(envelope)
        invalidateCachesForMutation(path: normalizedPath, parentPath: endpointParentPath(normalizedPath), includeDescendants: false)
        cacheResolvedNode(path: normalizedPath, resolved: SpiderwebEndpointResolvedNode(nodeID: attr.id, attr: attr))
        return attr
    }

    func getxattr(path: String, name: String) async throws -> Data {
        try await launchIfNeeded()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let resolved = try await resolveNode(normalizedPath)
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_getxattr",
            expectedType: "acheron.r_fs_getxattr",
            node: resolved.nodeID,
            handle: nil,
            payload: ["name": name]
        )
        return try parseFsXattrData(envelope)
    }

    func setxattr(path: String, name: String, value: Data, flags: UInt32) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let resolved = try await resolveNode(normalizedPath)
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_setxattr",
            expectedType: "acheron.r_fs_setxattr",
            node: resolved.nodeID,
            handle: nil,
            payload: [
                "name": name,
                "value_b64": value.base64EncodedString(),
                "flags": flags,
            ]
        )
        invalidatePathCaches(normalizedPath, includeDescendants: false, invalidateParentDirectory: false)
    }

    func listxattrs(path: String) async throws -> [String] {
        try await launchIfNeeded()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let resolved = try await resolveNode(normalizedPath)
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_listxattr",
            expectedType: "acheron.r_fs_listxattr",
            node: resolved.nodeID,
            handle: nil,
            payload: [:]
        )
        return try parseFsXattrNames(envelope)
    }

    func removexattr(path: String, name: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let resolved = try await resolveNode(normalizedPath)
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_removexattr",
            expectedType: "acheron.r_fs_removexattr",
            node: resolved.nodeID,
            handle: nil,
            payload: ["name": name]
        )
        invalidatePathCaches(normalizedPath, includeDescendants: false, invalidateParentDirectory: false)
    }

    func unlink(path: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let split = try splitEndpointParentChild(normalizedPath)
        let parent = try await resolveNode(split.parentPath)
        rememberNode(path: split.parentPath, nodeID: parent.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_unlink",
            expectedType: "acheron.r_fs_unlink",
            node: parent.nodeID,
            handle: nil,
            payload: ["name": split.name]
        )
        invalidateCachesForMutation(path: normalizedPath, parentPath: split.parentPath, includeDescendants: false)
    }

    func mkdir(path: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let split = try splitEndpointParentChild(normalizedPath)
        let parent = try await resolveNode(split.parentPath)
        rememberNode(path: split.parentPath, nodeID: parent.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_mkdir",
            expectedType: "acheron.r_fs_mkdir",
            node: parent.nodeID,
            handle: nil,
            payload: ["name": split.name]
        )
        invalidateCachesForMutation(path: normalizedPath, parentPath: split.parentPath, includeDescendants: false)
    }

    func rmdir(path: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let split = try splitEndpointParentChild(normalizedPath)
        let parent = try await resolveNode(split.parentPath)
        rememberNode(path: split.parentPath, nodeID: parent.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_rmdir",
            expectedType: "acheron.r_fs_rmdir",
            node: parent.nodeID,
            handle: nil,
            payload: ["name": split.name]
        )
        invalidateCachesForMutation(path: normalizedPath, parentPath: split.parentPath, includeDescendants: true)
    }

    func rename(oldPath: String, newPath: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let normalizedOldPath = normalizeRelativeEndpointPath(oldPath)
        let normalizedNewPath = normalizeRelativeEndpointPath(newPath)
        let oldSplit = try splitEndpointParentChild(normalizedOldPath)
        let newSplit = try splitEndpointParentChild(normalizedNewPath)
        let oldParent = try await resolveNode(oldSplit.parentPath)
        let newParent = try await resolveNode(newSplit.parentPath)
        rememberNode(path: oldSplit.parentPath, nodeID: oldParent.nodeID)
        rememberNode(path: newSplit.parentPath, nodeID: newParent.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_rename",
            expectedType: "acheron.r_fs_rename",
            node: nil,
            handle: nil,
            payload: [
                "old_parent": oldParent.nodeID,
                "old_name": oldSplit.name,
                "new_parent": newParent.nodeID,
                "new_name": newSplit.name,
            ]
        )
        invalidateCachesForMutation(path: normalizedOldPath, parentPath: oldSplit.parentPath, includeDescendants: true)
        invalidateCachesForMutation(path: normalizedNewPath, parentPath: newSplit.parentPath, includeDescendants: true)
    }

    func symlink(target: String, linkPath: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        try ensureSymlinkSupported()
        let normalizedPath = normalizeRelativeEndpointPath(linkPath)
        let split = try splitEndpointParentChild(normalizedPath)
        let parent = try await resolveNode(split.parentPath)
        rememberNode(path: split.parentPath, nodeID: parent.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_symlink",
            expectedType: "acheron.r_fs_symlink",
            node: parent.nodeID,
            handle: nil,
            payload: [
                "name": split.name,
                "target": target,
            ]
        )
        invalidateCachesForMutation(path: normalizedPath, parentPath: split.parentPath, includeDescendants: false)
    }

    private func connectFresh() async throws {
        guard let url = URL(string: config.url) else {
            throw SpiderwebBridgeError.invalidURL(config.url)
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.waitsForConnectivity = true
        let urlSession = URLSession(configuration: sessionConfiguration)
        let task = urlSession.webSocketTask(with: url)
        task.resume()

        self.urlSession = urlSession
        self.webSocketTask = task
        resetEndpointState(throwing: URLError(.cancelled))
        connectionGeneration &+= 1
        let generation = connectionGeneration
        receiveLoopTask?.cancel()
        receiveLoopTask = Task { [weak self] in
            await self?.runReceiveLoop(generation: generation)
        }

        do {
            _ = try await sendFsRequest(
                type: "acheron.t_fs_hello",
                expectedType: "acheron.r_fs_hello",
                node: nil,
                handle: nil,
                payload: fsHelloPayload()
            )

            let exportsEnvelope = try await sendFsRequest(
                type: "acheron.t_fs_exports",
                expectedType: "acheron.r_fs_exports",
                node: nil,
                handle: nil,
                payload: [:]
            )
            let selection = try parseFsExportSelection(exportsEnvelope, desiredName: config.exportName)
            exportSelection = selection
            cacheResolvedNode(path: "/", resolved: SpiderwebEndpointResolvedNode(nodeID: selection.rootNodeID, attr: nil))
        } catch {
            await shutdown()
            throw error
        }
    }

    private func ensureWritable() throws {
        if exportSelection?.readOnly == true {
            throw readOnlyError(message: "Spiderweb export \(config.mountPath) is read-only")
        }
    }

    private func ensureSymlinkSupported() throws {
        if exportSelection?.symlink == false {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENOTSUP),
                userInfo: [NSLocalizedDescriptionKey: "Spiderweb export \(config.mountPath) does not support symbolic links"]
            )
        }
    }

    private func resolveNode(_ path: String) async throws -> SpiderwebEndpointResolvedNode {
        guard exportSelection != nil else {
            throw URLError(.networkConnectionLost)
        }
        let normalizedPath = normalizeRelativeEndpointPath(path)
        if let cached = cachedResolvedNode(path: normalizedPath) {
            return cached
        }
        if let task = inFlightResolutions[normalizedPath] {
            return try await task.value
        }

        let task = Task { [self] in
            try await self.performResolveNode(normalizedPath)
        }
        inFlightResolutions[normalizedPath] = task
        defer { inFlightResolutions.removeValue(forKey: normalizedPath) }
        return try await task.value
    }

    private func lookupChild(parentNodeID: UInt64, name: String, childPath: String) async throws -> SpiderwebEndpointResolvedNode {
        let normalizedChildPath = normalizeRelativeEndpointPath(childPath)
        let key = SpiderwebEndpointChildCacheKey(parentNodeID: parentNodeID, name: name)
        if isNegativeLookupFresh(for: key) {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT), userInfo: [NSLocalizedDescriptionKey: "Spiderweb path \(normalizedChildPath) was not found"])
        }
        if let cached = cachedLookupChild(for: key) {
            cacheResolvedNode(path: normalizedChildPath, resolved: cached)
            return cached
        }
        if let task = inFlightLookups[key] {
            let resolved = try await task.value
            cacheResolvedNode(path: normalizedChildPath, resolved: resolved)
            return resolved
        }

        let task = Task { [self] in
            try await self.performLookupChild(
                parentNodeID: parentNodeID,
                name: name,
                childPath: normalizedChildPath,
                key: key
            )
        }
        inFlightLookups[key] = task
        defer { inFlightLookups.removeValue(forKey: key) }
        let resolved = try await task.value
        cacheResolvedNode(path: normalizedChildPath, resolved: resolved)
        return resolved
    }

    private func getattrNode(nodeID: UInt64) async throws -> SpiderwebRemoteAttr {
        if let cached = cachedAttr(nodeID: nodeID) {
            return cached
        }
        if let task = inFlightAttrs[nodeID] {
            return try await task.value
        }

        let task = Task { [self] in
            try await self.performGetattrNode(nodeID: nodeID)
        }
        inFlightAttrs[nodeID] = task
        defer { inFlightAttrs.removeValue(forKey: nodeID) }
        return try await task.value
    }

    private func fsHelloPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "protocol": spiderwebNodeFsProtocol,
            "proto": spiderwebNodeFsProto,
            "subscribe_invalidations": true,
        ]
        if let authToken = config.authToken, !authToken.isEmpty {
            payload["auth_token"] = authToken
        }
        return payload
    }

    private func sendFsRequest(
        type: String,
        expectedType: String,
        node: UInt64?,
        handle: UInt64?,
        payload: [String: Any]
    ) async throws -> [String: Any] {
        let tag = nextRequestTag()
        var envelope: [String: Any] = [
            "channel": "acheron",
            "type": type,
            "tag": tag,
            "payload": payload,
        ]
        if let node {
            envelope["node"] = node
        }
        if let handle {
            envelope["h"] = handle
        }
        let response = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String: Any], Error>) in
            pendingResponses[tag] = continuation
            Task {
                do {
                    try await self.sendEnvelope(envelope)
                } catch {
                    self.failPendingResponse(tag: tag, throwing: error)
                }
            }
        }
        let messageType = stringValue(response["type"]) ?? ""
        if messageType == "acheron.err_fs" || messageType == "acheron.error" {
            throw mapFsError(response)
        }
        guard messageType == expectedType else {
            throw SpiderwebProtocolFailure.unexpectedMessage(messageType)
        }
        return response
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

    private func rememberNode(path: String, nodeID: UInt64) {
        nodePaths[nodeID] = normalizeRelativeEndpointPath(path)
    }

    private func handleInvalidationEnvelope(_ envelope: [String: Any]) {
        guard let invalidation = parseFsInvalidationEnvelope(envelope),
              let path = nodePaths[invalidation.nodeID]
        else {
            return
        }

        applyEndpointInvalidation(path: path, kind: invalidation.kind, nodeID: invalidation.nodeID)
        let kindDescription = String(describing: invalidation.kind)
        Logger.spiderwebfs.notice(
            "Received FS invalidation for node \(invalidation.nodeID) path \(path, privacy: .public) kind \(kindDescription, privacy: .public)"
        )
        if let invalidationHandler {
            let mountedInvalidation = SpiderwebMountedInvalidation(path: path, kind: invalidation.kind)
            Task {
                invalidationHandler(mountedInvalidation)
            }
        }
    }

    private func nextRequestTag() -> UInt32 {
        defer { nextTag &+= 1 }
        if nextTag == 0 {
            nextTag = 1
        }
        return nextTag
    }

    private func runReceiveLoop(generation: UInt64) async {
        do {
            while !Task.isCancelled {
                let envelope = try await receiveEnvelope()
                processIncomingEnvelope(envelope, generation: generation)
            }
        } catch is CancellationError {
            return
        } catch {
            await handleReceiveLoopFailure(error, generation: generation)
        }
    }

    private func processIncomingEnvelope(_ envelope: [String: Any], generation: UInt64) {
        guard generation == connectionGeneration else {
            return
        }
        let messageType = stringValue(envelope["type"]) ?? ""
        if messageType == "acheron.e_fs_inval" || messageType == "acheron.e_fs_inval_dir" {
            handleInvalidationEnvelope(envelope)
            return
        }
        guard stringValue(envelope["channel"]) == "acheron",
              let tag = uint32Value(envelope["tag"]),
              let continuation = pendingResponses.removeValue(forKey: tag)
        else {
            return
        }
        continuation.resume(returning: envelope)
    }

    private func handleReceiveLoopFailure(_ error: Error, generation: UInt64) async {
        guard generation == connectionGeneration else {
            return
        }
        receiveLoopTask = nil
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        resetEndpointState(throwing: error)
    }

    private func failPendingResponse(tag: UInt32, throwing error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: tag) else {
            return
        }
        continuation.resume(throwing: error)
    }

    private func failPendingResponses(throwing error: Error) {
        let continuations = pendingResponses.values
        pendingResponses.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }

    private func performReaddir(path: String, cookie: UInt64, maxEntries: UInt32) async throws -> SpiderwebRemoteDirectoryListing {
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
        remoteOperationSnapshot.readdir &+= 1
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_readdirp",
            expectedType: "acheron.r_fs_readdirp",
            node: resolved.nodeID,
            handle: nil,
            payload: [
                "cookie": cookie,
                "max": maxEntries,
            ]
        )
        let listing = try parseFsDirectoryListing(envelope)
        cacheDirectoryPage(path: path, parentNodeID: resolved.nodeID, cookie: cookie, maxEntries: maxEntries, listing: listing)
        return listing
    }

    private func performResolveNode(_ path: String) async throws -> SpiderwebEndpointResolvedNode {
        guard let exportSelection else {
            throw URLError(.networkConnectionLost)
        }
        let normalizedPath = normalizeRelativeEndpointPath(path)
        if normalizedPath == "/" {
            let rootAttr = try await getattrNode(nodeID: exportSelection.rootNodeID)
            let resolvedRoot = SpiderwebEndpointResolvedNode(nodeID: exportSelection.rootNodeID, attr: rootAttr)
            cacheResolvedNode(path: normalizedPath, resolved: resolvedRoot)
            return resolvedRoot
        }

        var currentNodeID = exportSelection.rootNodeID
        var currentAttr: SpiderwebRemoteAttr?
        var currentPath = "/"
        for segment in endpointPathSegments(normalizedPath) {
            currentPath = join(directoryPath: currentPath, childName: segment)
            if let cachedSegment = cachedResolvedNode(path: currentPath) {
                currentNodeID = cachedSegment.nodeID
                currentAttr = cachedSegment.attr
                rememberNode(path: currentPath, nodeID: currentNodeID)
                continue
            }
            let lookup = try await lookupChild(parentNodeID: currentNodeID, name: segment, childPath: currentPath)
            currentNodeID = lookup.nodeID
            currentAttr = lookup.attr
            rememberNode(path: currentPath, nodeID: currentNodeID)
        }

        if currentAttr == nil {
            currentAttr = try await getattrNode(nodeID: currentNodeID)
        }

        let resolved = SpiderwebEndpointResolvedNode(nodeID: currentNodeID, attr: currentAttr)
        cacheResolvedNode(path: normalizedPath, resolved: resolved)
        return resolved
    }

    private func performLookupChild(
        parentNodeID: UInt64,
        name: String,
        childPath: String,
        key: SpiderwebEndpointChildCacheKey
    ) async throws -> SpiderwebEndpointResolvedNode {
        remoteOperationSnapshot.lookup &+= 1
        do {
            let envelope = try await sendFsRequest(
                type: "acheron.t_fs_lookup",
                expectedType: "acheron.r_fs_lookup",
                node: parentNodeID,
                handle: nil,
                payload: ["name": name]
            )
            let resolved = try parseFsLookupResponse(envelope)
            cacheLookupChild(for: key, childPath: childPath, resolved: resolved)
            return resolved
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
                negativeLookupCache[key] = Date()
            }
            throw error
        }
    }

    private func performGetattrNode(nodeID: UInt64) async throws -> SpiderwebRemoteAttr {
        remoteOperationSnapshot.getattr &+= 1
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_getattr",
            expectedType: "acheron.r_fs_getattr",
            node: nodeID,
            handle: nil,
            payload: [:]
        )
        let attr = try parseFsWrappedAttr(envelope)
        cacheAttr(attr)
        return attr
    }

    func remoteOperationsSnapshot() -> SpiderwebRemoteOperationSnapshot {
        remoteOperationSnapshot
    }

    private func resetEndpointState(throwing error: Error) {
        exportSelection = nil
        openHandles.removeAll()
        nodePaths.removeAll()
        resolvedPathCache.removeAll()
        childLookupCache.removeAll()
        negativeLookupCache.removeAll()
        nodeAttrCache.removeAll()
        directoryPageCache.removeAll()
        inFlightResolutions.removeAll()
        inFlightLookups.removeAll()
        inFlightAttrs.removeAll()
        inFlightReaddirs.removeAll()
        failPendingResponses(throwing: error)
    }

    private func cachedResolvedNode(path: String) -> SpiderwebEndpointResolvedNode? {
        let normalizedPath = normalizeRelativeEndpointPath(path)
        guard let cached = resolvedPathCache[normalizedPath] else {
            return nil
        }
        guard isFresh(cached.fetchedAt) else {
            resolvedPathCache.removeValue(forKey: normalizedPath)
            return nil
        }
        if let attr = cachedAttr(nodeID: cached.value.nodeID) {
            return SpiderwebEndpointResolvedNode(nodeID: cached.value.nodeID, attr: attr)
        }
        return cached.value
    }

    private func cacheResolvedNode(path: String, resolved: SpiderwebEndpointResolvedNode) {
        let normalizedPath = normalizeRelativeEndpointPath(path)
        resolvedPathCache[normalizedPath] = SpiderwebTimedCacheEntry(value: resolved, fetchedAt: Date())
        rememberNode(path: normalizedPath, nodeID: resolved.nodeID)
        if let attr = resolved.attr {
            cacheAttr(attr)
        }
    }

    private func cachedLookupChild(for key: SpiderwebEndpointChildCacheKey) -> SpiderwebEndpointResolvedNode? {
        guard let cached = childLookupCache[key] else {
            return nil
        }
        guard isFresh(cached.fetchedAt) else {
            childLookupCache.removeValue(forKey: key)
            return nil
        }
        if let attr = cachedAttr(nodeID: cached.value.nodeID) {
            return SpiderwebEndpointResolvedNode(nodeID: cached.value.nodeID, attr: attr)
        }
        return cached.value
    }

    private func cacheLookupChild(
        for key: SpiderwebEndpointChildCacheKey,
        childPath: String,
        resolved: SpiderwebEndpointResolvedNode
    ) {
        childLookupCache[key] = SpiderwebTimedCacheEntry(value: resolved, fetchedAt: Date())
        negativeLookupCache.removeValue(forKey: key)
        cacheResolvedNode(path: childPath, resolved: resolved)
    }

    private func isNegativeLookupFresh(for key: SpiderwebEndpointChildCacheKey) -> Bool {
        guard let recordedAt = negativeLookupCache[key] else {
            return false
        }
        if isFresh(recordedAt) {
            return true
        }
        negativeLookupCache.removeValue(forKey: key)
        return false
    }

    private func cachedAttr(nodeID: UInt64) -> SpiderwebRemoteAttr? {
        guard let cached = nodeAttrCache[nodeID] else {
            return nil
        }
        guard isFresh(cached.fetchedAt) else {
            nodeAttrCache.removeValue(forKey: nodeID)
            return nil
        }
        return cached.value
    }

    private func cacheAttr(_ attr: SpiderwebRemoteAttr) {
        nodeAttrCache[attr.id] = SpiderwebTimedCacheEntry(value: attr, fetchedAt: Date())
    }

    private func cachedDirectoryPage(for key: SpiderwebEndpointDirectoryCacheKey) -> SpiderwebRemoteDirectoryListing? {
        guard let cached = directoryPageCache[key] else {
            return nil
        }
        guard isFresh(cached.fetchedAt) else {
            directoryPageCache.removeValue(forKey: key)
            return nil
        }
        return cached.value
    }

    private func cacheDirectoryPage(
        path: String,
        parentNodeID: UInt64,
        cookie: UInt64,
        maxEntries: UInt32,
        listing: SpiderwebRemoteDirectoryListing
    ) {
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let key = SpiderwebEndpointDirectoryCacheKey(path: normalizedPath, cookie: cookie, maxEntries: maxEntries)
        directoryPageCache[key] = SpiderwebTimedCacheEntry(value: listing, fetchedAt: Date())

        for entry in listing.entries {
            let childPath = join(directoryPath: normalizedPath, childName: entry.name)
            if let attr = entry.attr {
                let resolved = SpiderwebEndpointResolvedNode(nodeID: attr.id, attr: attr)
                let childKey = SpiderwebEndpointChildCacheKey(parentNodeID: parentNodeID, name: entry.name)
                cacheLookupChild(for: childKey, childPath: childPath, resolved: resolved)
            }
        }
    }

    private func invalidateCachesForMutation(path: String, parentPath: String, includeDescendants: Bool) {
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let normalizedParentPath = normalizeRelativeEndpointPath(parentPath)
        if normalizedPath != "/",
           let split = try? splitEndpointParentChild(normalizedPath),
           let parentResolved = cachedResolvedNode(path: normalizedParentPath)
        {
            let childKey = SpiderwebEndpointChildCacheKey(parentNodeID: parentResolved.nodeID, name: split.name)
            childLookupCache.removeValue(forKey: childKey)
            negativeLookupCache.removeValue(forKey: childKey)
        }
        invalidatePathCaches(normalizedPath, includeDescendants: includeDescendants, invalidateParentDirectory: true)
        invalidateDirectoryPage(path: normalizedParentPath)
    }

    private func applyEndpointInvalidation(path: String, kind: SpiderwebMountedInvalidationKind, nodeID: UInt64) {
        let normalizedPath = normalizeRelativeEndpointPath(path)
        switch kind {
        case .directory:
            invalidatePathCaches(normalizedPath, includeDescendants: true, invalidateParentDirectory: true)
        case .attr, .data, .all:
            invalidatePathCaches(normalizedPath, includeDescendants: false, invalidateParentDirectory: true)
        }
        nodeAttrCache.removeValue(forKey: nodeID)
    }

    private func invalidatePathCaches(_ path: String, includeDescendants: Bool, invalidateParentDirectory: Bool) {
        let normalizedPath = normalizeRelativeEndpointPath(path)
        let parentPath = endpointParentPath(normalizedPath)
        let prefix = normalizedPath == "/" ? "/" : normalizedPath + "/"
        let invalidatedNodeIDs = Set(
            nodePaths.compactMap { nodeID, cachedPath in
                if cachedPath == normalizedPath {
                    return nodeID
                }
                if includeDescendants, cachedPath.hasPrefix(prefix) {
                    return nodeID
                }
                return nil
            }
        )

        let resolvedKeysToRemove = resolvedPathCache.keys.filter { key in
            key == normalizedPath || (includeDescendants && key.hasPrefix(prefix))
        }
        for key in resolvedKeysToRemove {
            resolvedPathCache.removeValue(forKey: key)
        }

        for nodeID in invalidatedNodeIDs {
            nodeAttrCache.removeValue(forKey: nodeID)
            nodePaths.removeValue(forKey: nodeID)
        }

        let lookupKeysToRemove = childLookupCache.compactMap { entry -> SpiderwebEndpointChildCacheKey? in
            if invalidatedNodeIDs.contains(entry.value.value.nodeID) {
                return entry.key
            }
            guard let childPath = nodePaths[entry.value.value.nodeID] else {
                return nil
            }
            if childPath == normalizedPath {
                return entry.key
            }
            if includeDescendants, childPath.hasPrefix(prefix) {
                return entry.key
            }
            return nil
        }
        for key in lookupKeysToRemove {
            childLookupCache.removeValue(forKey: key)
            negativeLookupCache.removeValue(forKey: key)
        }

        if includeDescendants {
            for key in directoryPageCache.keys.filter({ $0.path == normalizedPath || $0.path.hasPrefix(prefix) }) {
                directoryPageCache.removeValue(forKey: key)
            }
        } else {
            invalidateDirectoryPage(path: normalizedPath)
        }

        if invalidateParentDirectory {
            invalidateDirectoryPage(path: parentPath)
        }
    }

    private func invalidateDirectoryPage(path: String) {
        let normalizedPath = normalizeRelativeEndpointPath(path)
        for key in directoryPageCache.keys.filter({ $0.path == normalizedPath }) {
            directoryPageCache.removeValue(forKey: key)
        }
    }

    private func isFresh(_ recordedAt: Date) -> Bool {
        Date().timeIntervalSince(recordedAt) <= spiderwebEndpointCacheTTL
    }
}

private struct SpiderwebMountedHandleState {
    let rawHandleID: UInt64
}

final class SpiderwebFsEndpointBridge {
    private let session: SpiderwebFsEndpointSession

    init(config: SpiderwebMountRequest.LaunchConfig.Endpoint) {
        session = SpiderwebFsEndpointSession(config: config)
    }

    func setInvalidationHandler(_ handler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?) {
        try? runBlocking(operationName: "fs.setInvalidationHandler") { [session] in
            await session.setInvalidationHandler(handler)
        }
    }

    func launchIfNeeded() throws {
        try perform(operationName: "fs.launchIfNeeded") { [session] in
            try await session.launchIfNeeded()
        }
    }

    func stop() {
        Task {
            await session.shutdown()
        }
    }

    func requireMountedRPCBridge() throws {
        try perform(operationName: "fs.ping") { [session] in
            try await session.ping()
        }
    }

    func getattr(path: String) throws -> SpiderwebRemoteAttr {
        try perform(operationName: "fs.getattr(\(path))") { [session] in
            try await session.getattr(path: path)
        }
    }

    func readdir(path: String, cookie: UInt64, maxEntries: UInt32) throws -> SpiderwebRemoteDirectoryListing {
        try perform(operationName: "fs.readdir(\(path))") { [session] in
            try await session.readdir(path: path, cookie: cookie, maxEntries: maxEntries)
        }
    }

    func statfs(path: String) throws -> SpiderwebRemoteStatFS {
        try perform(operationName: "fs.statfs(\(path))") { [session] in
            try await session.statfs(path: path)
        }
    }

    func readlink(path: String) throws -> String {
        try perform(operationName: "fs.readlink(\(path))") { [session] in
            try await session.readlink(path: path)
        }
    }

    func open(path: String, flags: UInt32) throws -> SpiderwebOpenHandleResponse {
        try perform(operationName: "fs.open(\(path))") { [session] in
            try await session.open(path: path, flags: flags)
        }
    }

    func read(handleID: UInt64, offset: UInt64, length: UInt32) throws -> Data {
        try perform(operationName: "fs.read(handle:\(handleID))") { [session] in
            try await session.read(handleID: handleID, offset: offset, length: length)
        }
    }

    func release(handleID: UInt64) throws {
        try perform(operationName: "fs.release(handle:\(handleID))") { [session] in
            try await session.release(handleID: handleID)
        }
    }

    func write(handleID: UInt64, offset: UInt64, data: Data) throws -> UInt32 {
        try perform(operationName: "fs.write(handle:\(handleID))") { [session] in
            try await session.write(handleID: handleID, offset: offset, data: data)
        }
    }

    func create(path: String, mode: UInt32, flags: UInt32) throws -> SpiderwebCreateHandleResponse {
        try perform(operationName: "fs.create(\(path))") { [session] in
            try await session.create(path: path, mode: mode, flags: flags)
        }
    }

    func truncate(path: String, size: UInt64) throws {
        try perform(operationName: "fs.truncate(\(path))") { [session] in
            try await session.truncate(path: path, size: size)
        }
    }

    func setattr(path: String, request: SpiderwebSetAttrRequest) throws -> SpiderwebRemoteAttr {
        try perform(operationName: "fs.setattr(\(path))") { [session] in
            try await session.setattr(path: path, request: request)
        }
    }

    func getxattr(path: String, name: String) throws -> Data {
        try perform(operationName: "fs.getxattr(\(path),\(name))") { [session] in
            try await session.getxattr(path: path, name: name)
        }
    }

    func setxattr(path: String, name: String, value: Data, flags: UInt32) throws {
        try perform(operationName: "fs.setxattr(\(path),\(name))") { [session] in
            try await session.setxattr(path: path, name: name, value: value, flags: flags)
        }
    }

    func listxattrs(path: String) throws -> [String] {
        try perform(operationName: "fs.listxattr(\(path))") { [session] in
            try await session.listxattrs(path: path)
        }
    }

    func removexattr(path: String, name: String) throws {
        try perform(operationName: "fs.removexattr(\(path),\(name))") { [session] in
            try await session.removexattr(path: path, name: name)
        }
    }

    func unlink(path: String) throws {
        try perform(operationName: "fs.unlink(\(path))") { [session] in
            try await session.unlink(path: path)
        }
    }

    func mkdir(path: String) throws {
        try perform(operationName: "fs.mkdir(\(path))") { [session] in
            try await session.mkdir(path: path)
        }
    }

    func rmdir(path: String) throws {
        try perform(operationName: "fs.rmdir(\(path))") { [session] in
            try await session.rmdir(path: path)
        }
    }

    func rename(oldPath: String, newPath: String) throws {
        try perform(operationName: "fs.rename(\(oldPath)->\(newPath))") { [session] in
            try await session.rename(oldPath: oldPath, newPath: newPath)
        }
    }

    func symlink(target: String, linkPath: String) throws {
        try perform(operationName: "fs.symlink(\(linkPath))") { [session] in
            try await session.symlink(target: target, linkPath: linkPath)
        }
    }

    func remoteOperationSnapshot() -> SpiderwebRemoteOperationSnapshot {
        (try? runBlocking(operationName: "fs.remoteOperationSnapshot") { [session] in
            await session.remoteOperationsSnapshot()
        }) ?? .zero
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

final class SpiderwebMountedBridge {
    private let namespaceBridge: SpiderwebNamespaceBridge

    private let stateLock = NSLock()
    private var nextHandleID: UInt64 = 1
    private var openHandles: [UInt64: SpiderwebMountedHandleState] = [:]
    private var invalidationHandler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?

    init(request: SpiderwebMountRequest) {
        namespaceBridge = SpiderwebNamespaceBridge(request: request)
    }

    func launchIfNeeded() throws {
        try namespaceBridge.launchIfNeeded()
    }

    func stop() {
        namespaceBridge.stop()
    }

    func setInvalidationHandler(_ handler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?) {
        stateLock.lock()
        invalidationHandler = handler
        stateLock.unlock()
    }

    func requireMountedRPCBridge() throws {
        try namespaceBridge.requireMountedRPCBridge()
    }

    func getattr(path: String) throws -> SpiderwebRemoteAttr {
        return try namespaceBridge.getattr(path: path)
    }

    func readdir(path: String, cookie: UInt64, maxEntries: UInt32) throws -> SpiderwebRemoteDirectoryListing {
        return try namespaceBridge.readdir(path: path, cookie: cookie, maxEntries: maxEntries)
    }

    func statfs(path: String) throws -> SpiderwebRemoteStatFS {
        return try namespaceBridge.statfs(path: path)
    }

    func readlink(path: String) throws -> String {
        return try namespaceBridge.readlink(path: path)
    }

    func open(path: String, flags: UInt32) throws -> SpiderwebOpenHandleResponse {
        let response = try namespaceBridge.open(path: path, flags: flags)
        let handleID = registerHandle(rawHandleID: response.handleID)
        return SpiderwebOpenHandleResponse(handleID: handleID, writable: response.writable)
    }

    func read(handleID: UInt64, offset: UInt64, length: UInt32) throws -> Data {
        let state = try resolveHandle(handleID)
        return try namespaceBridge.read(handleID: state.rawHandleID, offset: offset, length: length)
    }

    func release(handleID: UInt64) throws {
        let state = try takeHandle(handleID)
        try namespaceBridge.release(handleID: state.rawHandleID)
    }

    func write(handleID: UInt64, offset: UInt64, data: Data) throws -> UInt32 {
        let state = try resolveHandle(handleID)
        return try namespaceBridge.write(handleID: state.rawHandleID, offset: offset, data: data)
    }

    func create(path: String, mode: UInt32, flags: UInt32) throws -> SpiderwebRemoteAttr {
        let created = try namespaceBridge.create(path: path, mode: mode, flags: flags)
        try? namespaceBridge.release(handleID: created.handleID)
        return created.attr
    }

    func truncate(path: String, size: UInt64) throws {
        try namespaceBridge.truncate(path: path, size: size)
    }

    func setattr(path: String, request: SpiderwebSetAttrRequest) throws -> SpiderwebRemoteAttr {
        return try namespaceBridge.setattr(path: path, request: request)
    }

    func getxattr(path: String, name: String) throws -> Data {
        return try namespaceBridge.getxattr(path: path, name: name)
    }

    func setxattr(path: String, name: String, value: Data, flags: UInt32) throws {
        try namespaceBridge.setxattr(path: path, name: name, value: value, flags: flags)
    }

    func listxattrs(path: String) throws -> [String] {
        return try namespaceBridge.listxattrs(path: path)
    }

    func removexattr(path: String, name: String) throws {
        try namespaceBridge.removexattr(path: path, name: name)
    }

    func unlink(path: String) throws {
        try namespaceBridge.unlink(path: path)
    }

    func mkdir(path: String) throws {
        try namespaceBridge.mkdir(path: path)
    }

    func rmdir(path: String) throws {
        try namespaceBridge.rmdir(path: path)
    }

    func rename(oldPath: String, newPath: String) throws {
        try namespaceBridge.rename(oldPath: oldPath, newPath: newPath)
    }

    func symlink(target: String, linkPath: String) throws {
        try namespaceBridge.symlink(target: target, linkPath: linkPath)
    }

    func isWritablePath(_ path: String) -> Bool {
        !normalizeAbsolutePath(path).isEmpty
    }

    func syntheticAttrHint(path: String) -> SpiderwebRemoteAttr? {
        _ = path
        return nil
    }

    func performanceSnapshot() -> SpiderwebRemoteOperationSnapshot {
        namespaceBridge.remoteOperationSnapshot()
    }

    private func registerHandle(rawHandleID: UInt64) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let handleID = nextHandleID
        nextHandleID &+= 1
        if nextHandleID == 0 {
            nextHandleID = 1
        }
        openHandles[handleID] = SpiderwebMountedHandleState(rawHandleID: rawHandleID)
        return handleID
    }

    private func resolveHandle(_ handleID: UInt64) throws -> SpiderwebMountedHandleState {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let state = openHandles[handleID] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb mount handle"])
        }
        return state
    }

    private func takeHandle(_ handleID: UInt64) throws -> SpiderwebMountedHandleState {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let state = openHandles.removeValue(forKey: handleID) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb mount handle"])
        }
        return state
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

    func readlink(path: String) throws -> String {
        try perform(operationName: "readlink(\(path))") { [session] in
            try await session.readlink(path: path)
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

    func write(handleID: UInt64, offset: UInt64, data: Data) throws -> UInt32 {
        try perform(operationName: "write(handle:\(handleID))") { [session] in
            try await session.write(handleID: handleID, offset: offset, data: data)
        }
    }

    func create(path: String, mode: UInt32, flags: UInt32) throws -> SpiderwebCreateHandleResponse {
        try perform(operationName: "create(\(path))") { [session] in
            try await session.create(path: path, mode: mode, flags: flags)
        }
    }

    func truncate(path: String, size: UInt64) throws {
        try perform(operationName: "truncate(\(path))") { [session] in
            try await session.truncate(path: path, size: size)
        }
    }

    func setattr(path: String, request: SpiderwebSetAttrRequest) throws -> SpiderwebRemoteAttr {
        try perform(operationName: "setattr(\(path))") { [session] in
            try await session.setattr(path: path, request: request)
        }
    }

    func getxattr(path: String, name: String) throws -> Data {
        try perform(operationName: "getxattr(\(path),\(name))") { [session] in
            try await session.getxattr(path: path, name: name)
        }
    }

    func setxattr(path: String, name: String, value: Data, flags: UInt32) throws {
        try perform(operationName: "setxattr(\(path),\(name))") { [session] in
            try await session.setxattr(path: path, name: name, value: value, flags: flags)
        }
    }

    func listxattrs(path: String) throws -> [String] {
        try perform(operationName: "listxattr(\(path))") { [session] in
            try await session.listxattrs(path: path)
        }
    }

    func removexattr(path: String, name: String) throws {
        try perform(operationName: "removexattr(\(path),\(name))") { [session] in
            try await session.removexattr(path: path, name: name)
        }
    }

    func unlink(path: String) throws {
        try perform(operationName: "unlink(\(path))") { [session] in
            try await session.unlink(path: path)
        }
    }

    func mkdir(path: String) throws {
        try perform(operationName: "mkdir(\(path))") { [session] in
            try await session.mkdir(path: path)
        }
    }

    func rmdir(path: String) throws {
        try perform(operationName: "rmdir(\(path))") { [session] in
            try await session.rmdir(path: path)
        }
    }

    func rename(oldPath: String, newPath: String) throws {
        try perform(operationName: "rename(\(oldPath)->\(newPath))") { [session] in
            try await session.rename(oldPath: oldPath, newPath: newPath)
        }
    }

    func symlink(target: String, linkPath: String) throws {
        try perform(operationName: "symlink(\(linkPath))") { [session] in
            try await session.symlink(target: target, linkPath: linkPath)
        }
    }

    func remoteOperationSnapshot() -> SpiderwebRemoteOperationSnapshot {
        (try? runBlocking(operationName: "namespace.remoteOperationSnapshot") { [session] in
            await session.remoteOperationsSnapshot()
        }) ?? .zero
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
    // Finder and FSKit can issue several concurrent cold-start requests at once.
    // A 2s default is too eager and makes the mounted root look empty on first open.
    return 10_000
}()

let spiderwebFailFastCooldownMS: UInt64 = {
    let value = ProcessInfo.processInfo.environment["SPIDERWEB_FSKIT_FAIL_FAST_MS"]
        ?? ProcessInfo.processInfo.environment["SPIDERWEB_FAIL_FAST_MS"]
    if let value, let parsed = UInt64(value) {
        return parsed
    }
    return 10_000
}()

let spiderwebFSKitPerfLoggingEnabled: Bool = {
    #if DEBUG
    let value = ProcessInfo.processInfo.environment["SPIDERWEB_FSKIT_PERF_LOG"]
        ?? ProcessInfo.processInfo.environment["SPIDERWEB_PERF_LOG"]
    guard let value else {
        return false
    }
    switch value.lowercased() {
    case "1", "true", "yes", "on":
        return true
    default:
        return false
    }
    #else
    return false
    #endif
}()

private func runBlocking<T>(operationName: String, _ operation: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let outcomeQueue = DispatchQueue(label: "com.deanoc.spiderweb.runblocking")
    var outcome: Result<T, Error>?
    let task = Task {
        do {
            let value = try await operation()
            outcomeQueue.sync {
                outcome = .success(value)
            }
        } catch {
            outcomeQueue.sync {
                outcome = .failure(error)
            }
        }
        semaphore.signal()
    }

    let deadline = DispatchTime.now() + .milliseconds(Int(spiderwebBridgeTimeoutMS))
    guard semaphore.wait(timeout: deadline) == .success else {
        task.cancel()
        throw timeoutError(operationName: operationName, timeoutMS: spiderwebBridgeTimeoutMS)
    }

    let resolvedOutcome = outcomeQueue.sync { outcome }
    return try resolvedOutcome!.get()
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

private func stableSyntheticPathID(_ path: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in path.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash == 0 ? 1 : hash
}

func pathMatchesPrefixBoundary(_ path: String, _ prefix: String) -> Bool {
    let normalizedPath = normalizeAbsolutePath(path)
    let normalizedPrefix = normalizeAbsolutePath(prefix)
    if normalizedPrefix == "/" {
        return normalizedPath.hasPrefix("/")
    }
    guard normalizedPath.hasPrefix(normalizedPrefix) else {
        return false
    }
    if normalizedPath == normalizedPrefix {
        return true
    }
    let boundaryIndex = normalizedPath.index(normalizedPath.startIndex, offsetBy: normalizedPrefix.count)
    return boundaryIndex < normalizedPath.endIndex && normalizedPath[boundaryIndex] == "/"
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

private func int32Value(_ value: Any?) -> Int32? {
    switch value {
    case let number as NSNumber:
        return number.int32Value
    case let number as Int32:
        return number
    case let number as Int:
        return Int32(exactly: number)
    default:
        return nil
    }
}

private func boolValue(_ value: Any?) -> Bool? {
    value as? Bool
}

func normalizeRelativeEndpointPath(_ path: String) -> String {
    let normalized = normalizeAbsolutePath(path)
    return normalized.isEmpty ? "/" : normalized
}

func endpointPathSegments(_ path: String) -> [String] {
    let normalized = normalizeRelativeEndpointPath(path)
    if normalized == "/" {
        return []
    }
    return normalized
        .split(separator: "/")
        .filter { !$0.isEmpty && $0 != "." }
        .map(String.init)
}

func splitEndpointParentChild(_ path: String) throws -> (parentPath: String, name: String) {
    let normalized = normalizeRelativeEndpointPath(path)
    guard normalized != "/" else {
        throw POSIXError(.EINVAL)
    }
    guard let slashIndex = normalized.lastIndex(of: "/") else {
        throw POSIXError(.EINVAL)
    }
    let name = String(normalized[normalized.index(after: slashIndex)...])
    guard !name.isEmpty else {
        throw POSIXError(.EINVAL)
    }
    if slashIndex == normalized.startIndex {
        return ("/", name)
    }
    return (String(normalized[..<slashIndex]), name)
}

func endpointParentPath(_ path: String) -> String {
    let normalized = normalizeRelativeEndpointPath(path)
    guard normalized != "/" else {
        return "/"
    }
    return (try? splitEndpointParentChild(normalized).parentPath) ?? "/"
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

private func mapFsError(_ envelope: [String: Any]) -> NSError {
    let details = envelope["error"] as? [String: Any]
    if let errno = int32Value(details?["errno"] ?? details?["no"]) {
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: stringValue(details?["message"] ?? details?["msg"]) ?? "Spiderweb filesystem request failed"]
        )
    }
    let code = stringValue(details?["code"]) ?? "acheron_error"
    let message = stringValue(details?["message"] ?? details?["msg"]) ?? "Spiderweb filesystem request failed"
    return mapCodeToNSError(code: code, message: message)
}

private func parseFsExportSelection(_ envelope: [String: Any], desiredName: String?) throws -> SpiderwebEndpointExportSelection {
    guard
        let payload = envelope["payload"] as? [String: Any],
        let exports = payload["exports"] as? [[String: Any]],
        !exports.isEmpty
    else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }

    let selected: [String: Any]
    if let desiredName, !desiredName.isEmpty {
        guard let matched = exports.first(where: { stringValue($0["name"]) == desiredName }) else {
            throw SpiderwebProtocolFailure.unexpectedMessage("missing fs export \(desiredName)")
        }
        selected = matched
    } else {
        selected = exports[0]
    }

    guard let rootNodeID = uint64Value(selected["root"]) else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }

    let readOnly = boolValue(selected["ro"])
    let caps = selected["caps"] as? [String: Any]
    let caseSensitive = boolValue(caps?["case_sensitive"])
    let symlink = boolValue(caps?["symlink"])
    return SpiderwebEndpointExportSelection(
        rootNodeID: rootNodeID,
        readOnly: readOnly,
        caseSensitive: caseSensitive,
        symlink: symlink
    )
}

private func parseFsWrappedAttr(_ envelope: [String: Any]) throws -> SpiderwebRemoteAttr {
    guard let payload = envelope["payload"] as? [String: Any] else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    if let wrapped = payload["attr"] {
        let data = try JSONSerialization.data(withJSONObject: wrapped, options: [])
        return try JSONDecoder().decode(SpiderwebRemoteAttr.self, from: data)
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    return try JSONDecoder().decode(SpiderwebRemoteAttr.self, from: data)
}

private func parseFsLookupResponse(_ envelope: [String: Any]) throws -> SpiderwebEndpointResolvedNode {
    guard let payload = envelope["payload"] as? [String: Any] else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    if let wrapped = payload["attr"] {
        let data = try JSONSerialization.data(withJSONObject: wrapped, options: [])
        let attr = try JSONDecoder().decode(SpiderwebRemoteAttr.self, from: data)
        return SpiderwebEndpointResolvedNode(nodeID: attr.id, attr: attr)
    }
    guard let nodeID = uint64Value(payload["node"]) else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    return SpiderwebEndpointResolvedNode(nodeID: nodeID, attr: nil)
}

private func parseFsDirectoryListing(_ envelope: [String: Any]) throws -> SpiderwebRemoteDirectoryListing {
    guard let payload = envelope["payload"] else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    let listing = try JSONDecoder().decode(SpiderwebRemoteDirectoryListing.self, from: data)
    let filteredEntries = listing.entries.filter { entry in
        entry.name != "." && entry.name != ".."
    }
    return SpiderwebRemoteDirectoryListing(
        entries: filteredEntries,
        nextCookie: listing.nextCookie,
        eof: listing.eof,
        directoryGeneration: listing.directoryGeneration
    )
}

private func parseFsStatfs(_ envelope: [String: Any]) throws -> SpiderwebRemoteStatFS {
    guard let payload = envelope["payload"] else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [])
    return try JSONDecoder().decode(SpiderwebRemoteStatFS.self, from: data)
}

private func parseFsOpenHandle(_ envelope: [String: Any]) throws -> SpiderwebOpenHandleResponse {
    guard
        let payload = envelope["payload"] as? [String: Any],
        let handleID = uint64Value(payload["h"])
    else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    let caps = payload["caps"] as? [String: Any]
    let writable = boolValue(caps?["wr"]) ?? false
    return SpiderwebOpenHandleResponse(handleID: handleID, writable: writable)
}

private func parseFsCreateResponse(_ envelope: [String: Any]) throws -> SpiderwebCreateHandleResponse {
    guard
        let payload = envelope["payload"] as? [String: Any],
        let handleID = uint64Value(payload["h"])
    else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    let caps = payload["caps"] as? [String: Any]
    let writable = boolValue(caps?["wr"]) ?? true
    return SpiderwebCreateHandleResponse(
        handleID: handleID,
        attr: try parseFsWrappedAttr(envelope),
        writable: writable
    )
}

private func parseFsReadData(_ envelope: [String: Any]) throws -> Data {
    guard
        let payload = envelope["payload"] as? [String: Any],
        let dataB64 = stringValue(payload["data_b64"]),
        let data = Data(base64Encoded: dataB64)
    else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    return data
}

private func parseFsWriteCount(_ envelope: [String: Any]) throws -> UInt32 {
    guard
        let payload = envelope["payload"] as? [String: Any],
        let count = uint32Value(payload["n"])
    else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    return count
}

private func parseFsXattrData(_ envelope: [String: Any]) throws -> Data {
    guard
        let payload = envelope["payload"] as? [String: Any],
        let valueB64 = stringValue(payload["value_b64"]),
        let data = Data(base64Encoded: valueB64)
    else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    return data
}

private func parseFsReadlinkTarget(_ envelope: [String: Any]) throws -> String {
    guard
        let payload = envelope["payload"] as? [String: Any],
        let target = stringValue(payload["target"])
    else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    return target
}

private func parseFsXattrNames(_ envelope: [String: Any]) throws -> [String] {
    guard
        let payload = envelope["payload"] as? [String: Any],
        let names = payload["names"] as? [String]
    else {
        throw SpiderwebProtocolFailure.invalidEnvelope
    }
    return names
}

private func parseFsInvalidationEnvelope(_ envelope: [String: Any]) -> SpiderwebEndpointInvalidation? {
    guard
        stringValue(envelope["channel"]) == "acheron",
        let messageType = stringValue(envelope["type"]),
        let payload = envelope["payload"] as? [String: Any]
    else {
        return nil
    }

    switch messageType {
    case "acheron.e_fs_inval":
        guard let nodeID = uint64Value(payload["node"]) else {
            return nil
        }
        let kind: SpiderwebMountedInvalidationKind
        switch stringValue(payload["what"]) ?? "all" {
        case "attr":
            kind = .attr
        case "data":
            kind = .data
        default:
            kind = .all
        }
        return SpiderwebEndpointInvalidation(nodeID: nodeID, kind: kind)

    case "acheron.e_fs_inval_dir":
        guard let nodeID = uint64Value(payload["dir"]) else {
            return nil
        }
        return SpiderwebEndpointInvalidation(nodeID: nodeID, kind: .directory)

    default:
        return nil
    }
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
