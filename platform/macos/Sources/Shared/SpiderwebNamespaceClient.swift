import Darwin
import Foundation
import OSLog

private let spiderwebControlProtocol = "unified-v2"
private let spiderwebAcheronRuntimeVersion = "acheron-1"

private let syntheticStatFS = SpiderwebRemoteStatFS(
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
    private let logger = Logger(subsystem: "com.deanoc.spiderweb.fskit.app", category: "namespace")
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

    func create(path: String, mode: UInt32, flags: UInt32) async throws -> SpiderwebOpenHandleResponse {
        _ = path
        _ = mode
        _ = flags
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
    }

    func write(handleID: UInt64, offset: UInt64, contents: Data) async throws -> UInt32 {
        _ = handleID
        _ = offset
        _ = contents
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
    }

    func truncate(path: String, size: UInt64) async throws {
        _ = path
        _ = size
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
    }

    func unlink(path: String) async throws {
        _ = path
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
    }

    func mkdir(path: String) async throws {
        _ = path
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
    }

    func rmdir(path: String) async throws {
        _ = path
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
    }

    func rename(oldPath: String, newPath: String) async throws {
        _ = oldPath
        _ = newPath
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
    }

    func symlink(target: String, linkPath: String) async throws {
        _ = target
        _ = linkPath
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
    }

    func getXattr(path: String, name: String) async throws -> Data {
        _ = path
        _ = name
        throw noAttributeError(message: "No extended attributes available")
    }

    func listXattrs(path: String) async throws -> [String] {
        _ = path
        return []
    }

    func setXattr(path: String, name: String, value: Data?, policy: UInt32) async throws {
        _ = path
        _ = name
        _ = value
        _ = policy
        throw readOnlyError(message: "Native Spiderweb FSKit writes are not enabled yet")
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
            guard let refreshed = openHandles.removeValue(forKey: response.handleID) else { continue }
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
            return SpiderwebRemoteDirectoryListing(entries: [], nextCookie: 0, eof: true, directoryGeneration: 0)
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
        let envelope = try await sendAcheronRequest(
            type: "acheron.t_walk",
            expectedType: "acheron.r_walk",
            fields: [
                "fid": 1,
                "newfid": fid,
                "path": segments,
            ]
        )
        _ = envelope
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
        self.session = SpiderwebNamespaceSession(request: request)
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

    func create(path: String, mode: UInt32, flags: UInt32) throws -> SpiderwebOpenHandleResponse {
        try perform(operationName: "create(\(path))") { [session] in
            try await session.create(path: path, mode: mode, flags: flags)
        }
    }

    func read(handleID: UInt64, offset: UInt64, length: UInt32) throws -> Data {
        try perform(operationName: "read(handle:\(handleID))") { [session] in
            try await session.read(handleID: handleID, offset: offset, length: length)
        }
    }

    func write(handleID: UInt64, offset: UInt64, contents: Data) throws -> UInt32 {
        try perform(operationName: "write(handle:\(handleID))") { [session] in
            try await session.write(handleID: handleID, offset: offset, contents: contents)
        }
    }

    func release(handleID: UInt64) throws {
        try perform(operationName: "release(handle:\(handleID))") { [session] in
            try await session.release(handleID: handleID)
        }
    }

    func truncate(path: String, size: UInt64) throws {
        try perform(operationName: "truncate(\(path))") { [session] in
            try await session.truncate(path: path, size: size)
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
        try perform(operationName: "rename(\(oldPath))") { [session] in
            try await session.rename(oldPath: oldPath, newPath: newPath)
        }
    }

    func symlink(target: String, linkPath: String) throws {
        try perform(operationName: "symlink(\(linkPath))") { [session] in
            try await session.symlink(target: target, linkPath: linkPath)
        }
    }

    func getXattr(path: String, name: String) throws -> Data {
        try perform(operationName: "getxattr(\(path))") { [session] in
            try await session.getXattr(path: path, name: name)
        }
    }

    func listXattrs(path: String) throws -> [String] {
        try perform(operationName: "listxattr(\(path))") { [session] in
            try await session.listXattrs(path: path)
        }
    }

    func setXattr(path: String, name: String, value: Data?, policy: UInt32) throws {
        try perform(operationName: "setxattr(\(path))") { [session] in
            try await session.setXattr(path: path, name: name, value: value, policy: policy)
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
    let outcomeQueue = DispatchQueue(label: "com.deanoc.spiderweb.fskit.bridge-outcome")
    var outcome: Result<T, Error>?
    let task = Task {
        let result: Result<T, Error>
        do {
            result = .success(try await operation())
        } catch {
            result = .failure(error)
        }
        outcomeQueue.sync {
            outcome = result
        }
        semaphore.signal()
    }

    let deadline = DispatchTime.now() + .milliseconds(Int(spiderwebBridgeTimeoutMS))
    guard semaphore.wait(timeout: deadline) == .success else {
        task.cancel()
        throw timeoutError(operationName: operationName, timeoutMS: spiderwebBridgeTimeoutMS)
    }

    let resolvedOutcome: Result<T, Error>? = outcomeQueue.sync {
        outcome
    }
    return try resolvedOutcome!.get()
}

private func join(directoryPath: String, childName: String) -> String {
    let normalizedDirectory = normalizeAbsolutePath(directoryPath)
    if normalizedDirectory == "/" {
        return "/" + childName
    }
    return normalizedDirectory + "/" + childName
}

private func normalizeAbsolutePath(_ path: String) -> String {
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
        return NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: stringValue(details?["message"]) ?? "Spiderweb filesystem request failed"])
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

func noAttributeError(message: String) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(ENODATA), userInfo: [NSLocalizedDescriptionKey: message])
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
