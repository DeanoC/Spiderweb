const std = @import("std");
const builtin = @import("builtin");
const managed_bundle_signatures = @import("managed_bundle_signatures.zig");
const registry_signatures = @import("venom_registry_signatures.zig");

const registry_schema_version = "spidervenom-registry-v1";
const supported_bundle_artifact_version = "1";

pub const Policy = struct {
    enabled: bool,
    source_url: []const u8,
    default_channel: []const u8,
    overrides_json: []const u8,
};

pub const ReleaseQuery = struct {
    package_id: []const u8,
    release_version: ?[]const u8 = null,
    channel: ?[]const u8 = null,
};

pub const InstallableRelease = struct {
    package_id: []u8,
    release_json: []u8,

    pub fn deinit(self: *InstallableRelease, allocator: std.mem.Allocator) void {
        allocator.free(self.package_id);
        allocator.free(self.release_json);
        self.* = undefined;
    }
};

pub const InstallBundleResult = struct {
    bundle_id: []u8,
    selected_package_id: []u8,
    selected_release_version: []u8,
    releases: std.ArrayListUnmanaged(InstallableRelease) = .{},

    pub fn deinit(self: *InstallBundleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.bundle_id);
        allocator.free(self.selected_package_id);
        allocator.free(self.selected_release_version);
        for (self.releases.items) |*release| release.deinit(allocator);
        self.releases.deinit(allocator);
        self.* = undefined;
    }
};

pub const InstalledPackageState = struct {
    package_id: []const u8,
    venom_id: []const u8,
    release_version: []const u8,
};

const OverrideRule = struct {
    package_id: []u8,
    channel_override: ?[]u8 = null,
    release_pin: ?[]u8 = null,

    fn deinit(self: *OverrideRule, allocator: std.mem.Allocator) void {
        allocator.free(self.package_id);
        if (self.channel_override) |value| allocator.free(value);
        if (self.release_pin) |value| allocator.free(value);
        self.* = undefined;
    }
};

const Selection = struct {
    package_json: []u8,
    bundle_id: []u8,
    package_id: []u8,
    manifest_path: []u8,
    release_version: []u8,
    channel: []u8,
    bundle_doc_path: []u8,
    bundle_release_path: []u8,
    bundle_release_sha256: []u8,
    min_spiderweb_version: []u8,

    fn deinit(self: *Selection, allocator: std.mem.Allocator) void {
        allocator.free(self.package_json);
        allocator.free(self.bundle_id);
        allocator.free(self.package_id);
        allocator.free(self.manifest_path);
        allocator.free(self.release_version);
        allocator.free(self.channel);
        allocator.free(self.bundle_doc_path);
        allocator.free(self.bundle_release_path);
        allocator.free(self.bundle_release_sha256);
        allocator.free(self.min_spiderweb_version);
        self.* = undefined;
    }
};

pub fn buildCatalogJson(
    allocator: std.mem.Allocator,
    policy: Policy,
    requested_channel: ?[]const u8,
    filter_package_id: ?[]const u8,
) ![]u8 {
    if (!policy.enabled or std.mem.trim(u8, policy.source_url, " \t\r\n").len == 0) {
        return allocator.dupe(u8, "[]");
    }

    var rules = try parseOverrides(allocator, policy.overrides_json);
    defer deinitOverrides(allocator, &rules);

    const channel = std.mem.trim(u8, requested_channel orelse policy.default_channel, " \t\r\n");
    if (channel.len == 0) return allocator.dupe(u8, "[]");

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;

    var index_doc = try loadRegistryDocument(allocator, policy.source_url, "v1/index.json");
    defer index_doc.deinit();
    if (index_doc.value != .object) return error.InvalidRegistryDocument;
    try validateRegistryIndex(index_doc.value.object);

    const channel_doc_path = try findChannelPath(allocator, index_doc.value.object, channel);
    defer allocator.free(channel_doc_path);
    var channel_doc = try loadRegistryDocument(allocator, policy.source_url, channel_doc_path);
    defer channel_doc.deinit();
    if (channel_doc.value != .object) return error.InvalidRegistryDocument;
    try validateRegistryChannel(channel_doc.value.object, channel);

    const bundles = getRequiredArray(channel_doc.value.object, "bundles") orelse return error.InvalidRegistryDocument;
    for (bundles) |bundle_entry| {
        if (bundle_entry != .object) return error.InvalidRegistryDocument;
        const path = getRequiredString(bundle_entry.object, "path") orelse return error.InvalidRegistryDocument;
        var bundle_doc = try loadRegistryDocument(allocator, policy.source_url, path);
        defer bundle_doc.deinit();
        if (bundle_doc.value != .object) return error.InvalidRegistryDocument;
        try validateRegistryBundleRelease(bundle_doc.value.object);
        const packages = getRequiredArray(bundle_doc.value.object, "packages") orelse return error.InvalidRegistryDocument;
        const bundle_id = getRequiredString(bundle_doc.value.object, "bundle_id") orelse return error.InvalidRegistryDocument;
        const published_at = getOptionalString(bundle_doc.value.object, "published_at");
        const min_spiderweb_version = getOptionalString(bundle_doc.value.object, "min_spiderweb_version");

        for (packages) |package_entry| {
            if (package_entry != .object) return error.InvalidRegistryDocument;
            const package_id = getRequiredString(package_entry.object, "package_id") orelse return error.InvalidRegistryDocument;
            if (filter_package_id) |needle| {
                if (!std.mem.eql(u8, package_id, needle)) continue;
            }
            const package_json = try buildRegistryPackageJson(
                allocator,
                package_entry.object,
                bundle_id,
                published_at,
                min_spiderweb_version,
                false,
                null,
                null,
            );
            defer allocator.free(package_json);
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.appendSlice(allocator, package_json);
        }
    }

    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn buildPolicyJson(
    allocator: std.mem.Allocator,
    policy: Policy,
    requested_package_id: ?[]const u8,
) ![]u8 {
    var overrides = try parseOverrides(allocator, policy.overrides_json);
    defer deinitOverrides(allocator, &overrides);

    const source_url_json = try optionalJsonStringField(allocator, policy.source_url);
    defer allocator.free(source_url_json);
    const default_channel_json = try optionalJsonStringField(allocator, policy.default_channel);
    defer allocator.free(default_channel_json);

    if (requested_package_id) |package_id| {
        const escaped_package_id = try std.json.Stringify.valueAlloc(allocator, package_id, .{});
        defer allocator.free(escaped_package_id);
        const channel_override = findPackageChannel(overrides.items, package_id);
        const release_pin = findPackageReleasePin(overrides.items, package_id);
        const channel_override_json = try optionalJsonStringField(allocator, channel_override);
        defer allocator.free(channel_override_json);
        const release_pin_json = try optionalJsonStringField(allocator, release_pin);
        defer allocator.free(release_pin_json);
        const effective_channel_json = try optionalJsonStringField(allocator, channel_override orelse policy.default_channel);
        defer allocator.free(effective_channel_json);
        return std.fmt.allocPrint(
            allocator,
            "{{\"enabled\":{},\"source_url\":{s},\"default_channel\":{s},\"package_id\":{s},\"channel_override\":{s},\"release_pin\":{s},\"effective_channel\":{s}}}",
            .{
                policy.enabled,
                source_url_json,
                default_channel_json,
                escaped_package_id,
                channel_override_json,
                release_pin_json,
                effective_channel_json,
            },
        );
    }

    var overrides_json = std.ArrayListUnmanaged(u8){};
    defer overrides_json.deinit(allocator);
    try overrides_json.append(allocator, '[');
    for (overrides.items, 0..) |entry, idx| {
        if (idx != 0) try overrides_json.append(allocator, ',');
        const channel_override_json = try optionalJsonStringField(allocator, entry.channel_override);
        defer allocator.free(channel_override_json);
        const release_pin_json = try optionalJsonStringField(allocator, entry.release_pin);
        defer allocator.free(release_pin_json);
        const effective_channel_json = try optionalJsonStringField(allocator, entry.channel_override orelse policy.default_channel);
        defer allocator.free(effective_channel_json);
        try overrides_json.writer(allocator).print(
            "{{\"package_id\":\"{s}\",\"channel_override\":{s},\"release_pin\":{s},\"effective_channel\":{s}}}",
            .{ entry.package_id, channel_override_json, release_pin_json, effective_channel_json },
        );
    }
    try overrides_json.append(allocator, ']');

    return std.fmt.allocPrint(
        allocator,
        "{{\"enabled\":{},\"source_url\":{s},\"default_channel\":{s},\"override_count\":{d},\"overrides\":{s}}}",
        .{ policy.enabled, source_url_json, default_channel_json, overrides.items.len, overrides_json.items },
    );
}

pub fn buildUpdatesJson(
    allocator: std.mem.Allocator,
    policy: Policy,
    installed_packages: []const InstalledPackageState,
) ![]u8 {
    if (!policy.enabled or std.mem.trim(u8, policy.source_url, " \t\r\n").len == 0) {
        return allocator.dupe(u8, "[]");
    }

    var out = std.ArrayListUnmanaged(u8){};
    defer out.deinit(allocator);
    try out.append(allocator, '[');
    var first = true;
    for (installed_packages) |package| {
        if (resolveRegistrySelection(allocator, policy, .{ .package_id = package.package_id }, false) catch null) |selection_value| {
            var selection = selection_value;
            defer selection.deinit(allocator);
            const update_available = compareReleaseVersions(selection.release_version, package.release_version) == .gt;
            const package_json = try buildRegistryPackageJsonFromSelection(
                allocator,
                selection,
                update_available,
                package.release_version,
            );
            defer allocator.free(package_json);
            if (!first) try out.append(allocator, ',');
            first = false;
            try out.appendSlice(allocator, package_json);
        }
    }
    try out.append(allocator, ']');
    return out.toOwnedSlice(allocator);
}

pub fn getRegistryPackageJson(
    allocator: std.mem.Allocator,
    policy: Policy,
    query: ReleaseQuery,
) ![]u8 {
    var selection = try resolveRegistrySelection(allocator, policy, query, false) orelse return error.RegistryPackageNotFound;
    defer selection.deinit(allocator);
    return allocator.dupe(u8, selection.package_json);
}

pub fn enrichProjectedPackageJson(
    allocator: std.mem.Allocator,
    policy: Policy,
    package_json: []const u8,
) ![]u8 {
    var overrides = try parseOverrides(allocator, policy.overrides_json);
    defer deinitOverrides(allocator, &overrides);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, package_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRegistryDocument;

    const package_id = getRequiredString(parsed.value.object, "package_id") orelse return error.InvalidRegistryDocument;
    const channel_override = findPackageChannel(overrides.items, package_id);
    const release_pin = findPackageReleasePin(overrides.items, package_id);
    const effective_channel = channel_override orelse policy.default_channel;
    const installed_release_version = blk: {
        if (getOptionalString(parsed.value.object, "active_release_version")) |value| break :blk value;
        const installed_release_count = parsed.value.object.get("installed_release_count");
        if (installed_release_count) |value| {
            if (value == .integer and value.integer > 0) {
                break :blk getOptionalString(parsed.value.object, "release_version");
            }
        }
        break :blk null;
    };
    const existing_release_source = getOptionalString(parsed.value.object, "release_source");

    if (resolveRegistrySelection(allocator, policy, .{ .package_id = package_id }, false) catch null) |selection_value| {
        var selection = selection_value;
        defer selection.deinit(allocator);
        const update_available = if (installed_release_version) |installed|
            compareReleaseVersions(selection.release_version, installed) == .gt
        else
            false;
        return appendRegistryMetadataToPackageJson(
            allocator,
            package_json,
            selection.channel,
            selection.release_version,
            selection.channel,
            selection.release_version,
            installed_release_version,
            update_available,
            existing_release_source orelse "installed",
            channel_override,
            release_pin,
            effective_channel,
        );
    }

    return appendRegistryMetadataToPackageJson(
        allocator,
        package_json,
        null,
        null,
        null,
        null,
        installed_release_version,
        false,
        existing_release_source orelse "installed",
        channel_override,
        release_pin,
        effective_channel,
    );
}

pub fn resolveInstallBundle(
    allocator: std.mem.Allocator,
    policy: Policy,
    query: ReleaseQuery,
    spiderweb_version: []const u8,
) !InstallBundleResult {
    var selection = try resolveRegistrySelection(allocator, policy, query, true) orelse return error.RegistryPackageNotFound;
    defer selection.deinit(allocator);

    if (selection.min_spiderweb_version.len > 0 and
        compareReleaseVersions(spiderweb_version, selection.min_spiderweb_version) == .lt)
    {
        return error.RegistryReleaseIncompatible;
    }

    const temp_root = try makeTempDirPath(allocator, "spiderweb-registry-install");
    defer allocator.free(temp_root);
    try ensureDir(temp_root);
    defer std.fs.cwd().deleteTree(temp_root) catch {};

    const archive_path = try std.fs.path.join(allocator, &.{ temp_root, "bundle.tar.gz" });
    defer allocator.free(archive_path);
    try fetchArtifactToPath(allocator, policy.source_url, selection.bundle_release_path, archive_path);
    try verifyFileSha256(allocator, archive_path, selection.bundle_release_sha256);

    const extract_root = try std.fs.path.join(allocator, &.{ temp_root, "extract" });
    defer allocator.free(extract_root);
    try ensureDir(extract_root);
    try extractTarGz(allocator, archive_path, extract_root);

    const extracted_release_path = try findExtractedManifestPath(
        allocator,
        extract_root,
        selection.manifest_path,
    ) orelse return error.InvalidBundleRelease;
    defer allocator.free(extracted_release_path);
    const bundle_root = std.fs.path.dirname(extracted_release_path) orelse return error.InvalidBundleRelease;

    const release_text = try readFileAlloc(allocator, extracted_release_path, 1024 * 1024);
    defer allocator.free(release_text);
    var release_doc = try std.json.parseFromSlice(std.json.Value, allocator, release_text, .{});
    defer release_doc.deinit();
    if (release_doc.value != .object) return error.InvalidBundleRelease;
    try managed_bundle_signatures.verifySignedValue(allocator, release_doc.value);

    const packages = getRequiredArray(release_doc.value.object, "packages") orelse return error.InvalidBundleRelease;

    var result = InstallBundleResult{
        .bundle_id = try allocator.dupe(u8, selection.bundle_id),
        .selected_package_id = try allocator.dupe(u8, selection.package_id),
        .selected_release_version = try allocator.dupe(u8, selection.release_version),
    };
    errdefer result.deinit(allocator);

    for (packages) |package_entry| {
        if (package_entry != .object) return error.InvalidBundleRelease;
        try managed_bundle_signatures.verifySignedValue(allocator, package_entry);
        const manifest_rel_path = getRequiredString(package_entry.object, "manifest_path") orelse return error.InvalidBundleRelease;
        const manifest_path = try std.fs.path.join(allocator, &.{ bundle_root, manifest_rel_path });
        defer allocator.free(manifest_path);
        const manifest_text = try readFileAlloc(allocator, manifest_path, 512 * 1024);
        defer allocator.free(manifest_text);
        var manifest_doc = try std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{});
        defer manifest_doc.deinit();
        if (manifest_doc.value != .object) return error.InvalidBundleRelease;
        try managed_bundle_signatures.verifySignedValue(allocator, manifest_doc.value);
        try validateBundleManifestMatchesRelease(package_entry.object, manifest_doc.value.object);

        const package_id = getRequiredString(package_entry.object, "package_id") orelse return error.InvalidBundleRelease;
        const release_json = try buildInstallReleaseJson(
            allocator,
            package_entry.object,
            manifest_doc.value.object,
        );
        errdefer allocator.free(release_json);
        try result.releases.append(allocator, .{
            .package_id = try allocator.dupe(u8, package_id),
            .release_json = release_json,
        });
    }

    return result;
}

fn parseOverrides(
    allocator: std.mem.Allocator,
    overrides_json: []const u8,
) !std.ArrayListUnmanaged(OverrideRule) {
    var overrides = std.ArrayListUnmanaged(OverrideRule){};
    errdefer deinitOverrides(allocator, &overrides);
    if (std.mem.trim(u8, overrides_json, " \t\r\n").len == 0) return overrides;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, overrides_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidRegistryDocument;
    for (parsed.value.array.items) |item| {
        if (item != .object) return error.InvalidRegistryDocument;
        const package_id = getRequiredString(item.object, "package_id") orelse return error.InvalidRegistryDocument;
        try overrides.append(allocator, .{
            .package_id = try allocator.dupe(u8, package_id),
            .channel_override = if (getOptionalString(item.object, "channel_override")) |value| try allocator.dupe(u8, value) else null,
            .release_pin = if (getOptionalString(item.object, "release_pin")) |value| try allocator.dupe(u8, value) else null,
        });
    }
    return overrides;
}

fn deinitOverrides(allocator: std.mem.Allocator, overrides: *std.ArrayListUnmanaged(OverrideRule)) void {
    for (overrides.items) |*override| override.deinit(allocator);
    overrides.deinit(allocator);
    overrides.* = .{};
}

fn resolveRegistrySelection(
    allocator: std.mem.Allocator,
    policy: Policy,
    query: ReleaseQuery,
    for_install: bool,
) !?Selection {
    if (!policy.enabled or std.mem.trim(u8, policy.source_url, " \t\r\n").len == 0) return null;

    var overrides = try parseOverrides(allocator, policy.overrides_json);
    defer deinitOverrides(allocator, &overrides);

    var index_doc = try loadRegistryDocument(allocator, policy.source_url, "v1/index.json");
    defer index_doc.deinit();
    if (index_doc.value != .object) return error.InvalidRegistryDocument;
    try validateRegistryIndex(index_doc.value.object);

    const bundle_id = try findBundleIdForPackage(allocator, index_doc.value.object, query.package_id) orelse return null;
    defer allocator.free(bundle_id);

    const release_pin = if (query.release_version) |value| value else findPackageReleasePin(overrides.items, query.package_id);
    const channel = if (query.channel) |value| value else findPackageChannel(overrides.items, query.package_id) orelse policy.default_channel;

    const bundle_doc_path = if (release_pin) |pinned|
        try std.fmt.allocPrint(allocator, "v1/bundles/{s}/{s}.json", .{ bundle_id, pinned })
    else
        try resolveBundleDocPathForChannel(allocator, policy.source_url, channel, bundle_id);
    errdefer allocator.free(bundle_doc_path);

    var bundle_doc = try loadRegistryDocument(allocator, policy.source_url, bundle_doc_path);
    defer bundle_doc.deinit();
    if (bundle_doc.value != .object) return error.InvalidRegistryDocument;
    try validateRegistryBundleRelease(bundle_doc.value.object);

    const packages = getRequiredArray(bundle_doc.value.object, "packages") orelse return error.InvalidRegistryDocument;
    const bundle_release_version = getRequiredString(bundle_doc.value.object, "release_version") orelse return error.InvalidRegistryDocument;
    const bundle_channel = getRequiredString(bundle_doc.value.object, "channel") orelse return error.InvalidRegistryDocument;
    const manifest_path = getRequiredString(bundle_doc.value.object, "manifest") orelse return error.InvalidRegistryDocument;
    const published_at = getOptionalString(bundle_doc.value.object, "published_at");
    const min_spiderweb_version = getOptionalString(bundle_doc.value.object, "min_spiderweb_version") orelse "";

    for (packages) |package_entry| {
        if (package_entry != .object) return error.InvalidRegistryDocument;
        const package_id = getRequiredString(package_entry.object, "package_id") orelse return error.InvalidRegistryDocument;
        if (!std.mem.eql(u8, package_id, query.package_id)) continue;
        const package_json = try buildRegistryPackageJson(
            allocator,
            package_entry.object,
            bundle_id,
            published_at,
            min_spiderweb_version,
            false,
            null,
            null,
        );
        errdefer allocator.free(package_json);
        const artifact = if (for_install)
            try selectArtifactForCurrentPlatform(bundle_doc.value.object)
        else
            null;
        return Selection{
            .package_json = package_json,
            .bundle_id = try allocator.dupe(u8, bundle_id),
            .package_id = try allocator.dupe(u8, package_id),
            .manifest_path = try allocator.dupe(u8, manifest_path),
            .release_version = try allocator.dupe(u8, bundle_release_version),
            .channel = try allocator.dupe(u8, bundle_channel),
            .bundle_doc_path = bundle_doc_path,
            .bundle_release_path = if (artifact) |value| try allocator.dupe(u8, value.url) else try allocator.dupe(u8, ""),
            .bundle_release_sha256 = if (artifact) |value| try allocator.dupe(u8, value.sha256) else try allocator.dupe(u8, ""),
            .min_spiderweb_version = try allocator.dupe(u8, min_spiderweb_version),
        };
    }
    allocator.free(bundle_doc_path);
    return null;
}

const ArtifactSelection = struct {
    url: []const u8,
    sha256: []const u8,
};

fn selectArtifactForCurrentPlatform(bundle_doc: std.json.ObjectMap) !?ArtifactSelection {
    const artifacts = getRequiredArray(bundle_doc, "artifacts") orelse return error.InvalidRegistryDocument;
    const current_os = currentOsLabel();
    const current_arch = currentArchLabel();
    for (artifacts) |artifact| {
        if (artifact != .object) return error.InvalidRegistryDocument;
        const os_value = getRequiredString(artifact.object, "os") orelse return error.InvalidRegistryDocument;
        const arch_value = getRequiredString(artifact.object, "arch") orelse return error.InvalidRegistryDocument;
        if (!std.mem.eql(u8, os_value, current_os)) continue;
        if (!std.mem.eql(u8, arch_value, current_arch)) continue;
        const url = getRequiredString(artifact.object, "url") orelse return error.InvalidRegistryDocument;
        const sha256 = getRequiredString(artifact.object, "sha256") orelse return error.InvalidRegistryDocument;
        return .{ .url = url, .sha256 = sha256 };
    }
    return null;
}

fn buildRegistryPackageJson(
    allocator: std.mem.Allocator,
    package_obj: std.json.ObjectMap,
    bundle_id: []const u8,
    published_at: ?[]const u8,
    min_spiderweb_version: ?[]const u8,
    update_available: bool,
    installed_release_version: ?[]const u8,
    release_source: ?[]const u8,
) ![]u8 {
    const package_id = getRequiredString(package_obj, "package_id") orelse return error.InvalidRegistryDocument;
    const venom_id = getRequiredString(package_obj, "venom_id") orelse return error.InvalidRegistryDocument;
    const kind = getRequiredString(package_obj, "kind") orelse return error.InvalidRegistryDocument;
    const release_version = getRequiredString(package_obj, "release_version") orelse return error.InvalidRegistryDocument;
    const channel = getRequiredString(package_obj, "channel") orelse return error.InvalidRegistryDocument;
    const digest_json = try optionalJsonStringField(allocator, getOptionalString(package_obj, "digest"));
    defer allocator.free(digest_json);
    const signature_json = try optionalJsonValueField(allocator, package_obj.get("signature"));
    defer allocator.free(signature_json);
    const trust_json = try optionalJsonValueField(allocator, package_obj.get("trust"));
    defer allocator.free(trust_json);
    const published_json = try optionalJsonStringField(allocator, published_at);
    defer allocator.free(published_json);
    const min_version_json = try optionalJsonStringField(allocator, min_spiderweb_version);
    defer allocator.free(min_version_json);
    const installed_json = try optionalJsonStringField(allocator, installed_release_version);
    defer allocator.free(installed_json);
    const release_source_json = try optionalJsonStringField(allocator, release_source orelse "registry");
    defer allocator.free(release_source_json);

    return std.fmt.allocPrint(
        allocator,
        "{{\"package_id\":\"{s}\",\"venom_id\":\"{s}\",\"kind\":\"{s}\",\"release_version\":\"{s}\",\"channel\":\"{s}\",\"digest\":{s},\"signature\":{s},\"trust\":{s},\"bundle_id\":\"{s}\",\"published_at\":{s},\"min_spiderweb_version\":{s},\"registry_channel\":\"{s}\",\"registry_release_version\":\"{s}\",\"latest_release_version\":\"{s}\",\"latest_release_channel\":\"{s}\",\"installed_release_version\":{s},\"update_available\":{},\"release_source\":{s}}}",
        .{
            package_id,
            venom_id,
            kind,
            release_version,
            channel,
            digest_json,
            signature_json,
            trust_json,
            bundle_id,
            published_json,
            min_version_json,
            channel,
            release_version,
            release_version,
            channel,
            installed_json,
            update_available,
            release_source_json,
        },
    );
}

fn buildRegistryPackageJsonFromSelection(
    allocator: std.mem.Allocator,
    selection: Selection,
    update_available: bool,
    installed_release_version: ?[]const u8,
) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, selection.package_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRegistryDocument;
    const bundle_id = getRequiredString(parsed.value.object, "bundle_id") orelse return error.InvalidRegistryDocument;
    return buildRegistryPackageJson(
        allocator,
        parsed.value.object,
        bundle_id,
        getOptionalString(parsed.value.object, "published_at"),
        getOptionalString(parsed.value.object, "min_spiderweb_version"),
        update_available,
        installed_release_version,
        "registry",
    );
}

fn buildInstallReleaseJson(
    allocator: std.mem.Allocator,
    release_entry: std.json.ObjectMap,
    manifest: std.json.ObjectMap,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"release\":{{\"package_id\":\"{s}\",\"release_version\":\"{s}\",\"channel\":\"{s}\",\"digest\":\"{s}\",\"signature\":{f},\"trust\":{f},\"package\":{f}}}}}",
        .{
            getRequiredString(release_entry, "package_id") orelse return error.InvalidBundleRelease,
            getRequiredString(release_entry, "release_version") orelse return error.InvalidBundleRelease,
            getRequiredString(release_entry, "channel") orelse return error.InvalidBundleRelease,
            getRequiredString(release_entry, "digest") orelse return error.InvalidBundleRelease,
            std.json.fmt(release_entry.get("signature") orelse return error.InvalidBundleRelease, .{}),
            std.json.fmt(release_entry.get("trust") orelse return error.InvalidBundleRelease, .{}),
            std.json.fmt(std.json.Value{ .object = manifest }, .{}),
        },
    );
}

fn validateBundleManifestMatchesRelease(release_entry: std.json.ObjectMap, manifest: std.json.ObjectMap) !void {
    try requireMatchingBundleString("package_id", release_entry, manifest);
    try requireMatchingBundleString("release_version", release_entry, manifest);
    try requireMatchingBundleString("venom_id", release_entry, manifest);
    try requireMatchingBundleString("kind", release_entry, manifest);
    try requireMatchingBundleString("channel", release_entry, manifest);
}

fn requireMatchingBundleString(field_name: []const u8, release_entry: std.json.ObjectMap, manifest: std.json.ObjectMap) !void {
    const expected = getRequiredString(release_entry, field_name) orelse return error.InvalidBundleRelease;
    const actual = getRequiredString(manifest, field_name) orelse return error.InvalidBundleRelease;
    if (!std.mem.eql(u8, expected, actual)) return error.InvalidBundleRelease;
}

fn findBundleIdForPackage(
    allocator: std.mem.Allocator,
    index_doc: std.json.ObjectMap,
    package_id: []const u8,
) !?[]u8 {
    const bundles = getRequiredArray(index_doc, "bundles") orelse return error.InvalidRegistryDocument;
    for (bundles) |bundle_entry| {
        if (bundle_entry != .object) return error.InvalidRegistryDocument;
        const ids = getRequiredArray(bundle_entry.object, "package_ids") orelse return error.InvalidRegistryDocument;
        for (ids) |id_entry| {
            if (id_entry != .string) return error.InvalidRegistryDocument;
            if (std.mem.eql(u8, id_entry.string, package_id)) {
                return try allocator.dupe(u8, getRequiredString(bundle_entry.object, "bundle_id") orelse return error.InvalidRegistryDocument);
            }
        }
    }
    return null;
}

fn findChannelPath(
    allocator: std.mem.Allocator,
    index_doc: std.json.ObjectMap,
    channel: []const u8,
) ![]u8 {
    const channels = getRequiredArray(index_doc, "channels") orelse return error.InvalidRegistryDocument;
    for (channels) |entry| {
        if (entry != .object) return error.InvalidRegistryDocument;
        const id = getRequiredString(entry.object, "id") orelse return error.InvalidRegistryDocument;
        if (!std.mem.eql(u8, id, channel)) continue;
        return allocator.dupe(u8, getRequiredString(entry.object, "path") orelse return error.InvalidRegistryDocument);
    }
    return error.RegistryChannelNotFound;
}

fn resolveBundleDocPathForChannel(
    allocator: std.mem.Allocator,
    source_url: []const u8,
    channel: []const u8,
    bundle_id: []const u8,
) ![]u8 {
    const channel_path = try std.fmt.allocPrint(allocator, "v1/channels/{s}.json", .{channel});
    defer allocator.free(channel_path);
    var channel_doc = try loadRegistryDocument(allocator, source_url, channel_path);
    defer channel_doc.deinit();
    if (channel_doc.value != .object) return error.InvalidRegistryDocument;
    try validateRegistryChannel(channel_doc.value.object, channel);
    const bundles = getRequiredArray(channel_doc.value.object, "bundles") orelse return error.InvalidRegistryDocument;
    for (bundles) |entry| {
        if (entry != .object) return error.InvalidRegistryDocument;
        const id = getRequiredString(entry.object, "bundle_id") orelse return error.InvalidRegistryDocument;
        if (!std.mem.eql(u8, id, bundle_id)) continue;
        return allocator.dupe(u8, getRequiredString(entry.object, "path") orelse return error.InvalidRegistryDocument);
    }
    return error.RegistryPackageNotFound;
}

fn findPackageChannel(overrides: []const OverrideRule, package_id: []const u8) ?[]const u8 {
    for (overrides) |rule| {
        if (!std.mem.eql(u8, rule.package_id, package_id)) continue;
        return rule.channel_override;
    }
    return null;
}

fn findPackageReleasePin(overrides: []const OverrideRule, package_id: []const u8) ?[]const u8 {
    for (overrides) |rule| {
        if (!std.mem.eql(u8, rule.package_id, package_id)) continue;
        return rule.release_pin;
    }
    return null;
}

fn currentOsLabel() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "windows",
        else => @tagName(builtin.os.tag),
    };
}

fn currentArchLabel() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn makeTempDirPath(allocator: std.mem.Allocator, prefix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}-{d}", .{ prefix, std.time.nanoTimestamp() });
}

fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn extractTarGz(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xzf", archive_path, "-C", dest_dir },
        .max_output_bytes = 256 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code == 0) return,
        else => {},
    }
    return error.RegistryArtifactExtractionFailed;
}

fn fetchArtifactToPath(
    allocator: std.mem.Allocator,
    source_url: []const u8,
    artifact_path: []const u8,
    output_path: []const u8,
) !void {
    const resolved = try resolveAssetReference(allocator, source_url, artifact_path);
    defer allocator.free(resolved);
    if (isHttpUrl(resolved)) {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "curl", "-fsSL", "-o", output_path, resolved },
            .max_output_bytes = 128 * 1024,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code == 0) return,
            else => {},
        }
        return error.RegistryFetchFailed;
    }

    const bytes = try readFileAlloc(allocator, resolved, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    try writeFileReplacing(output_path, bytes);
}

fn verifyFileSha256(allocator: std.mem.Allocator, path: []const u8, expected_hex: []const u8) !void {
    const bytes = try readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(digest, .lower)});
    defer allocator.free(actual);
    if (!std.mem.eql(u8, actual, expected_hex)) return error.RegistryArtifactChecksumMismatch;
}

fn findPathEndingWith(allocator: std.mem.Allocator, root: []const u8, suffix: []const u8) !?[]u8 {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const full = try std.fs.path.join(allocator, &.{ root, entry.path });
        errdefer allocator.free(full);
        if (std.mem.endsWith(u8, full, suffix)) return full;
        allocator.free(full);
    }
    return null;
}

fn findExtractedManifestPath(
    allocator: std.mem.Allocator,
    extract_root: []const u8,
    manifest_path: []const u8,
) !?[]u8 {
    const trimmed_manifest_path = std.mem.trim(u8, manifest_path, " \t\r\n");
    if (trimmed_manifest_path.len == 0) return error.InvalidBundleRelease;
    return findPathEndingWith(allocator, extract_root, trimmed_manifest_path);
}

fn resolveAssetReference(allocator: std.mem.Allocator, source_url: []const u8, asset_path: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, asset_path, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidRegistryDocument;
    if (isHttpUrl(trimmed)) return allocator.dupe(u8, trimmed);
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    const base = std.mem.trim(u8, source_url, " \t\r\n");
    if (base.len == 0) return allocator.dupe(u8, trimmed);
    if (isHttpUrl(base)) {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimRight(u8, base, "/"), trimmed });
    }
    return std.fs.path.join(allocator, &.{ base, trimmed });
}

fn isHttpUrl(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://");
}

fn loadRegistryDocument(
    allocator: std.mem.Allocator,
    source_url: []const u8,
    relative_path: []const u8,
) !std.json.Parsed(std.json.Value) {
    const resolved = try resolveAssetReference(allocator, source_url, relative_path);
    defer allocator.free(resolved);
    const text = if (isHttpUrl(resolved))
        try fetchRemoteText(allocator, resolved)
    else
        try readFileAlloc(allocator, resolved, 4 * 1024 * 1024);
    errdefer allocator.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    allocator.free(text);
    try registry_signatures.verifySignedValue(allocator, parsed.value);
    return parsed;
}

fn fetchRemoteText(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-fsSL", url },
        .max_output_bytes = 4 * 1024 * 1024,
    });
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    return error.RegistryFetchFailed;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = if (std.fs.path.isAbsolute(path))
        try std.fs.openFileAbsolute(path, .{ .mode = .read_only })
    else
        try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn writeFileReplacing(path: []const u8, data: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPath;
    const base = std.fs.path.basename(path);
    try ensureDir(parent);
    var dir = if (std.fs.path.isAbsolute(parent))
        try std.fs.openDirAbsolute(parent, .{})
    else
        try std.fs.cwd().openDir(parent, .{});
    defer dir.close();
    var file = try dir.createFile(base, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
}

fn optionalJsonStringField(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    if (value) |raw| {
        const escaped = try std.json.Stringify.valueAlloc(allocator, raw, .{});
        defer allocator.free(escaped);
        return allocator.dupe(u8, escaped);
    }
    return allocator.dupe(u8, "null");
}

fn optionalJsonValueField(allocator: std.mem.Allocator, value: ?std.json.Value) ![]u8 {
    if (value) |raw| {
        return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(raw, .{})});
    }
    return allocator.dupe(u8, "null");
}

fn getRequiredArray(obj: std.json.ObjectMap, field_name: []const u8) ?[]const std.json.Value {
    const value = obj.get(field_name) orelse return null;
    if (value != .array) return null;
    return value.array.items;
}

fn getRequiredString(obj: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = obj.get(field_name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn getOptionalString(obj: std.json.ObjectMap, field_name: []const u8) ?[]const u8 {
    const value = obj.get(field_name) orelse return null;
    if (value != .string or value.string.len == 0) return null;
    return value.string;
}

fn compareReleaseVersions(a: []const u8, b: []const u8) std.math.Order {
    const parsed_a = std.SemanticVersion.parse(a) catch return std.mem.order(u8, a, b);
    const parsed_b = std.SemanticVersion.parse(b) catch return std.mem.order(u8, a, b);
    return parsed_a.order(parsed_b);
}

fn appendRegistryMetadataToPackageJson(
    allocator: std.mem.Allocator,
    package_json: []const u8,
    registry_channel: ?[]const u8,
    registry_release_version: ?[]const u8,
    latest_release_channel: ?[]const u8,
    latest_release_version: ?[]const u8,
    installed_release_version: ?[]const u8,
    update_available: bool,
    release_source: []const u8,
    channel_override: ?[]const u8,
    release_pin: ?[]const u8,
    effective_channel: ?[]const u8,
) ![]u8 {
    if (package_json.len == 0 or package_json[package_json.len - 1] != '}') return error.InvalidRegistryDocument;

    const registry_channel_json = try optionalJsonStringField(allocator, registry_channel);
    defer allocator.free(registry_channel_json);
    const registry_release_json = try optionalJsonStringField(allocator, registry_release_version);
    defer allocator.free(registry_release_json);
    const latest_channel_json = try optionalJsonStringField(allocator, latest_release_channel);
    defer allocator.free(latest_channel_json);
    const latest_release_json = try optionalJsonStringField(allocator, latest_release_version);
    defer allocator.free(latest_release_json);
    const installed_release_json = try optionalJsonStringField(allocator, installed_release_version);
    defer allocator.free(installed_release_json);
    const release_source_json = try optionalJsonStringField(allocator, release_source);
    defer allocator.free(release_source_json);
    const channel_override_json = try optionalJsonStringField(allocator, channel_override);
    defer allocator.free(channel_override_json);
    const release_pin_json = try optionalJsonStringField(allocator, release_pin);
    defer allocator.free(release_pin_json);
    const effective_channel_json = try optionalJsonStringField(allocator, effective_channel);
    defer allocator.free(effective_channel_json);

    return std.fmt.allocPrint(
        allocator,
        "{s},\"registry_channel\":{s},\"registry_release_version\":{s},\"latest_release_version\":{s},\"latest_release_channel\":{s},\"installed_release_version\":{s},\"update_available\":{},\"release_source\":{s},\"channel_override\":{s},\"release_pin\":{s},\"effective_channel\":{s}}}",
        .{
            package_json[0 .. package_json.len - 1],
            registry_channel_json,
            registry_release_json,
            latest_release_json,
            latest_channel_json,
            installed_release_json,
            update_available,
            release_source_json,
            channel_override_json,
            release_pin_json,
            effective_channel_json,
        },
    );
}

fn validateRegistryIndex(obj: std.json.ObjectMap) !void {
    const schema = getRequiredString(obj, "schema_version") orelse return error.InvalidRegistryDocument;
    if (!std.mem.eql(u8, schema, registry_schema_version)) return error.UnsupportedRegistrySchemaVersion;
}

fn validateRegistryChannel(obj: std.json.ObjectMap, requested_channel: []const u8) !void {
    const channel = getRequiredString(obj, "channel") orelse return error.InvalidRegistryDocument;
    if (!std.mem.eql(u8, channel, requested_channel)) return error.InvalidRegistryDocument;
}

fn validateRegistryBundleRelease(obj: std.json.ObjectMap) !void {
    const artifact_version = getRequiredString(obj, "artifact_version") orelse return error.InvalidRegistryDocument;
    if (!std.mem.eql(u8, artifact_version, supported_bundle_artifact_version)) {
        return error.UnsupportedRegistrySchemaVersion;
    }
}

test "validateRegistryIndex rejects unsupported schema versions" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"schema_version":"spidervenom-registry-v2","publisher":"SpiderVenomRegistry","generated_at":"2026-03-26T18:00:00Z","keys":[],"channels":[],"bundles":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.UnsupportedRegistrySchemaVersion, validateRegistryIndex(parsed.value.object));
}

test "validateRegistryChannel rejects mismatched channel metadata" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"channel":"beta","generated_at":"2026-03-26T18:00:00Z","bundles":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidRegistryDocument, validateRegistryChannel(parsed.value.object, "stable"));
}

test "validateRegistryBundleRelease rejects unsupported artifact versions" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"bundle_id":"managed-local","release_version":"0.5.8","channel":"stable","artifact_version":"2","packages":[],"artifacts":[]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    try std.testing.expectError(error.UnsupportedRegistrySchemaVersion, validateRegistryBundleRelease(parsed.value.object));
}

test "findExtractedManifestPath uses the registry manifest path" {
    const allocator = std.testing.allocator;
    const temp_root = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/venom-registry-manifest-{d}", .{std.time.nanoTimestamp()});
    defer allocator.free(temp_root);
    defer std.fs.cwd().deleteTree(temp_root) catch {};

    const manifest_path = try std.fs.path.join(allocator, &.{ temp_root, "share/spidervenoms/bundles/browser-bundle/release.json" });
    defer allocator.free(manifest_path);
    try ensureDir(std.fs.path.dirname(manifest_path).?);
    try writeFileReplacing(manifest_path, "{}");

    const resolved = (try findExtractedManifestPath(
        allocator,
        temp_root,
        "share/spidervenoms/bundles/browser-bundle/release.json",
    )).?;
    defer allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "share/spidervenoms/bundles/browser-bundle/release.json"));
}

test "buildPolicyJson escapes requested package ids" {
    const allocator = std.testing.allocator;
    const json = try buildPolicyJson(
        allocator,
        .{
            .enabled = true,
            .source_url = "https://registry.example.test",
            .default_channel = "stable",
            .overrides_json = "[]",
        },
        "browser\\\"beta",
    );
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"package_id\":\"browser\\\\\\\"beta\"") != null);
}
