import AppKit
import CanvasCore
import UniformTypeIdentifiers

public enum CanvasConflictDecision: Equatable, Sendable {
    case saveAs(URL)
    case reloadFromDisk(confirmed: Bool)
    case keepEditing
}

public enum CanvasCloseDecision: Equatable, Sendable {
    case save(destinationURL: URL?)
    case keepRecovery
    case discardChanges
    case cancel
}

public enum CanvasRecoveryLaunchDecision: Equatable, Sendable {
    case restore
    case discard
    case keepCorruptFile
}

/// Native `NSDocument` controller owning file identity, coordinated safe saving,
/// byte-fingerprint conflict detection, coalesced 5s/30s autosave, `NSDocument` draft autosaving,
/// private app-owned recovery envelopes, and document undo history (`macos/SPEC.md §4, §6`).
@MainActor
@objc(CanvasNativeDocument)
public final class CanvasNativeDocument: NSDocument {
    public nonisolated override class var autosavesInPlace: Bool { true }
    public nonisolated override class var autosavesDrafts: Bool { true }

    private struct ActiveWriteContext: Sendable {
        let data: Data
        let revision: UInt64
        let generation: UInt64
        let expectedFingerprint: CanvasFileFingerprint?
        let readOnlyReason: String?
        let isDraftWrite: Bool
    }

    public let sessionID: UUID
    public let recoveryStore: CanvasRecoveryStore
    public private(set) var session: CanvasSession
    public private(set) var canvasView: CanvasView
    private let sharedUndoManager: UndoManager

    public override var undoManager: UndoManager? {
        get { sharedUndoManager }
        set {}
    }

    public private(set) var displayNameTitle: String
    public private(set) var sourceGeneration: UInt64 = 0
    public private(set) var acknowledgedFingerprint: CanvasFileFingerprint?
    public private(set) var acknowledgedRevision: UInt64 = 0
    public private(set) var acknowledgedCanonicalData: Data
    public private(set) var conflictReason: CanvasConflictReason? {
        didSet {
            if conflictReason == nil {
                acknowledgedConflictReason = nil
            }
        }
    }
    public private(set) var lastSaveError: String? {
        didSet {
            if lastSaveError != nil {
                saveErrorSeq &+= 1
            } else {
                acknowledgedSaveErrorSeq = saveErrorSeq
            }
        }
    }
    public private(set) var lastRecoveryError: String? {
        didSet {
            if lastRecoveryError != nil {
                recoveryErrorSeq &+= 1
            } else {
                acknowledgedRecoveryErrorSeq = recoveryErrorSeq
            }
        }
    }
    public private(set) var readOnlyReason: String? {
        didSet {
            if readOnlyReason == nil {
                acknowledgedReadOnlyReason = nil
            }
        }
    }
    public private(set) var isSavingInFlight = false
    public private(set) var isRecoveryWriteInFlight = false
    public private(set) var isClosed = false
    public private(set) var lastPreReloadRecoverySessionID: UUID?
    private var pendingRecoveryAfterSourceSave = false
    private var acknowledgedConflictReason: CanvasConflictReason?
    private var saveErrorSeq: UInt64 = 0
    private var acknowledgedSaveErrorSeq: UInt64 = 0
    private var recoveryErrorSeq: UInt64 = 0
    private var acknowledgedRecoveryErrorSeq: UInt64 = 0
    private var acknowledgedReadOnlyReason: String?

    private nonisolated(unsafe) var activeWriteContext: ActiveWriteContext?
    private nonisolated(unsafe) var activeWriteCaughtError: Error?

    public var quietAutosaveInterval: TimeInterval = 5.0
    public var maxContinuousAutosaveInterval: TimeInterval = 30.0
    public var synchronousWaitTimeout: TimeInterval = 5.0
    private var firstUnflushedChangeAt: Date?
    private var quietTimer: Timer?
    private var maxContinuousTimer: Timer?
    public private(set) var isAutosaveScheduled = false

    public var onStateDidChange: ((CanvasPersistenceState) -> Void)?
    public var onConflictDetected: ((CanvasConflictReason) -> Void)?

    /// Optional deterministic hook for testing in-flight write races (`macos/SPEC.md §4, §8`).
    /// Receives `(snapshotRevision, sourceGeneration, executeWriteClosure)`.
    public var writeInterceptor: ((UInt64, UInt64, @escaping () -> Void) -> Void)?


    /// Optional deterministic hook for delaying the `NSDocument` completion callback beyond `synchronousWaitTimeout`.
    public var saveCompletionDelayHook: ((@escaping () -> Void) -> Void)?
    /// Optional destination provider for interactive Save / Save As when no URL is passed.
    public var saveDestinationProvider: ((String) -> URL?)?

    /// Optional close-decision provider for deterministic testing or custom sheet handling.
    public var closeDecisionProvider: ((CanvasPersistenceState) -> CanvasCloseDecision)?

    /// Optional conflict-decision provider for deterministic testing or custom sheet handling.
    public var conflictDecisionProvider: ((CanvasConflictReason) -> CanvasConflictDecision)?

    public override convenience init() {
        let blank = try! CanvasDocument.blank()
        try! self.init(
            document: blank,
            displayName: "Untitled",
            sourceURL: nil,
            sourceFingerprint: nil,
            isWritable: true,
            recoveryStore: CanvasRecoveryStore()
        )
    }

    public init(
        document: CanvasDocument,
        displayName: String,
        sourceURL: URL? = nil,
        sourceFingerprint: CanvasFileFingerprint? = nil,
        isWritable: Bool = true,
        sessionID: UUID = UUID(),
        recoveryStore: CanvasRecoveryStore = CanvasRecoveryStore()
    ) throws {
        let canonical = try CanvasDocument.encode(document.root)
        let history = UndoManager()
        history.groupsByEvent = false
        let canvasSession = CanvasSession(document: document)
        let view = CanvasView(session: canvasSession, undoManager: history)

        self.sessionID = sessionID
        self.recoveryStore = recoveryStore
        self.session = canvasSession
        self.canvasView = view
        self.sharedUndoManager = history
        self.displayNameTitle = displayName
        self.acknowledgedFingerprint = sourceFingerprint
        self.acknowledgedRevision = 0
        self.acknowledgedCanonicalData = canonical
        self.readOnlyReason = (!isWritable && sourceURL != nil)
            ? "File or folder is read-only; use Save As to save a copy."
            : nil
        canvasSession.isReadOnly = (self.readOnlyReason != nil)

        super.init()
        self.hasUndoManager = false
        self.fileType = "public.json"
        if let sourceURL {
            self.fileURL = sourceURL
            self.fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate]) as? Date
            self.sourceGeneration = 1
        }
        wireCallbacks()
        syncStatusBanner()
    }

    public convenience init(
        untitledDisplayName: String = "Untitled",
        recoveryStore: CanvasRecoveryStore = CanvasRecoveryStore()
    ) throws {
        let blank = try CanvasDocument.blank()
        try self.init(
            document: blank,
            displayName: untitledDisplayName,
            sourceURL: nil,
            sourceFingerprint: nil,
            isWritable: true,
            recoveryStore: recoveryStore
        )
    }

    public convenience init(
        opening url: URL,
        recoveryStore: CanvasRecoveryStore = CanvasRecoveryStore()
    ) throws {
        let inspected: (data: Data, fingerprint: CanvasFileFingerprint, isWritable: Bool)
        do {
            inspected = try CanvasFileFingerprint.inspectRegularFile(at: url)
        } catch let error as CanvasPersistenceError {
            switch error {
            case .externalConflict(.notRegularFile):
                throw CanvasDocumentError("\(url.lastPathComponent) is not a regular file.")
            case .externalConflict(.missingOrReplaced):
                throw CanvasDocumentError("\(url.lastPathComponent) does not exist.")
            default:
                throw CanvasDocumentError(error.localizedDescription)
            }
        }
        let doc = try CanvasDocument(data: inspected.data)
        try self.init(
            document: doc,
            displayName: url.lastPathComponent,
            sourceURL: url,
            sourceFingerprint: inspected.fingerprint,
            isWritable: inspected.isWritable,
            recoveryStore: recoveryStore
        )
    }

    /// Restores a document session from an inspected recovery entry using `NSDocument`'s draft lifecycle
    /// without automatically overwriting any connected source file (`macos/SPEC.md §4`).
    public convenience init(
        restoring inspection: CanvasRecoveryInspection,
        recoveryStore: CanvasRecoveryStore = CanvasRecoveryStore()
    ) throws {
        switch inspection {
        case .restorableUntitled(let env, let draftURL, _):
            let draftData = try Data(contentsOf: draftURL)
            let doc = try CanvasDocument(data: draftData)
            try self.init(
                document: doc,
                displayName: env.displayName,
                sourceURL: nil,
                sourceFingerprint: nil,
                isWritable: true,
                sessionID: env.sessionID,
                recoveryStore: recoveryStore
            )
            self.autosavedContentsFileURL = draftURL
            let restoredRev = max(1, env.committedRevision)
            try self.session.replaceRoot(doc.root, revision: restoredRev)
            self.acknowledgedRevision = 0
            self.acknowledgedCanonicalData = try CanvasDocument.encode(CanvasDocument.blank().root)
            self.canvasView.reloadFromSession(clearingUndoHistory: true)
            if let textDraft = env.pendingTextDraft {
                self.canvasView.restoreRecoverableTextDraft(textDraft)
            }
            self.notifyStateDidChange()

        case .restorableConnected(let env, let sourceURL, let contentsURL, _):
            let sourceInspected = try CanvasFileFingerprint.inspectRegularFile(at: sourceURL)
            let sourceDoc = try CanvasDocument(data: sourceInspected.data)
            let restoredData = try Data(contentsOf: contentsURL)
            let restoredDoc = try CanvasDocument(data: restoredData)
            try self.init(
                document: restoredDoc,
                displayName: sourceURL.lastPathComponent,
                sourceURL: sourceURL,
                sourceFingerprint: sourceInspected.fingerprint,
                isWritable: sourceInspected.isWritable,
                sessionID: env.sessionID,
                recoveryStore: recoveryStore
            )
            if contentsURL.canonicalFileURL != sourceURL.canonicalFileURL {
                self.autosavedContentsFileURL = contentsURL
            }
            self.acknowledgedCanonicalData = try CanvasDocument.encode(sourceDoc.root)
            self.acknowledgedRevision = env.acknowledgedRevision
            let targetRev = (restoredData == sourceInspected.data) ? env.acknowledgedRevision : max(env.acknowledgedRevision + 1, env.committedRevision)
            try self.session.replaceRoot(restoredDoc.root, revision: targetRev)
            self.canvasView.reloadFromSession(clearingUndoHistory: true)
            if let textDraft = env.pendingTextDraft {
                self.canvasView.restoreRecoverableTextDraft(textDraft)
            }
            self.notifyStateDidChange()

        case .sourceChangedRestoreAsUntitled(let env, let originalSourceURL, let draftURL, _):
            let draftData = try Data(contentsOf: draftURL)
            let doc = try CanvasDocument(data: draftData)
            let untitledName = "Recovered — \(originalSourceURL.deletingPathExtension().lastPathComponent)"
            try self.init(
                document: doc,
                displayName: untitledName,
                sourceURL: nil,
                sourceFingerprint: nil,
                isWritable: true,
                sessionID: env.sessionID,
                recoveryStore: recoveryStore
            )
            self.autosavedContentsFileURL = draftURL
            let restoredRev = max(1, env.committedRevision)
            try self.session.replaceRoot(doc.root, revision: restoredRev)
            self.acknowledgedRevision = 0
            self.acknowledgedCanonicalData = try CanvasDocument.encode(CanvasDocument.blank().root)
            self.canvasView.reloadFromSession(clearingUndoHistory: true)
            if let textDraft = env.pendingTextDraft {
                self.canvasView.restoreRecoverableTextDraft(textDraft)
            }
            // Update the recovery envelope so it is now tracked as untitled without referencing the changed source.
            try? self.writeRecoverySnapshotNow()
            self.notifyStateDidChange()

        case .corrupt(_, _, _, let reason):
            throw CanvasPersistenceError.corruptRecovery(reason)
        }
    }

    private func wireCallbacks() {
        session.onDidMutate = { [weak self] _ in
            guard let self else { return }
            self.handleSessionDidMutate()
        }
        canvasView.onDraftStateDidChange = { [weak self] in
            guard let self else { return }
            self.handleDraftStateDidChange()
        }
    }

    public var hasUnacknowledgedCommittedChanges: Bool {
        guard let currentCanonical = try? session.encodedData() else {
            return session.revision != acknowledgedRevision
        }
        return currentCanonical != acknowledgedCanonicalData
    }

    public var persistenceState: CanvasPersistenceState {
        let draft = canvasView.hasPendingDraftOrPreview
        if isSavingInFlight {
            return .saving(hasPendingDraft: draft)
        }
        if let conflictReason {
            return .conflict(reason: conflictReason, hasPendingDraft: draft)
        }
        if let readOnlyReason {
            return .readOnly(reason: readOnlyReason, hasPendingDraft: draft)
        }
        if let lastSaveError {
            return .saveFailed(message: lastSaveError, hasPendingDraft: draft)
        }
        guard fileURL != nil else {
            return .untitled(isDirty: hasUnacknowledgedCommittedChanges, hasPendingDraft: draft)
        }
        if hasUnacknowledgedCommittedChanges {
            return .changesPending(hasPendingDraft: draft)
        }
        return .saved(hasPendingDraft: draft)
    }

    public var windowTitle: String {
        "\(displayNameTitle) — \(persistenceState.statusSummary)"
    }

    private func handleSessionDidMutate() {
        let changeType: NSDocument.ChangeType
        if sharedUndoManager.isUndoing {
            changeType = .changeUndone
        } else if sharedUndoManager.isRedoing {
            changeType = .changeRedone
        } else {
            changeType = .changeDone
        }
        updateChangeCount(changeType)
        if hasUnacknowledgedCommittedChanges {
            if !isSavingInFlight {
                scheduleCoalescedAutosaveAndRecovery()
            }
        } else {
            cancelScheduledTimers()
            if fileURL != nil && conflictReason == nil && lastSaveError == nil && canvasView.recoverableTextDraft == nil {
                recoveryStore.remove(sessionID: sessionID)
                autosavedContentsFileURL = nil
            }
        }
        notifyStateDidChange()
    }

    private func handleDraftStateDidChange() {
        if canvasView.recoverableTextDraft != nil {
            if !isSavingInFlight {
                scheduleCoalescedAutosaveAndRecovery()
            }
        } else if !hasUnacknowledgedCommittedChanges && conflictReason == nil && lastSaveError == nil {
            cancelScheduledTimers()
            if fileURL != nil {
                recoveryStore.remove(sessionID: sessionID)
                autosavedContentsFileURL = nil
            }
        }
        notifyStateDidChange()
    }

    private func notifyStateDidChange() {
        syncStatusBanner()
        onStateDidChange?(persistenceState)
    }

    private var nextUnacknowledgedBannerKind: CanvasStatusBannerView.BannerKind? {
        if let conflict = conflictReason, acknowledgedConflictReason != conflict {
            return .conflict(conflict)
        }
        if let saveErr = lastSaveError, acknowledgedSaveErrorSeq != saveErrorSeq {
            let canRetry = fileURL != nil && conflictReason == nil && readOnlyReason == nil
            return .saveError(saveErr, canRetry: canRetry)
        }
        if let recErr = lastRecoveryError, acknowledgedRecoveryErrorSeq != recoveryErrorSeq {
            return .recoveryError(recErr)
        }
        if let readOnly = readOnlyReason, acknowledgedReadOnlyReason != readOnly {
            return .readOnly(readOnly)
        }
        return nil
    }

    public var isStatusBannerDismissed: Bool {
        nextUnacknowledgedBannerKind == nil &&
            (conflictReason != nil || lastSaveError != nil || lastRecoveryError != nil || readOnlyReason != nil)
    }

    public func syncStatusBanner() {
        canvasView.statusBanner.configure(kind: nextUnacknowledgedBannerKind)
        canvasView.positionStatusBanner()
        canvasView.needsDisplay = true
    }

    public func dismissStatusBanner() {
        switch canvasView.statusBanner.activeKind ?? nextUnacknowledgedBannerKind {
        case .conflict(let reason):
            acknowledgedConflictReason = reason
            _ = try? applyConflictDecision(.keepEditing)
        case .saveError:
            acknowledgedSaveErrorSeq = saveErrorSeq
        case .recoveryError:
            acknowledgedRecoveryErrorSeq = recoveryErrorSeq
        case .readOnly(let reason):
            acknowledgedReadOnlyReason = reason
        case .v1CodeNotice:
            canvasView.statusBanner.configure(kind: nil)
        case nil:
            break
        }
        notifyStateDidChange()
    }

    // MARK: - Coalesced 5s quiet / 30s continuous scheduling

    private func scheduleCoalescedAutosaveAndRecovery() {
        guard !isClosed else { return }
        let now = Date()
        if firstUnflushedChangeAt == nil {
            firstUnflushedChangeAt = now
            let maxInterval = max(0.001, maxContinuousAutosaveInterval)
            maxContinuousTimer?.invalidate()
            maxContinuousTimer = Timer.scheduledTimer(withTimeInterval: maxInterval, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.coalescedTimerDidFire()
                }
            }
        }
        if let first = firstUnflushedChangeAt,
           now.timeIntervalSince(first) >= maxContinuousAutosaveInterval {
            coalescedTimerDidFire()
            return
        }
        let quietInterval = max(0.001, quietAutosaveInterval)
        quietTimer?.invalidate()
        quietTimer = Timer.scheduledTimer(withTimeInterval: quietInterval, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.coalescedTimerDidFire()
            }
        }
        isAutosaveScheduled = true
    }

    public func cancelScheduledTimers() {
        quietTimer?.invalidate()
        quietTimer = nil
        maxContinuousTimer?.invalidate()
        maxContinuousTimer = nil
        firstUnflushedChangeAt = nil
        isAutosaveScheduled = false
    }

    public func triggerScheduledAutosaveNow() {
        coalescedTimerDidFire()
    }

    private func coalescedTimerDidFire() {
        cancelScheduledTimers()
        guard !isClosed else { return }

        if let url = fileURL,
           conflictReason == nil,
           readOnlyReason == nil,
           !isSavingInFlight,
           hasUnacknowledgedCommittedChanges {
            _ = try? performCoordinatedSave(to: url, for: .autosaveInPlaceOperation)
        }

        if needsRecoveryPersistence {
            try? writeRecoverySnapshotNow()
        }
    }

    public var needsRecoveryPersistence: Bool {
        if canvasView.recoverableTextDraft != nil {
            return true
        }
        if fileURL == nil {
            return hasUnacknowledgedCommittedChanges
        }
        return conflictReason != nil || lastSaveError != nil || hasUnacknowledgedCommittedChanges
    }

    // MARK: - Explicit Save, Save As, Version-2 Copy, and Reload

    /// Flushes valid pending editors/previews and saves to the connected file (or prompts for a destination if untitled).
    @discardableResult
    public func saveDocumentExplicitly(destinationURL: URL? = nil) throws -> Bool {
        do {
            try canvasView.flushPendingEditsForSave()
        } catch {
            throw CanvasPersistenceError.invalidDraft(error.localizedDescription)
        }
        if let conflictReason {
            onConflictDetected?(conflictReason)
            throw CanvasPersistenceError.externalConflict(conflictReason)
        }
        if let readOnlyReason {
            throw CanvasPersistenceError.readOnlySource(readOnlyReason)
        }
        if let currentURL = fileURL {
            if !hasUnacknowledgedCommittedChanges && lastSaveError == nil {
                // Verify external file is still intact even when no local changes exist.
                if let expectedFP = acknowledgedFingerprint {
                    do {
                        let inspected = try CanvasFileFingerprint.inspectRegularFile(at: currentURL)
                        if !inspected.fingerprint.matchesBytes(of: expectedFP) {
                            enterConflictState(.modifiedExternally(currentFingerprint: inspected.fingerprint))
                            throw CanvasPersistenceError.externalConflict(self.conflictReason!)
                        }
                    } catch let err as CanvasPersistenceError {
                        if case .externalConflict(let reason) = err {
                            enterConflictState(reason)
                        }
                        throw err
                    }
                }
                recoveryStore.remove(sessionID: sessionID)
                autosavedContentsFileURL = nil
                notifyStateDidChange()
                return true
            }
            return try performCoordinatedSave(to: currentURL, for: .saveOperation)
        } else {
            let chosenURL = destinationURL ?? chooseSaveDestination(suggestedName: suggestedSaveFilename())
            guard let chosenURL else { return false }
            return try saveDocumentAs(to: chosenURL)
        }
    }

    /// Flushes valid pending editors/previews and writes the document to a new destination URL via `NSDocument` safe-saving,
    /// promoting the document's connected identity only after the write succeeds (`macos/SPEC.md §3, §4`).
    @discardableResult
    public func saveDocumentAs(to destinationURL: URL) throws -> Bool {
        do {
            try canvasView.flushPendingEditsForSave()
        } catch {
            throw CanvasPersistenceError.invalidDraft(error.localizedDescription)
        }
        if let currentURL = fileURL, destinationURL.refersToSameFile(as: currentURL) {
            if conflictReason != nil {
                throw CanvasPersistenceError.writeFailed(
                    "Choose a different destination file to resolve the conflict without overwriting the external file."
                )
            }
            if let readOnlyReason {
                throw CanvasPersistenceError.readOnlySource(readOnlyReason)
            }
            return try saveDocumentExplicitly()
        }
        let op: NSDocument.SaveOperationType = (fileURL == nil) ? .saveOperation : .saveAsOperation
        return try performCoordinatedSave(to: destinationURL, for: op)
    }

    /// Writes an explicit version-2 snapshot copy to `destinationURL` after flushing valid drafts,
    /// leaving the original source, version, baseline, conflict/dirty state, and undo history untouched (`macos/SPEC.md §5`).
    public func saveVersion2Copy(to destinationURL: URL) throws {
        do {
            try canvasView.flushPendingEditsForSave()
        } catch {
            throw CanvasPersistenceError.invalidDraft(error.localizedDescription)
        }
        guard (session.root["version"] as? Int) == 1 else {
            throw CanvasPersistenceError.writeFailed("Only version-1 canvases need a separate version-2 copy.")
        }
        if let currentURL = fileURL, destinationURL.refersToSameFile(as: currentURL) {
            throw CanvasPersistenceError.writeFailed(
                "Choose a different file for the version-2 copy so the original version-1 file remains untouched."
            )
        }
        let copyData = try session.encodedVersion2CopyData()
        let parentDir = destinationURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parentDir.path) else {
            throw CanvasPersistenceError.writeFailed("Destination folder is not writable.")
        }
        let tempURL = parentDir.appendingPathComponent(".tmp-v2copy-\(UUID().uuidString).json")
        do {
            try copyData.write(to: tempURL, options: .withoutOverwriting)
            if Darwin.rename(tempURL.path, destinationURL.path) != 0 {
                let code = errno
                try? FileManager.default.removeItem(at: tempURL)
                throw CanvasPersistenceError.writeFailed("Could not write version-2 copy: \(String(cString: strerror(code)))")
            }
        } catch let error as CanvasPersistenceError {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw CanvasPersistenceError.writeFailed("Could not write version-2 copy: \(error.localizedDescription)")
        }
    }

    /// Reloads the connected source file from disk after explicit confirmation, preserving a recovery snapshot
    /// of any unsaved local work before replacing the model and resetting incompatible undo history (`macos/SPEC.md §4`).
    @discardableResult
    public func reloadFromDisk(confirmed: Bool) throws -> Bool {
        guard confirmed else { return false }
        guard let url = fileURL else {
            throw CanvasPersistenceError.writeFailed("Untitled documents have no disk source to reload.")
        }
        let hadLocalWorkToPreserve = hasUnacknowledgedCommittedChanges || canvasView.recoverableTextDraft != nil
        if hadLocalWorkToPreserve {
            let backupID = UUID()
            try writeRecoverySnapshotNow(
                requireAcknowledgement: true,
                targetSessionID: backupID,
                displayNameOverride: "Pre-Reload — \(displayNameTitle)",
                forceUntitledBackup: true
            )
            lastPreReloadRecoverySessionID = backupID
        }
        let inspected = try CanvasFileFingerprint.inspectRegularFile(at: url)
        let reloadedDoc = try CanvasDocument(data: inspected.data)
        let canonical = try CanvasDocument.encode(reloadedDoc.root)

        cancelScheduledTimers()
        sourceGeneration &+= 1
        fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        acknowledgedFingerprint = inspected.fingerprint
        acknowledgedCanonicalData = canonical
        acknowledgedRevision = 0
        conflictReason = nil
        lastSaveError = nil
        readOnlyReason = inspected.isWritable ? nil : "File or folder is read-only; use Save As to save a copy."
        session.isReadOnly = (readOnlyReason != nil)
        recoveryStore.remove(sessionID: sessionID, removeDraft: true)
        autosavedContentsFileURL = nil
        session.onDidMutate = nil
        canvasView.onDraftStateDidChange = nil
        try session.replaceRoot(reloadedDoc.root, revision: 0)
        canvasView.reloadFromSession(clearingUndoHistory: true)
        wireCallbacks()
        updateChangeCount(.changeCleared)
        notifyStateDidChange()
        return true
    }

    /// Evaluates external changes on the connected file (`NSFilePresenter` or explicit check) without reloading underneath the user.
    public nonisolated override func presentedItemDidChange() {
        Task { @MainActor [weak self] in
            _ = self?.checkExternalSourceStatus()
        }
    }
    @discardableResult
    public func checkExternalSourceStatus() -> Bool {
        guard let url = fileURL,
              let expectedFP = acknowledgedFingerprint,
              !isSavingInFlight else { return false }
        do {
            let inspected = try CanvasFileFingerprint.inspectRegularFile(at: url)
            if !inspected.fingerprint.matchesBytes(of: expectedFP) {
                enterConflictState(.modifiedExternally(currentFingerprint: inspected.fingerprint))
                return true
            }
        } catch let error as CanvasPersistenceError {
            if case .externalConflict(let reason) = error {
                enterConflictState(reason)
                return true
            }
        } catch {}
        return false
    }

    private func enterConflictState(_ reason: CanvasConflictReason) {
        cancelScheduledTimers()
        if conflictReason == reason {
            acknowledgedConflictReason = nil
        }
        conflictReason = reason
        try? writeRecoverySnapshotNow()
        notifyStateDidChange()
        onConflictDetected?(reason)
    }

    // MARK: - NSDocument Coordinated Safe-Save Execution

    @discardableResult
    public func performCoordinatedSave(
        to url: URL,
        for saveOperation: NSDocument.SaveOperationType
    ) throws -> Bool {
        if isRecoveryWriteInFlight {
            let waitLimit = Date().addingTimeInterval(max(0.001, synchronousWaitTimeout))
            while isRecoveryWriteInFlight && Date() < waitLimit {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            if isRecoveryWriteInFlight {
                throw CanvasPersistenceError.writeFailed(
                    "Cannot save while a recovery operation is still in progress."
                )
            }
        }
        let previousURL = self.fileURL
        let previousDisplayName = self.displayNameTitle
        let previousGen = self.sourceGeneration
        let isNewDestination = (saveOperation == .saveAsOperation) ||
            (saveOperation == .saveOperation && previousURL == nil) ||
            (previousURL.map { $0.canonicalFileURL != url.canonicalFileURL } ?? true)

        let capturedData = try session.encodedData()
        let capturedRevision = session.revision
        let targetGeneration = isNewDestination ? (previousGen &+ 1) : max(1, previousGen)
        let expectedFP: CanvasFileFingerprint? = isNewDestination ? nil : acknowledgedFingerprint

        cancelScheduledTimers()
        isSavingInFlight = true
        lastSaveError = nil
        notifyStateDidChange()

        var completionFinished = false
        var completionError: Error?

        let executeWrite: () -> Void = { [weak self] in
            guard let self else { return }
            if self.isClosed {
                self.isSavingInFlight = false
                completionFinished = true
                return
            }
            if !isNewDestination && self.sourceGeneration != previousGen {
                // Source generation advanced (e.g., Save As or Reload happened while this write was staged);
                // abort stale-generation completion so it cannot overwrite the new destination (`macos/SPEC.md §4`).
                self.isSavingInFlight = false
                completionFinished = true
                self.notifyStateDidChange()
                return
            }
            self.activeWriteContext = ActiveWriteContext(
                data: capturedData,
                revision: capturedRevision,
                generation: targetGeneration,
                expectedFingerprint: expectedFP,
                readOnlyReason: self.readOnlyReason,
                isDraftWrite: false
            )
            self.activeWriteCaughtError = nil

            self.invokeSuperSave(to: url, for: saveOperation) { [weak self] nsDocError in
                let handleCompletion: () -> Void = { [weak self] in
                    guard let self else { return }
                    let finalError = self.activeWriteCaughtError ?? nsDocError
                    self.activeWriteContext = nil
                    self.activeWriteCaughtError = nil
                    self.isSavingInFlight = false
                    completionFinished = true

                    if let finalError {
                        self.fileURL = previousURL
                        self.displayNameTitle = previousDisplayName
                        self.sourceGeneration = previousGen
                        let resolvedError = self.classifySaveFailure(
                            finalError,
                            destinationURL: url,
                            expectedFingerprint: expectedFP
                        )
                        completionError = resolvedError
                        if let persistenceErr = resolvedError as? CanvasPersistenceError,
                           case .externalConflict(let reason) = persistenceErr {
                            self.enterConflictState(reason)
                        } else {
                            self.lastSaveError = resolvedError.localizedDescription
                            try? self.writeRecoverySnapshotNow()
                            self.notifyStateDidChange()
                        }
                        if self.pendingRecoveryAfterSourceSave {
                            self.pendingRecoveryAfterSourceSave = false
                            try? self.writeRecoverySnapshotNow()
                        }
                        return
                    }

                    // Write succeeded: verify whether a newer sourceGeneration superseded this completion.
                    guard isNewDestination || self.sourceGeneration == previousGen else {
                        self.notifyStateDidChange()
                        return
                    }
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    let writtenPerms = (attrs?[.posixPermissions] as? NSNumber)?.intValue
                        ?? expectedFP?.posixPermissions
                    if self.fileURL == nil {
                        self.fileURL = url
                    }
                    self.displayNameTitle = url.lastPathComponent
                    self.sourceGeneration = targetGeneration
                    self.acknowledgedFingerprint = CanvasFileFingerprint(data: capturedData, posixPermissions: writtenPerms)
                    self.acknowledgedCanonicalData = capturedData
                    self.acknowledgedRevision = capturedRevision
                    self.conflictReason = nil
                    self.lastSaveError = nil
                    self.readOnlyReason = nil
                    self.session.isReadOnly = false
                    if self.hasUnacknowledgedCommittedChanges {
                        // Newer edits arrived while this snapshot was writing (`macos/SPEC.md §4` invariant 5).
                        self.scheduleCoalescedAutosaveAndRecovery()
                    } else if self.canvasView.recoverableTextDraft == nil && !self.pendingRecoveryAfterSourceSave {
                        self.recoveryStore.remove(sessionID: self.sessionID)
                        self.autosavedContentsFileURL = nil
                        self.lastRecoveryError = nil
                    } else {
                        self.pendingRecoveryAfterSourceSave = false
                        try? self.writeRecoverySnapshotNow()
                    }
                    self.notifyStateDidChange()
                }

                if let delayHook = self?.saveCompletionDelayHook {
                    delayHook(handleCompletion)
                } else {
                    handleCompletion()
                }
            }

            let deadline = Date().addingTimeInterval(max(0.001, self.synchronousWaitTimeout))
            while !completionFinished && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            if !completionFinished {
                // Never mark Saved or clear activeWriteContext/isSavingInFlight on timeout;
                // the completion handler remains armed and will settle state when it actually fires.
                completionError = CanvasPersistenceError.writeFailed(
                    "Save operation is still in progress and has not been acknowledged."
                )
            }
        }

        if let interceptor = writeInterceptor {
            interceptor(capturedRevision, previousGen, executeWrite)
            if let completionError { throw completionError }
            return completionFinished && completionError == nil
        } else {
            executeWrite()
            if let completionError { throw completionError }
            return completionFinished
        }
    }

    private func classifySaveFailure(
        _ error: Error,
        destinationURL: URL,
        expectedFingerprint: CanvasFileFingerprint?
    ) -> Error {
        if error is CanvasPersistenceError {
            return error
        }
        if let expectedFP = expectedFingerprint {
            do {
                let inspected = try CanvasFileFingerprint.inspectRegularFile(at: destinationURL)
                if !inspected.fingerprint.matchesBytes(of: expectedFP) {
                    return CanvasPersistenceError.externalConflict(
                        .modifiedExternally(currentFingerprint: inspected.fingerprint)
                    )
                }
            } catch let conflictErr as CanvasPersistenceError {
                return conflictErr
            } catch {}
        }
        return error
    }

    private func invokeSuperSave(
        to url: URL,
        for saveOperation: NSDocument.SaveOperationType,
        completion: @escaping ((any Error)?) -> Void
    ) {
        super.save(to: url, ofType: "public.json", for: saveOperation, completionHandler: completion)
    }

    public override func autosave(
        withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if autosavingIsImplicitlyCancellable {
            // Defer AppKit's implicit timer to our 5s-quiet / 30s-continuous coalesced schedule
            // and respect conflict/read-only pauses.
            completionHandler(nil)
            return
        }
        super.autosave(
            withImplicitCancellability: autosavingIsImplicitlyCancellable,
            completionHandler: completionHandler
        )
    }

    public nonisolated override func writeSafely(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) throws {
        do {
            if saveOperation == .autosaveElsewhereOperation {
                try recoveryStore.ensureDirectories()
                guard FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else {
                    throw CanvasPersistenceError.writeFailed("Draft recovery directory is not writable.")
                }
                try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                return
            }

            let context = activeWriteContext
            if let roReason = context?.readOnlyReason,
               (saveOperation == .autosaveInPlaceOperation ||
                (saveOperation == .saveOperation && context?.expectedFingerprint != nil)) {
                throw CanvasPersistenceError.readOnlySource(roReason)
            }

            if let expectedFP = context?.expectedFingerprint {
                let inspected = try CanvasFileFingerprint.inspectRegularFile(at: url)
                guard inspected.fingerprint.matchesBytes(of: expectedFP) else {
                    throw CanvasPersistenceError.externalConflict(
                        .modifiedExternally(currentFingerprint: inspected.fingerprint)
                    )
                }
                guard inspected.isWritable else {
                    throw CanvasPersistenceError.writeFailed("Destination \(url.lastPathComponent) is not writable.")
                }
            } else {
                let parentPath = url.deletingLastPathComponent().path
                guard FileManager.default.isWritableFile(atPath: parentPath) else {
                    throw CanvasPersistenceError.writeFailed("Destination folder is not writable.")
                }
                if FileManager.default.fileExists(atPath: url.path) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    if (attrs?[.type] as? FileAttributeType) != .typeRegular {
                        throw CanvasPersistenceError.externalConflict(.notRegularFile)
                    }
                    guard FileManager.default.isWritableFile(atPath: url.path) else {
                        throw CanvasPersistenceError.writeFailed("Existing file \(url.lastPathComponent) is not writable.")
                    }
                }
            }

            try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
            if let perms = context?.expectedFingerprint?.posixPermissions {
                try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path)
            }
        } catch {
            activeWriteCaughtError = error
            throw error
        }
    }

    public nonisolated override func write(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        originalContentsURL absoluteOriginalContentsURL: URL?
    ) throws {
        do {
            try super.write(
                to: url,
                ofType: typeName,
                for: saveOperation,
                originalContentsURL: absoluteOriginalContentsURL
            )
            // Recheck external byte fingerprint immediately before NSDocument's safe-save replaces the destination (`macos/SPEC.md §4`).
            if saveOperation != .autosaveElsewhereOperation,
               let expectedFP = activeWriteContext?.expectedFingerprint,
               let origURL = absoluteOriginalContentsURL ?? self.fileURL {
                let recheck = try CanvasFileFingerprint.inspectRegularFile(at: origURL)
                guard recheck.fingerprint.matchesBytes(of: expectedFP) else {
                    throw CanvasPersistenceError.externalConflict(
                        .modifiedExternally(currentFingerprint: recheck.fingerprint)
                    )
                }
            }
        } catch {
            activeWriteCaughtError = error
            throw error
        }
    }

    public nonisolated override func data(ofType typeName: String) throws -> Data {
        if let context = activeWriteContext {
            return context.data
        }
        return try MainActor.assumeIsolated {
            try session.encodedData()
        }
    }

    public nonisolated override func read(from url: URL, ofType typeName: String) throws {
        let inspected = try CanvasFileFingerprint.inspectRegularFile(at: url)
        let doc = try CanvasDocument(data: inspected.data)
        let canonical = try CanvasDocument.encode(doc.root)
        try MainActor.assumeIsolated {
            self.displayNameTitle = url.lastPathComponent
            self.sourceGeneration &+= 1
            self.acknowledgedFingerprint = inspected.fingerprint
            self.acknowledgedCanonicalData = canonical
            self.acknowledgedRevision = 0
            self.conflictReason = nil
            self.lastSaveError = nil
            self.readOnlyReason = inspected.isWritable
                ? nil
                : "File or folder is read-only; use Save As to save a copy."
            self.session.isReadOnly = !inspected.isWritable
            self.session.onDidMutate = nil
            self.canvasView.onDraftStateDidChange = nil
            try self.session.replaceRoot(doc.root, revision: 0)
            self.canvasView.reloadFromSession(clearingUndoHistory: true)
            self.wireCallbacks()
        }
    }

    public nonisolated override func read(from data: Data, ofType typeName: String) throws {
        let doc = try CanvasDocument(data: data)
        let canonical = try CanvasDocument.encode(doc.root)
        try MainActor.assumeIsolated {
            self.acknowledgedCanonicalData = canonical
            self.acknowledgedRevision = 0
            self.session.onDidMutate = nil
            self.canvasView.onDraftStateDidChange = nil
            try self.session.replaceRoot(doc.root, revision: 0)
            self.canvasView.reloadFromSession(clearingUndoHistory: true)
            self.wireCallbacks()
        }
    }

    // MARK: - NSDocument Draft Autosaving + Private Recovery Envelope

    /// Writes the committed snapshot through `NSDocument`'s `.autosaveElsewhereOperation` draft mechanism
    /// (`autosavedContentsFileURL`) and records only the uncovered state in `CanvasRecoveryStore` (`macos/SPEC.md §4`).
    public func writeRecoverySnapshotNow(
        requireAcknowledgement: Bool = false,
        targetSessionID: UUID? = nil,
        displayNameOverride: String? = nil,
        forceUntitledBackup: Bool = false
    ) throws {
        if isSavingInFlight || isRecoveryWriteInFlight {
            if !requireAcknowledgement {
                pendingRecoveryAfterSourceSave = true
                return
            }
            let waitLimit = Date().addingTimeInterval(max(0.001, synchronousWaitTimeout))
            while (isSavingInFlight || isRecoveryWriteInFlight) && Date() < waitLimit {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            if isSavingInFlight || isRecoveryWriteInFlight {
                throw CanvasPersistenceError.writeFailed(
                    "Cannot write recovery while another save operation is still in progress."
                )
            }
        }
        var reportedInCallback = false
        do {
            try recoveryStore.ensureDirectories()
            let effectiveSessionID = targetSessionID ?? sessionID
            let isIndependentBackup = (targetSessionID != nil && targetSessionID != sessionID)
            let previousAutosavedURL = self.autosavedContentsFileURL
            let draftURL = isIndependentBackup
                ? recoveryStore.draftURL(for: effectiveSessionID)
                : (self.autosavedContentsFileURL ?? recoveryStore.draftURL(for: effectiveSessionID))
            let snapshotData = try session.encodedData()
            let capturedRevision = max(1, session.revision)
            let capturedAckRevision = forceUntitledBackup ? 0 : acknowledgedRevision
            let capturedSourcePath = forceUntitledBackup ? nil : fileURL?.path
            let capturedBaseFP = forceUntitledBackup ? nil : acknowledgedFingerprint
            let capturedDisplayName = displayNameOverride ?? displayNameTitle
            let capturedTextDraft = canvasView.recoverableTextDraft
            let capturedGeneration = sourceGeneration

            isRecoveryWriteInFlight = true
            activeWriteContext = ActiveWriteContext(
                data: snapshotData,
                revision: capturedRevision,
                generation: capturedGeneration,
                expectedFingerprint: nil,
                readOnlyReason: nil,
                isDraftWrite: true
            )
            activeWriteCaughtError = nil

            var draftFinished = false
            var draftCompletionError: Error?

            let writeErr: (any Error)?
            do {
                try self.writeSafely(
                    to: draftURL,
                    ofType: "public.json",
                    for: .autosaveElsewhereOperation
                )
                writeErr = nil
            } catch {
                writeErr = self.activeWriteCaughtError ?? error
            }

            let finishDraft: () -> Void = { [weak self] in
                guard let self else { return }
                let caught = self.activeWriteCaughtError ?? writeErr
                self.activeWriteContext = nil
                self.activeWriteCaughtError = nil
                self.isRecoveryWriteInFlight = false
                draftFinished = true

                if self.isClosed || (!isIndependentBackup && self.sourceGeneration != capturedGeneration) {
                    return
                }

                if let caught {
                    if isIndependentBackup {
                        self.autosavedContentsFileURL = previousAutosavedURL
                    }
                    draftCompletionError = caught
                    reportedInCallback = true
                    self.lastRecoveryError = caught.localizedDescription
                    self.notifyStateDidChange()
                    return
                }
                if isIndependentBackup {
                    self.autosavedContentsFileURL = previousAutosavedURL
                } else {
                    self.autosavedContentsFileURL = draftURL
                }
                let envelope = CanvasRecoveryEnvelope(
                    sessionID: effectiveSessionID,
                    updatedAt: Date(),
                    displayName: capturedDisplayName,
                    sourcePath: capturedSourcePath,
                    baseFingerprint: capturedBaseFP,
                    autosavedDraftPath: draftURL.path,
                    committedRevision: capturedRevision,
                    acknowledgedRevision: capturedAckRevision,
                    pendingTextDraft: capturedTextDraft
                )
                do {
                    let hadRecoveryError = (self.lastRecoveryError != nil)
                    try self.recoveryStore.write(envelope)
                    self.lastRecoveryError = nil
                    if hadRecoveryError {
                        self.notifyStateDidChange()
                    }
                } catch {
                    draftCompletionError = error
                    reportedInCallback = true
                    self.lastRecoveryError = error.localizedDescription
                    self.notifyStateDidChange()
                }
            }
            if let delayHook = self.saveCompletionDelayHook {
                delayHook(finishDraft)
            } else {
                finishDraft()
            }

            let deadline = Date().addingTimeInterval(max(0.001, synchronousWaitTimeout))
            while !draftFinished && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            if !draftFinished {
                throw CanvasPersistenceError.writeFailed(
                    "Recovery draft write is still in progress and has not been acknowledged."
                )
            }
            if let draftCompletionError {
                throw draftCompletionError
            }
        } catch {
            if !reportedInCallback && !isRecoveryWriteInFlight {
                lastRecoveryError = error.localizedDescription
                notifyStateDidChange()
            }
            throw error
        }
    }

    // MARK: - Conflict Resolution and Close/Quit Guards

    @discardableResult
    public func applyConflictDecision(_ decision: CanvasConflictDecision) throws -> Bool {
        switch decision {
        case .saveAs(let destinationURL):
            return try saveDocumentAs(to: destinationURL)
        case .reloadFromDisk(let confirmed):
            return try reloadFromDisk(confirmed: confirmed)
        case .keepEditing:
            // Keep local edits and keep autosave paused.
            notifyStateDidChange()
            return true
        }
    }

    /// Evaluates whether the document can close safely, flushing valid pending editors and awaiting any in-flight write (`macos/SPEC.md §4`).
    public func shouldCloseDocument() -> Bool {
        let evaluation = evaluateCloseApproval()
        if evaluation.approved {
            evaluation.finalizeClose?()
        }
        return evaluation.approved
    }

    /// Evaluates close approval without marking the document closed or tearing down timers/recovery prematurely,
    /// allowing `applicationShouldTerminate` to abort cleanly if a subsequent window cancels Quit.
    public func evaluateCloseApproval() -> (approved: Bool, finalizeClose: (() -> Void)?) {
        if isSavingInFlight || isRecoveryWriteInFlight {
            let deadline = Date().addingTimeInterval(max(0.001, synchronousWaitTimeout))
            while (isSavingInFlight || isRecoveryWriteInFlight) && Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
            }
            if isSavingInFlight || isRecoveryWriteInFlight {
                // Never permit closing while an unacknowledged write is still in flight.
                return (false, nil)
            }
        }

        // Attempt to flush valid pending editors/previews first.
        var flushFailedError: String?
        if canvasView.hasPendingDraftOrPreview {
            do {
                try canvasView.flushPendingEditsForSave()
            } catch {
                flushFailedError = error.localizedDescription
            }
        }

        // If clean and no unresolved conflict/error/invalid draft, approve immediately and defer cleanup to finalizeClose.
        if flushFailedError == nil && !persistenceState.hasUnresolvedWork && !hasUnacknowledgedCommittedChanges && !isSavingInFlight && !isRecoveryWriteInFlight {
            return (true, { [weak self] in
                self?.finalizeCloseTeardown(discardRecovery: true)
            })
        }

        let decision = closeDecisionProvider?(persistenceState)
            ?? promptCloseDecision(flushFailedError: flushFailedError)

        switch decision {
        case .cancel:
            return (false, nil)
        case .save(let destinationURL):
            guard flushFailedError == nil else {
                // Invalid drafts block saving on close; keep window open with draft intact.
                return (false, nil)
            }
            do {
                let saved: Bool
                if let destinationURL {
                    saved = try saveDocumentAs(to: destinationURL)
                } else if conflictReason != nil || readOnlyReason != nil || fileURL == nil {
                    guard let chosen = chooseSaveDestination(suggestedName: suggestedSaveFilename()) else {
                        return (false, nil)
                    }
                    saved = try saveDocumentAs(to: chosen)
                } else {
                    saved = try saveDocumentExplicitly()
                }
                guard saved && !persistenceState.hasUnresolvedWork && !hasUnacknowledgedCommittedChanges else {
                    return (false, nil)
                }
                return (true, { [weak self] in
                    self?.finalizeCloseTeardown(discardRecovery: true)
                })
            } catch {
                return (false, nil)
            }
        case .keepRecovery:
            do {
                try writeRecoverySnapshotNow(requireAcknowledgement: true)
                return (true, { [weak self] in
                    self?.finalizeCloseTeardown(discardRecovery: false)
                })
            } catch {
                return (false, nil)
            }
        case .discardChanges:
            return (true, { [weak self] in
                guard let self else { return }
                self.canvasView.cancelInlineText()
                self.finalizeCloseTeardown(discardRecovery: true)
            })
        }
    }

    public func finalizeCloseTeardown(discardRecovery: Bool) {
        cancelScheduledTimers()
        if discardRecovery {
            recoveryStore.remove(sessionID: sessionID, removeDraft: true)
            autosavedContentsFileURL = nil
        }
        isClosed = true
    }

    public func suggestedSaveFilename() -> String {
        if let fileURL {
            return fileURL.lastPathComponent
        }
        let cleaned = displayNameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasSuffix(".json") {
            return cleaned
        }
        return "\(cleaned.isEmpty ? "Untitled" : cleaned).json"
    }

    public func chooseSaveDestination(suggestedName: String) -> URL? {
        if let provider = saveDestinationProvider {
            return provider(suggestedName)
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func promptCloseDecision(flushFailedError: String?) -> CanvasCloseDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if let flushFailedError {
            alert.messageText = "Cannot close “\(displayNameTitle)” with an invalid active edit"
            alert.informativeText = "\(flushFailedError) Return to editing to fix the draft, keep recoverable work, or discard changes."
            alert.addButton(withTitle: "Return to Editing")
            alert.addButton(withTitle: "Keep Recovery")
            alert.addButton(withTitle: "Discard Changes")
            let response = alert.runModal()
            switch response {
            case .alertSecondButtonReturn: return .keepRecovery
            case .alertThirdButtonReturn: return .discardChanges
            default: return .cancel
            }
        }
        alert.messageText = "Do you want to save changes to “\(displayNameTitle)”?"
        alert.informativeText = "Current status: \(persistenceState.statusSummary). You can save to a JSON file, retain recovery for next launch, discard changes, or cancel."
        alert.addButton(withTitle: (conflictReason != nil || readOnlyReason != nil || fileURL == nil) ? "Save As…" : "Save")
        alert.addButton(withTitle: "Keep Recovery")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .save(destinationURL: nil)
        case .alertSecondButtonReturn: return .keepRecovery
        case .alertThirdButtonReturn: return .discardChanges
        default: return .cancel
        }
    }
}
