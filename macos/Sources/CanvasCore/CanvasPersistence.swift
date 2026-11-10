import CryptoKit
import Darwin
import Foundation


extension URL {
    public var canonicalFileURL: URL {
        resolvingSymlinksInPath().standardizedFileURL
    }

    public func refersToSameFile(as other: URL) -> Bool {
        if canonicalFileURL == other.canonicalFileURL {
            return true
        }
        let fm = FileManager.default
        if let attrsA = try? fm.attributesOfItem(atPath: path),
           let attrsB = try? fm.attributesOfItem(atPath: other.path),
           let inoA = (attrsA[.systemFileNumber] as? NSNumber)?.uint64Value,
           let inoB = (attrsB[.systemFileNumber] as? NSNumber)?.uint64Value,
           let devA = (attrsA[.systemNumber] as? NSNumber)?.uint64Value,
           let devB = (attrsB[.systemNumber] as? NSNumber)?.uint64Value {
            return devA == devB && inoA == inoB
        }
        return false
    }
}
/// Byte-level SHA-256 and size fingerprint of an acknowledged canvas JSON file on disk.
public struct CanvasFileFingerprint: Equatable, Codable, Sendable {
    public let sha256Hex: String
    public let byteCount: Int
    public let posixPermissions: Int?

    public init(data: Data, posixPermissions: Int? = nil) {
        let digest = SHA256.hash(data: data)
        self.sha256Hex = digest.map { String(format: "%02x", $0) }.joined()
        self.byteCount = data.count
        self.posixPermissions = posixPermissions
    }

    public func matchesBytes(of other: CanvasFileFingerprint) -> Bool {
        sha256Hex == other.sha256Hex && byteCount == other.byteCount
    }

    /// Reads an existing regular file and computes its byte fingerprint and writability.
    public static func inspectRegularFile(
        at url: URL
    ) throws -> (data: Data, fingerprint: CanvasFileFingerprint, isWritable: Bool) {
        let fm = FileManager.default
        let path = url.path
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try fm.attributesOfItem(atPath: path)
        } catch {
            throw CanvasPersistenceError.externalConflict(.missingOrReplaced)
        }
        guard (attrs[.type] as? FileAttributeType) == .typeRegular else {
            throw CanvasPersistenceError.externalConflict(.notRegularFile)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CanvasPersistenceError.externalConflict(.missingOrReplaced)
        }
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
        let parentPath = url.deletingLastPathComponent().path
        let isWritable = fm.isWritableFile(atPath: path) && fm.isWritableFile(atPath: parentPath)
        return (data, CanvasFileFingerprint(data: data, posixPermissions: permissions), isWritable)
    }
}

public enum CanvasConflictReason: Equatable, Sendable {
    case modifiedExternally(currentFingerprint: CanvasFileFingerprint)
    case missingOrReplaced
    case notRegularFile

    public var message: String {
        switch self {
        case .modifiedExternally:
            return "The file on disk was modified by another program. Autosave is paused to protect both versions."
        case .missingOrReplaced:
            return "The file on disk was moved or deleted. Autosave is paused; use Save As to keep your work."
        case .notRegularFile:
            return "The destination on disk is no longer a regular JSON file. Autosave is paused."
        }
    }
}

public enum CanvasPersistenceError: LocalizedError, Equatable, Sendable {
    case externalConflict(CanvasConflictReason)
    case readOnlySource(String)
    case invalidDraft(String)
    case corruptRecovery(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .externalConflict(let reason):
            return reason.message
        case .readOnlySource(let msg),
             .invalidDraft(let msg),
             .corruptRecovery(let msg),
             .writeFailed(let msg):
            return msg
        }
    }
}

/// User-visible document persistence states (`macos/SPEC.md §4`).
public enum CanvasPersistenceState: Equatable, Sendable {
    case untitled(isDirty: Bool, hasPendingDraft: Bool)
    case saved(hasPendingDraft: Bool)
    case changesPending(hasPendingDraft: Bool)
    case saving(hasPendingDraft: Bool)
    case saveFailed(message: String, hasPendingDraft: Bool)
    case conflict(reason: CanvasConflictReason, hasPendingDraft: Bool)
    case readOnly(reason: String, hasPendingDraft: Bool)

    public var hasPendingDraft: Bool {
        switch self {
        case .untitled(_, let draft),
             .saved(let draft),
             .changesPending(let draft),
             .saving(let draft),
             .saveFailed(_, let draft),
             .conflict(_, let draft),
             .readOnly(_, let draft):
            return draft
        }
    }

    public var statusSummary: String {
        switch self {
        case .untitled(let isDirty, let draft):
            if draft { return "Untitled — Pending draft" }
            return isDirty ? "Untitled — Edited" : "Untitled — Not saved"
        case .saved(let draft):
            return draft ? "Saved · Pending draft" : "Saved"
        case .changesPending(let draft):
            return draft ? "Changes pending · Pending draft" : "Changes pending"
        case .saving(let draft):
            return draft ? "Saving… · Pending draft" : "Saving…"
        case .saveFailed(let message, _):
            return "Save failed — \(message)"
        case .conflict(_, _):
            return "External change — Autosave paused"
        case .readOnly(_, let draft):
            return draft ? "Read-only · Pending draft" : "Read-only"
        }
    }

    public var isAutosavePaused: Bool {
        switch self {
        case .conflict, .readOnly:
            return true
        default:
            return false
        }
    }

    public var hasUnresolvedWork: Bool {
        switch self {
        case .untitled(let isDirty, let draft):
            return isDirty || draft
        case .saved(let draft):
            return draft
        case .changesPending, .saving, .saveFailed, .conflict:
            return true
        case .readOnly(_, let draft):
            return draft
        }
    }
}

/// Acknowledged active inline text draft (never incomplete marked IME composition).
public struct CanvasRecoverableTextDraft: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case adjacentEditing
        case newText
        case shapeCaption
    }

    public let kind: Kind
    public let targetID: String?
    public let directionRawValue: String?
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let rotation: Double?
    public let beforeText: String?
    public let beforeX: Double?
    public let beforeY: Double?
    public let beforeWidth: Double?
    public let beforeHeight: Double?
    public let beforeRotation: Double?
    public let text: String

    public var geometry: CanvasGeometry {
        CanvasGeometry(x: x, y: y, width: width, height: height, rotation: rotation)
    }

    public var beforeGeometry: CanvasGeometry? {
        guard let bx = beforeX, let by = beforeY, let bw = beforeWidth, let bh = beforeHeight else {
            return nil
        }
        return CanvasGeometry(x: bx, y: by, width: bw, height: bh, rotation: beforeRotation)
    }

    public static func adjacentEditing(
        sourceID: String,
        direction: CanvasThoughtDirection,
        geometry: CanvasGeometry,
        text: String
    ) -> CanvasRecoverableTextDraft {
        CanvasRecoverableTextDraft(
            kind: .adjacentEditing,
            targetID: sourceID,
            directionRawValue: direction.rawValue,
            x: geometry.x,
            y: geometry.y,
            width: geometry.width,
            height: geometry.height,
            rotation: geometry.rotation,
            beforeText: nil,
            beforeX: nil,
            beforeY: nil,
            beforeWidth: nil,
            beforeHeight: nil,
            beforeRotation: nil,
            text: text
        )
    }

    public static func newText(
        position: CanvasPosition,
        geometry: CanvasGeometry,
        text: String
    ) -> CanvasRecoverableTextDraft {
        CanvasRecoverableTextDraft(
            kind: .newText,
            targetID: nil,
            directionRawValue: nil,
            x: position.x,
            y: position.y,
            width: geometry.width,
            height: geometry.height,
            rotation: geometry.rotation,
            beforeText: nil,
            beforeX: nil,
            beforeY: nil,
            beforeWidth: nil,
            beforeHeight: nil,
            beforeRotation: nil,
            text: text
        )
    }

    public static func shapeCaption(
        id: String,
        beforeText: String?,
        beforeGeometry: CanvasGeometry,
        previewGeometry: CanvasGeometry,
        text: String
    ) -> CanvasRecoverableTextDraft {
        CanvasRecoverableTextDraft(
            kind: .shapeCaption,
            targetID: id,
            directionRawValue: nil,
            x: previewGeometry.x,
            y: previewGeometry.y,
            width: previewGeometry.width,
            height: previewGeometry.height,
            rotation: previewGeometry.rotation,
            beforeText: beforeText,
            beforeX: beforeGeometry.x,
            beforeY: beforeGeometry.y,
            beforeWidth: beforeGeometry.width,
            beforeHeight: beforeGeometry.height,
            beforeRotation: beforeGeometry.rotation,
            text: text
        )
    }
}

/// Private app-owned recovery envelope storing only state uncovered by `NSDocument` draft autosaving:
/// source association, base byte fingerprint, `NSDocument.autosavedContentsFileURL` reference, and
/// any acknowledged active inline text draft (`macos/SPEC.md §4`).
public struct CanvasRecoveryEnvelope: Equatable, Codable, Sendable {
    public let sessionID: UUID
    public let updatedAt: Date
    public let displayName: String
    public let sourcePath: String?
    public let baseFingerprint: CanvasFileFingerprint?
    public let autosavedDraftPath: String?
    public let committedRevision: UInt64
    public let acknowledgedRevision: UInt64
    public let pendingTextDraft: CanvasRecoverableTextDraft?

    public init(
        sessionID: UUID,
        updatedAt: Date = Date(),
        displayName: String,
        sourcePath: String?,
        baseFingerprint: CanvasFileFingerprint?,
        autosavedDraftPath: String?,
        committedRevision: UInt64,
        acknowledgedRevision: UInt64,
        pendingTextDraft: CanvasRecoverableTextDraft?
    ) {
        self.sessionID = sessionID
        self.updatedAt = updatedAt
        self.displayName = displayName
        self.sourcePath = sourcePath
        self.baseFingerprint = baseFingerprint
        self.autosavedDraftPath = autosavedDraftPath
        self.committedRevision = committedRevision
        self.acknowledgedRevision = acknowledgedRevision
        self.pendingTextDraft = pendingTextDraft
    }
}

/// Result of inspecting a recovery entry on launch.
public enum CanvasRecoveryInspection: Equatable, Sendable {
    /// Untitled document recovery backed by an `NSDocument` autosaved draft file and optional text draft.
    case restorableUntitled(
        envelope: CanvasRecoveryEnvelope,
        draftURL: URL,
        envelopeURL: URL
    )
    /// Connected document whose source file on disk still matches `baseFingerprint`.
    case restorableConnected(
        envelope: CanvasRecoveryEnvelope,
        sourceURL: URL,
        contentsURL: URL,
        envelopeURL: URL
    )
    /// Connected document whose source file on disk changed or was removed since `baseFingerprint`;
    /// must restore as a separate untitled document without modifying the source file.
    case sourceChangedRestoreAsUntitled(
        envelope: CanvasRecoveryEnvelope,
        originalSourceURL: URL,
        draftURL: URL,
        envelopeURL: URL
    )
    /// Corrupt recovery envelope or corrupt `NSDocument` draft file; original source remains untouched.
    case corrupt(
        envelopeURL: URL,
        draftURL: URL?,
        sourceURL: URL?,
        reason: String
    )
}

/// Manages private owner-only recovery envelopes under Application Support (or an isolated test directory).
public final class CanvasRecoveryStore: Sendable {
    public static let bundleIdentifier = "local.elixircanvas.native"

    public let directoryURL: URL
    public let draftsDirectoryURL: URL

    public init(directoryURL: URL? = nil, draftsDirectoryURL: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        let baseDir: URL
        if let directoryURL {
            baseDir = directoryURL
        } else if let envDir = env["ELIXIR_CANVAS_RECOVERY_DIR"], !envDir.isEmpty {
            baseDir = URL(fileURLWithPath: envDir, isDirectory: true)
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            baseDir = appSupport
                .appendingPathComponent(Self.bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Recovery", isDirectory: true)
        }
        self.directoryURL = baseDir
        if let draftsDirectoryURL {
            self.draftsDirectoryURL = draftsDirectoryURL
        } else if let envDrafts = env["ELIXIR_CANVAS_DRAFTS_DIR"], !envDrafts.isEmpty {
            self.draftsDirectoryURL = URL(fileURLWithPath: envDrafts, isDirectory: true)
        } else {
            self.draftsDirectoryURL = baseDir.appendingPathComponent("Drafts", isDirectory: true)
        }
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.createDirectory(
            at: draftsDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func envelopeURL(for sessionID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(sessionID.uuidString).envelope.json")
    }

    public func draftURL(for sessionID: UUID) -> URL {
        draftsDirectoryURL.appendingPathComponent("\(sessionID.uuidString).draft.json")
    }

    /// Atomically writes a private `0600` recovery envelope without duplicating the committed JSON snapshot.
    public func write(_ envelope: CanvasRecoveryEnvelope) throws {
        let fm = FileManager.default
        do {
            try ensureDirectories()
        } catch {
            throw CanvasPersistenceError.writeFailed("Could not prepare private recovery directory: \(error.localizedDescription)")
        }
        guard fm.isWritableFile(atPath: directoryURL.path) else {
            throw CanvasPersistenceError.writeFailed("Recovery directory is not writable.")
        }
        let targetURL = envelopeURL(for: envelope.sessionID)
        let tempURL = directoryURL.appendingPathComponent(".tmp-\(UUID().uuidString).envelope.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw CanvasPersistenceError.writeFailed("Could not encode recovery envelope: \(error.localizedDescription)")
        }
        do {
            try data.write(to: tempURL, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
            if Darwin.rename(tempURL.path, targetURL.path) != 0 {
                let code = errno
                try? fm.removeItem(at: tempURL)
                throw CanvasPersistenceError.writeFailed("Could not replace recovery envelope: \(String(cString: strerror(code)))")
            }
        } catch let error as CanvasPersistenceError {
            try? fm.removeItem(at: tempURL)
            throw error
        } catch {
            try? fm.removeItem(at: tempURL)
            throw CanvasPersistenceError.writeFailed("Could not write recovery envelope: \(error.localizedDescription)")
        }
    }

    /// Removes the recovery envelope (and any remaining draft file) for `sessionID`.
    public func remove(sessionID: UUID, removeDraft: Bool = true) {
        let fm = FileManager.default
        let envURL = envelopeURL(for: sessionID)
        if let data = try? Data(contentsOf: envURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if removeDraft,
               let env = try? decoder.decode(CanvasRecoveryEnvelope.self, from: data),
               let draftPath = env.autosavedDraftPath {
                try? fm.removeItem(atPath: draftPath)
            }
        }
        try? fm.removeItem(at: envURL)
        if removeDraft {
            try? fm.removeItem(at: draftURL(for: sessionID))
        }
    }

    /// Explicitly discards a specific inspected recovery record (including corrupt records).
    public func discard(_ inspection: CanvasRecoveryInspection) {
        let fm = FileManager.default
        switch inspection {
        case .restorableUntitled(let env, let draftURL, let envURL):
            try? fm.removeItem(at: draftURL)
            try? fm.removeItem(at: envURL)
            try? fm.removeItem(at: self.draftURL(for: env.sessionID))
        case .restorableConnected(let env, let sourceURL, let contentsURL, let envURL):
            if contentsURL.canonicalFileURL != sourceURL.canonicalFileURL {
                try? fm.removeItem(at: contentsURL)
            }
            try? fm.removeItem(at: envURL)
            try? fm.removeItem(at: self.draftURL(for: env.sessionID))
        case .sourceChangedRestoreAsUntitled(let env, _, let draftURL, let envURL):
            try? fm.removeItem(at: draftURL)
            try? fm.removeItem(at: envURL)
            try? fm.removeItem(at: self.draftURL(for: env.sessionID))
        case .corrupt(let envURL, let draftURL, _, _):
            if let draftURL {
                try? fm.removeItem(at: draftURL)
            }
            try? fm.removeItem(at: envURL)
        }
    }

    /// Inspects all recovery envelopes on launch, comparing any connected source against its recorded `baseFingerprint`.
    public func inspectAll() -> [CanvasRecoveryInspection] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let envelopeURLs = entries
            .filter { $0.lastPathComponent.hasSuffix(".envelope.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return envelopeURLs.map { envURL in
            let data: Data
            do {
                data = try Data(contentsOf: envURL)
            } catch {
                return .corrupt(
                    envelopeURL: envURL,
                    draftURL: nil,
                    sourceURL: nil,
                    reason: "Could not read recovery file \(envURL.lastPathComponent)."
                )
            }
            let envelope: CanvasRecoveryEnvelope
            do {
                envelope = try decoder.decode(CanvasRecoveryEnvelope.self, from: data)
            } catch {
                return .corrupt(
                    envelopeURL: envURL,
                    draftURL: nil,
                    sourceURL: nil,
                    reason: "Recovery metadata in \(envURL.lastPathComponent) is damaged."
                )
            }
            let sourceURL = envelope.sourcePath.map { URL(fileURLWithPath: $0) }
            let draftURL = envelope.autosavedDraftPath.map { URL(fileURLWithPath: $0) }

            if let draftURL {
                guard let draftData = try? Data(contentsOf: draftURL),
                      (try? CanvasDocument(data: draftData)) != nil else {
                    return .corrupt(
                        envelopeURL: envURL,
                        draftURL: draftURL,
                        sourceURL: sourceURL,
                        reason: "Autosaved recovery draft for \(envelope.displayName) is missing or damaged."
                    )
                }
            }

            if let sourceURL {
                let sourceMatchesBase: Bool
                if let baseFingerprint = envelope.baseFingerprint,
                   let inspected = try? CanvasFileFingerprint.inspectRegularFile(at: sourceURL) {
                    sourceMatchesBase = inspected.fingerprint.matchesBytes(of: baseFingerprint)
                } else {
                    sourceMatchesBase = false
                }

                if sourceMatchesBase {
                    let contentsURL = draftURL ?? sourceURL
                    guard let contentsData = try? Data(contentsOf: contentsURL),
                          (try? CanvasDocument(data: contentsData)) != nil else {
                        return .corrupt(
                            envelopeURL: envURL,
                            draftURL: draftURL,
                            sourceURL: sourceURL,
                            reason: "Recovered canvas data for \(envelope.displayName) is invalid."
                        )
                    }
                    return .restorableConnected(
                        envelope: envelope,
                        sourceURL: sourceURL,
                        contentsURL: contentsURL,
                        envelopeURL: envURL
                    )
                } else {
                    guard let draftURL else {
                        return .corrupt(
                            envelopeURL: envURL,
                            draftURL: nil,
                            sourceURL: sourceURL,
                            reason: "Source file \(sourceURL.lastPathComponent) changed externally and no separate recovery draft exists."
                        )
                    }
                    return .sourceChangedRestoreAsUntitled(
                        envelope: envelope,
                        originalSourceURL: sourceURL,
                        draftURL: draftURL,
                        envelopeURL: envURL
                    )
                }
            } else {
                guard let draftURL else {
                    return .corrupt(
                        envelopeURL: envURL,
                        draftURL: nil,
                        sourceURL: nil,
                        reason: "Untitled recovery for \(envelope.displayName) has no autosaved draft file."
                    )
                }
                return .restorableUntitled(
                    envelope: envelope,
                    draftURL: draftURL,
                    envelopeURL: envURL
                )
            }
        }
    }
}
