import Foundation

enum SpiderAppWorkflowID: String {
    case startLocalWorkspace = "start_local_workspace"
    case addSecondDevice = "add_second_device"
    case installPackage = "install_package"
    case runRemoteService = "run_remote_service"
    case connectToAnotherSpiderweb = "connect_to_another_spiderweb"
    case spiderwebHandoffCompleted = "spiderweb_handoff_completed"
}

enum SpiderAppDeepLinkRoute: String {
    case workspace
    case devices
    case capabilities
    case explore
    case settings
}

enum SpiderAppDeepLinkAction: String {
    case openWorkspace = "open_workspace"
    case openDevices = "open_devices"
    case openCapabilities = "open_capabilities"
    case openExplore = "open_explore"
    case openSettings = "open_settings"
}

private struct SpiderAppWorkflowEntry {
    var profileID: String
    var workspaceID: String?
    var workflowID: String
    var completedAtMS: Int64
}

enum SpiderAppWorkflowStore {
    static let defaultProfileID = "default"

    static func hasCompletion(_ workflowID: SpiderAppWorkflowID, profileID: String = defaultProfileID, workspaceID: String? = nil) -> Bool {
        loadEntries().contains { entry in
            guard entry.profileID == profileID else { return false }
            guard entry.workflowID == workflowID.rawValue else { return false }
            return normalize(entry.workspaceID) == normalize(workspaceID)
        }
    }

    static func hasAnyCompletion(_ workflowID: SpiderAppWorkflowID, profileID: String = defaultProfileID) -> Bool {
        loadEntries().contains { entry in
            entry.profileID == profileID && entry.workflowID == workflowID.rawValue
        }
    }

    static func markCompleted(_ workflowID: SpiderAppWorkflowID, profileID: String = defaultProfileID, workspaceID: String? = nil) {
        updateRootObject { rootObject in
            var entries = parseEntries(from: rootObject)
            let normalizedWorkspaceID = normalize(workspaceID)
            let nowMS = Int64(Date().timeIntervalSince1970 * 1000)

            if let index = entries.firstIndex(where: {
                $0.profileID == profileID &&
                $0.workflowID == workflowID.rawValue &&
                normalize($0.workspaceID) == normalizedWorkspaceID
            }) {
                entries[index].completedAtMS = nowMS
            } else {
                entries.append(
                    SpiderAppWorkflowEntry(
                        profileID: profileID,
                        workspaceID: normalizedWorkspaceID,
                        workflowID: workflowID.rawValue,
                        completedAtMS: nowMS
                    )
                )
            }

            rootObject["onboarding_workflows"] = entries.map { entry in
                var dict: [String: Any] = [
                    "profile_id": entry.profileID,
                    "workflow_id": entry.workflowID,
                    "completed_at_ms": entry.completedAtMS
                ]
                if let workspaceID = normalize(entry.workspaceID) {
                    dict["workspace_id"] = workspaceID
                }
                return dict
            }
        }
    }

    static func deepLinkURL(
        profileID: String = defaultProfileID,
        workspaceID: String? = nil,
        route: SpiderAppDeepLinkRoute,
        action: SpiderAppDeepLinkAction? = nil,
        mountpoint: String? = nil,
        degraded: Bool = false,
        handoff: Bool = false
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "spiderapp"
        components.host = "open"

        var queryItems = [URLQueryItem(name: "profile_id", value: profileID)]
        if let workspaceID = normalize(workspaceID) {
            queryItems.append(URLQueryItem(name: "workspace_id", value: workspaceID))
        }
        queryItems.append(URLQueryItem(name: "route", value: route.rawValue))
        if let action {
            queryItems.append(URLQueryItem(name: "action", value: action.rawValue))
        }
        if let mountpoint = normalize(mountpoint) {
            queryItems.append(URLQueryItem(name: "mountpoint", value: mountpoint))
        }
        if degraded {
            queryItems.append(URLQueryItem(name: "degraded", value: "1"))
        }
        if handoff {
            queryItems.append(URLQueryItem(name: "handoff", value: "1"))
        }
        components.queryItems = queryItems
        return components.url
    }

    private static func configURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/spider", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    private static func loadEntries() -> [SpiderAppWorkflowEntry] {
        guard let data = try? Data(contentsOf: configURL()),
              let rootObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return []
        }
        return parseEntries(from: rootObject)
    }

    private static func parseEntries(from rootObject: [String: Any]) -> [SpiderAppWorkflowEntry] {
        guard let rawEntries = rootObject["onboarding_workflows"] as? [[String: Any]] else { return [] }
        return rawEntries.compactMap { raw in
            guard let profileID = normalize(raw["profile_id"] as? String),
                  let workflowID = normalize(raw["workflow_id"] as? String) else {
                return nil
            }
            let completedAtMS = (raw["completed_at_ms"] as? NSNumber)?.int64Value ?? 0
            return SpiderAppWorkflowEntry(
                profileID: profileID,
                workspaceID: normalize(raw["workspace_id"] as? String),
                workflowID: workflowID,
                completedAtMS: completedAtMS
            )
        }
    }

    private static func updateRootObject(_ mutate: (inout [String: Any]) -> Void) {
        let url = configURL()
        let configDirectory = url.deletingLastPathComponent()

        var rootObject: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let loaded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            rootObject = loaded
        }
        if rootObject["schema_version"] == nil {
            rootObject["schema_version"] = 2
        }

        mutate(&rootObject)

        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: rootObject, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("SpiderAppWorkflowStore save failed: %@", error.localizedDescription)
        }
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
