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
        try bridge.launchIfNeeded()
        try bridge.requireMountedRPCBridge()
        return bridge
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

    func write(handleID: UInt64, offset: UInt64, data: Data) async throws -> UInt32 {
        try await withReconnect { session in
            try await session.writeHandle(handleID: handleID, offset: offset, data: data)
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

        var names: [String] = []
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
        try await flushNamespaceWrites()
        try await clunk(fid: state.fid)
    }

    private func readFile(handleID: UInt64, offset: UInt64, length: UInt32) async throws -> Data {
        guard let state = openHandles[handleID] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb handle"])
        }
        return try await readFid(fid: state.fid, offset: offset, count: length)
    }

    private func writeHandle(handleID: UInt64, offset: UInt64, data: Data) async throws -> UInt32 {
        guard let state = openHandles[handleID] else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EBADF), userInfo: [NSLocalizedDescriptionKey: "Unknown Spiderweb handle"])
        }
        guard state.writable else {
            throw readOnlyError(message: "Spiderweb path \(state.path) is read-only")
        }
        let written = try await writeFid(fid: state.fid, offset: offset, data: data)
        try await flushNamespaceWrites()
        return written
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

    private func flushNamespaceWrites() async throws {
        _ = try await sendAcheronRequest(
            type: "acheron.t_flush",
            expectedType: "acheron.r_flush",
            fields: [:]
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

    private func writeFid(fid: UInt32, offset: UInt64, data: Data) async throws -> UInt32 {
        let envelope = try await sendAcheronRequest(
            type: "acheron.t_write",
            expectedType: "acheron.r_write",
            fields: [
                "fid": fid,
                "offset": offset,
                "data_b64": data.base64EncodedString(),
            ]
        )
        guard
            let payload = envelope["payload"] as? [String: Any],
            let count = uint32Value(payload["n"] ?? payload["count"])
        else {
            throw SpiderwebProtocolFailure.invalidEnvelope
        }
        return count
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
            flags: 0,
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

actor SpiderwebFsEndpointSession {
    private let config: SpiderwebMountRequest.LaunchConfig.Endpoint

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?
    private var connectionGeneration: UInt64 = 0
    private var nextTag: UInt32 = 1
    private var exportSelection: SpiderwebEndpointExportSelection?
    private var openHandles: [UInt64: SpiderwebEndpointHandleState] = [:]
    private var nodePaths: [UInt64: String] = [:]
    private var invalidationHandler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?
    private var pendingResponses: [UInt32: CheckedContinuation<[String: Any], Error>] = [:]

    init(config: SpiderwebMountRequest.LaunchConfig.Endpoint) {
        self.config = config
    }

    func setInvalidationHandler(_ handler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?) {
        invalidationHandler = handler
    }

    func launchIfNeeded() async throws {
        if webSocketTask != nil {
            return
        }
        try await connectFresh()
    }

    func shutdown() async {
        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        if let task = webSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        exportSelection = nil
        openHandles.removeAll()
        nodePaths.removeAll()
        failPendingResponses(throwing: URLError(.cancelled))
    }

    func ping() async throws {
        _ = try await statfs(path: "/")
    }

    func getattr(path: String) async throws -> SpiderwebRemoteAttr {
        try await launchIfNeeded()
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
        if let attr = resolved.attr {
            return attr
        }
        let attr = try await getattrNode(nodeID: resolved.nodeID)
        rememberNode(path: path, nodeID: attr.id)
        return attr
    }

    func readdir(path: String, cookie: UInt64, maxEntries: UInt32) async throws -> SpiderwebRemoteDirectoryListing {
        try await launchIfNeeded()
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
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
        for entry in listing.entries {
            guard let attr = entry.attr else { continue }
            rememberNode(path: join(directoryPath: path, childName: entry.name), nodeID: attr.id)
        }
        return listing
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
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_open",
            expectedType: "acheron.r_fs_open",
            node: resolved.nodeID,
            handle: nil,
            payload: ["flags": flags]
        )
        let response = try parseFsOpenHandle(envelope)
        openHandles[response.handleID] = SpiderwebEndpointHandleState(
            path: normalizeRelativeEndpointPath(path),
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
        return try parseFsWriteCount(envelope)
    }

    func create(path: String, mode: UInt32, flags: UInt32) async throws -> SpiderwebCreateHandleResponse {
        try await launchIfNeeded()
        try ensureWritable()
        let split = try splitEndpointParentChild(path)
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
        rememberNode(path: path, nodeID: created.attr.id)
        openHandles[created.handleID] = SpiderwebEndpointHandleState(
            path: normalizeRelativeEndpointPath(path),
            nodeID: created.attr.id,
            flags: flags,
            writable: created.writable
        )
        return created
    }

    func truncate(path: String, size: UInt64) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_truncate",
            expectedType: "acheron.r_fs_truncate",
            node: resolved.nodeID,
            handle: nil,
            payload: ["sz": size]
        )
    }

    func setattr(path: String, request: SpiderwebSetAttrRequest) async throws -> SpiderwebRemoteAttr {
        try await launchIfNeeded()
        try ensureWritable()
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
        guard !request.isEmpty else {
            if let attr = resolved.attr {
                return attr
            }
            let attr = try await getattrNode(nodeID: resolved.nodeID)
            rememberNode(path: path, nodeID: attr.id)
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
        rememberNode(path: path, nodeID: attr.id)
        return attr
    }

    func getxattr(path: String, name: String) async throws -> Data {
        try await launchIfNeeded()
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
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
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
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
    }

    func listxattrs(path: String) async throws -> [String] {
        try await launchIfNeeded()
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
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
        let resolved = try await resolveNode(path)
        rememberNode(path: path, nodeID: resolved.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_removexattr",
            expectedType: "acheron.r_fs_removexattr",
            node: resolved.nodeID,
            handle: nil,
            payload: ["name": name]
        )
    }

    func unlink(path: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let split = try splitEndpointParentChild(path)
        let parent = try await resolveNode(split.parentPath)
        rememberNode(path: split.parentPath, nodeID: parent.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_unlink",
            expectedType: "acheron.r_fs_unlink",
            node: parent.nodeID,
            handle: nil,
            payload: ["name": split.name]
        )
    }

    func mkdir(path: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let split = try splitEndpointParentChild(path)
        let parent = try await resolveNode(split.parentPath)
        rememberNode(path: split.parentPath, nodeID: parent.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_mkdir",
            expectedType: "acheron.r_fs_mkdir",
            node: parent.nodeID,
            handle: nil,
            payload: ["name": split.name]
        )
    }

    func rmdir(path: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let split = try splitEndpointParentChild(path)
        let parent = try await resolveNode(split.parentPath)
        rememberNode(path: split.parentPath, nodeID: parent.nodeID)
        _ = try await sendFsRequest(
            type: "acheron.t_fs_rmdir",
            expectedType: "acheron.r_fs_rmdir",
            node: parent.nodeID,
            handle: nil,
            payload: ["name": split.name]
        )
    }

    func rename(oldPath: String, newPath: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        let oldSplit = try splitEndpointParentChild(oldPath)
        let newSplit = try splitEndpointParentChild(newPath)
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
    }

    func symlink(target: String, linkPath: String) async throws {
        try await launchIfNeeded()
        try ensureWritable()
        try ensureSymlinkSupported()
        let split = try splitEndpointParentChild(linkPath)
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
        self.exportSelection = nil
        self.openHandles.removeAll()
        self.nodePaths.removeAll()
        failPendingResponses(throwing: URLError(.cancelled))
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
            rememberNode(path: "/", nodeID: selection.rootNodeID)
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
        guard let exportSelection else {
            throw URLError(.networkConnectionLost)
        }
        let normalizedPath = normalizeRelativeEndpointPath(path)
        if normalizedPath == "/" {
            rememberNode(path: normalizedPath, nodeID: exportSelection.rootNodeID)
            return SpiderwebEndpointResolvedNode(
                nodeID: exportSelection.rootNodeID,
                attr: try await getattrNode(nodeID: exportSelection.rootNodeID)
            )
        }

        var currentNodeID = exportSelection.rootNodeID
        var currentAttr: SpiderwebRemoteAttr?
        var currentPath = "/"
        for segment in endpointPathSegments(normalizedPath) {
            let lookup = try await lookupChild(parentNodeID: currentNodeID, name: segment)
            currentNodeID = lookup.nodeID
            currentAttr = lookup.attr
            currentPath = join(directoryPath: currentPath, childName: segment)
            rememberNode(path: currentPath, nodeID: currentNodeID)
        }

        if currentAttr == nil {
            currentAttr = try await getattrNode(nodeID: currentNodeID)
        }

        return SpiderwebEndpointResolvedNode(nodeID: currentNodeID, attr: currentAttr)
    }

    private func lookupChild(parentNodeID: UInt64, name: String) async throws -> SpiderwebEndpointResolvedNode {
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_lookup",
            expectedType: "acheron.r_fs_lookup",
            node: parentNodeID,
            handle: nil,
            payload: ["name": name]
        )
        return try parseFsLookupResponse(envelope)
    }

    private func getattrNode(nodeID: UInt64) async throws -> SpiderwebRemoteAttr {
        let envelope = try await sendFsRequest(
            type: "acheron.t_fs_getattr",
            expectedType: "acheron.r_fs_getattr",
            node: nodeID,
            handle: nil,
            payload: [:]
        )
        return try parseFsWrappedAttr(envelope)
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
                    await self.failPendingResponse(tag: tag, throwing: error)
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
              let path = nodePaths[invalidation.nodeID],
              let invalidationHandler
        else {
            return
        }

        let kindDescription = String(describing: invalidation.kind)
        Logger.spiderwebfs.notice(
            "Received FS invalidation for node \(invalidation.nodeID) path \(path, privacy: .public) kind \(kindDescription, privacy: .public)"
        )
        let mountedInvalidation = SpiderwebMountedInvalidation(path: path, kind: invalidation.kind)
        Task {
            invalidationHandler(mountedInvalidation)
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
                await processIncomingEnvelope(envelope, generation: generation)
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
        exportSelection = nil
        openHandles.removeAll()
        nodePaths.removeAll()
        failPendingResponses(throwing: error)
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
}

private struct SpiderwebMountedEndpoint {
    let mountPath: String
    let bridge: SpiderwebFsEndpointBridge
}

private enum SpiderwebMountedHandleBackend {
    case namespace
    case endpoint(Int)
}

private struct SpiderwebMountedHandleState {
    let backend: SpiderwebMountedHandleBackend
    let rawHandleID: UInt64
}

private struct SpiderwebMountedPathRoute {
    let endpointIndex: Int
    let relativePath: String
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
    private let endpointMounts: [SpiderwebMountedEndpoint]

    private let stateLock = NSLock()
    private var nextHandleID: UInt64 = 1
    private var openHandles: [UInt64: SpiderwebMountedHandleState] = [:]
    private var invalidationHandler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?

    init(request: SpiderwebMountRequest) {
        namespaceBridge = SpiderwebNamespaceBridge(request: request)
        endpointMounts = request.launchConfig.endpoints
            .map {
                SpiderwebMountedEndpoint(
                    mountPath: normalizeAbsolutePath($0.mountPath),
                    bridge: SpiderwebFsEndpointBridge(config: $0)
                )
            }
            .sorted { lhs, rhs in
                lhs.mountPath.count > rhs.mountPath.count
            }
    }

    func launchIfNeeded() throws {
        try namespaceBridge.launchIfNeeded()
    }

    func stop() {
        namespaceBridge.stop()
        for endpoint in endpointMounts {
            endpoint.bridge.setInvalidationHandler(nil)
            endpoint.bridge.stop()
        }
    }

    func setInvalidationHandler(_ handler: (@Sendable (SpiderwebMountedInvalidation) -> Void)?) {
        stateLock.lock()
        invalidationHandler = handler
        stateLock.unlock()

        for endpoint in endpointMounts {
            let mountPath = endpoint.mountPath
            endpoint.bridge.setInvalidationHandler { [weak self] invalidation in
                self?.publishInvalidation(fromMountPath: mountPath, invalidation: invalidation)
            }
        }
    }

    func requireMountedRPCBridge() throws {
        try namespaceBridge.requireMountedRPCBridge()
    }

    func getattr(path: String) throws -> SpiderwebRemoteAttr {
        if let route = routeForPath(path) {
            return try endpointMounts[route.endpointIndex].bridge.getattr(path: route.relativePath)
        }
        return try namespaceBridge.getattr(path: path)
    }

    func readdir(path: String, cookie: UInt64, maxEntries: UInt32) throws -> SpiderwebRemoteDirectoryListing {
        if let route = routeForPath(path) {
            return try endpointMounts[route.endpointIndex].bridge.readdir(path: route.relativePath, cookie: cookie, maxEntries: maxEntries)
        }
        return try namespaceBridge.readdir(path: path, cookie: cookie, maxEntries: maxEntries)
    }

    func statfs(path: String) throws -> SpiderwebRemoteStatFS {
        if let route = routeForPath(path) {
            return try endpointMounts[route.endpointIndex].bridge.statfs(path: route.relativePath)
        }
        return try namespaceBridge.statfs(path: path)
    }

    func readlink(path: String) throws -> String {
        guard let route = routeForPath(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: [NSLocalizedDescriptionKey: "Symbolic link targets are only supported on mounted exports"])
        }
        return try endpointMounts[route.endpointIndex].bridge.readlink(path: route.relativePath)
    }

    func open(path: String, flags: UInt32) throws -> SpiderwebOpenHandleResponse {
        if let route = routeForPath(path) {
            let response = try endpointMounts[route.endpointIndex].bridge.open(path: route.relativePath, flags: flags)
            let handleID = registerHandle(.endpoint(route.endpointIndex), rawHandleID: response.handleID)
            return SpiderwebOpenHandleResponse(handleID: handleID, writable: response.writable)
        }

        let response = try namespaceBridge.open(path: path, flags: flags)
        let handleID = registerHandle(.namespace, rawHandleID: response.handleID)
        return SpiderwebOpenHandleResponse(handleID: handleID, writable: response.writable)
    }

    func read(handleID: UInt64, offset: UInt64, length: UInt32) throws -> Data {
        let state = try resolveHandle(handleID)
        switch state.backend {
        case .namespace:
            return try namespaceBridge.read(handleID: state.rawHandleID, offset: offset, length: length)
        case .endpoint(let endpointIndex):
            return try endpointMounts[endpointIndex].bridge.read(handleID: state.rawHandleID, offset: offset, length: length)
        }
    }

    func release(handleID: UInt64) throws {
        let state = try takeHandle(handleID)
        switch state.backend {
        case .namespace:
            try namespaceBridge.release(handleID: state.rawHandleID)
        case .endpoint(let endpointIndex):
            try endpointMounts[endpointIndex].bridge.release(handleID: state.rawHandleID)
        }
    }

    func write(handleID: UInt64, offset: UInt64, data: Data) throws -> UInt32 {
        let state = try resolveHandle(handleID)
        switch state.backend {
        case .namespace:
            return try namespaceBridge.write(handleID: state.rawHandleID, offset: offset, data: data)
        case .endpoint(let endpointIndex):
            return try endpointMounts[endpointIndex].bridge.write(handleID: state.rawHandleID, offset: offset, data: data)
        }
    }

    func create(path: String, mode: UInt32, flags: UInt32) throws -> SpiderwebRemoteAttr {
        guard let route = routeForPath(path) else {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }
        let created = try endpointMounts[route.endpointIndex].bridge.create(path: route.relativePath, mode: mode, flags: flags)
        try? endpointMounts[route.endpointIndex].bridge.release(handleID: created.handleID)
        return created.attr
    }

    func truncate(path: String, size: UInt64) throws {
        guard let route = routeForPath(path) else {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }
        try endpointMounts[route.endpointIndex].bridge.truncate(path: route.relativePath, size: size)
    }

    func setattr(path: String, request: SpiderwebSetAttrRequest) throws -> SpiderwebRemoteAttr {
        guard let route = routeForPath(path) else {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }
        return try endpointMounts[route.endpointIndex].bridge.setattr(path: route.relativePath, request: request)
    }

    func getxattr(path: String, name: String) throws -> Data {
        guard let route = routeForPath(path) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: [NSLocalizedDescriptionKey: "Extended attributes are only supported on mounted exports"])
        }
        return try endpointMounts[route.endpointIndex].bridge.getxattr(path: route.relativePath, name: name)
    }

    func setxattr(path: String, name: String, value: Data, flags: UInt32) throws {
        guard let route = routeForPath(path) else {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }
        try endpointMounts[route.endpointIndex].bridge.setxattr(path: route.relativePath, name: name, value: value, flags: flags)
    }

    func listxattrs(path: String) throws -> [String] {
        guard let route = routeForPath(path) else {
            return []
        }
        return try endpointMounts[route.endpointIndex].bridge.listxattrs(path: route.relativePath)
    }

    func removexattr(path: String, name: String) throws {
        guard let route = routeForPath(path) else {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }
        try endpointMounts[route.endpointIndex].bridge.removexattr(path: route.relativePath, name: name)
    }

    func unlink(path: String) throws {
        guard let route = routeForPath(path) else {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }
        try endpointMounts[route.endpointIndex].bridge.unlink(path: route.relativePath)
    }

    func mkdir(path: String) throws {
        guard let route = routeForPath(path) else {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }
        try endpointMounts[route.endpointIndex].bridge.mkdir(path: route.relativePath)
    }

    func rmdir(path: String) throws {
        guard let route = routeForPath(path) else {
            throw readOnlyError(message: "Spiderweb path \(path) is read-only")
        }
        try endpointMounts[route.endpointIndex].bridge.rmdir(path: route.relativePath)
    }

    func rename(oldPath: String, newPath: String) throws {
        guard
            let oldRoute = routeForPath(oldPath),
            let newRoute = routeForPath(newPath)
        else {
            throw readOnlyError(message: "Spiderweb rename is only supported inside writable mounted exports")
        }
        guard oldRoute.endpointIndex == newRoute.endpointIndex else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV), userInfo: [NSLocalizedDescriptionKey: "Cross-export rename is not supported"])
        }
        try endpointMounts[oldRoute.endpointIndex].bridge.rename(oldPath: oldRoute.relativePath, newPath: newRoute.relativePath)
    }

    func symlink(target: String, linkPath: String) throws {
        guard let route = routeForPath(linkPath) else {
            throw readOnlyError(message: "Spiderweb path \(linkPath) is read-only")
        }
        try endpointMounts[route.endpointIndex].bridge.symlink(target: target, linkPath: route.relativePath)
    }

    func isWritablePath(_ path: String) -> Bool {
        routeForPath(path) != nil
    }

    private func routeForPath(_ path: String) -> SpiderwebMountedPathRoute? {
        let normalizedPath = normalizeAbsolutePath(path)
        for (index, endpoint) in endpointMounts.enumerated() {
            guard let relativePath = matchMountedPath(normalizedPath, mountPath: endpoint.mountPath) else {
                continue
            }
            return SpiderwebMountedPathRoute(endpointIndex: index, relativePath: relativePath)
        }
        return nil
    }

    private func registerHandle(_ backend: SpiderwebMountedHandleBackend, rawHandleID: UInt64) -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        let handleID = nextHandleID
        nextHandleID &+= 1
        if nextHandleID == 0 {
            nextHandleID = 1
        }
        openHandles[handleID] = SpiderwebMountedHandleState(backend: backend, rawHandleID: rawHandleID)
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

    private func publishInvalidation(fromMountPath mountPath: String, invalidation: SpiderwebMountedInvalidation) {
        let normalizedMountPath = normalizeAbsolutePath(mountPath)
        let normalizedRelativePath = normalizeRelativeEndpointPath(invalidation.path)
        let absolutePath = if normalizedRelativePath == "/" {
            normalizedMountPath
        } else {
            join(directoryPath: normalizedMountPath, childName: String(normalizedRelativePath.dropFirst()))
        }

        stateLock.lock()
        let handler = invalidationHandler
        stateLock.unlock()

        handler?(SpiderwebMountedInvalidation(path: absolutePath, kind: invalidation.kind))
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

    func write(handleID: UInt64, offset: UInt64, data: Data) throws -> UInt32 {
        try perform(operationName: "write(handle:\(handleID))") { [session] in
            try await session.write(handleID: handleID, offset: offset, data: data)
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

func matchMountedPath(_ path: String, mountPath: String) -> String? {
    let normalizedPath = normalizeAbsolutePath(path)
    let normalizedMount = normalizeAbsolutePath(mountPath)

    if normalizedMount == "/" {
        return normalizedPath
    }
    guard normalizedPath.hasPrefix(normalizedMount) else {
        return nil
    }
    if normalizedPath == normalizedMount {
        return "/"
    }
    guard normalizedPath.dropFirst(normalizedMount.count).first == "/" else {
        return nil
    }
    let suffix = String(normalizedPath.dropFirst(normalizedMount.count))
    return suffix.isEmpty ? "/" : suffix
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
