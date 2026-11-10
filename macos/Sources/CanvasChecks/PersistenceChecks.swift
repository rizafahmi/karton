import AppKit
import CanvasCore
import CanvasUI
import Foundation

@MainActor
func checkPersistenceAndRecovery(repository: URL) throws {
    let fm = FileManager.default
    let tempRoot = fm.temporaryDirectory.appendingPathComponent("canvas-persistence-checks-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer {
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tempRoot.path)
        try? fm.removeItem(at: tempRoot)
    }

    let recoveryDir = tempRoot.appendingPathComponent("Recovery", isDirectory: true)
    let draftsDir = tempRoot.appendingPathComponent("Drafts", isDirectory: true)
    let recoveryStore = CanvasRecoveryStore(directoryURL: recoveryDir, draftsDirectoryURL: draftsDir)

    let appDelegate = CanvasAppDelegate(recoveryStore: recoveryStore)
    appDelegate.installMenu()
    defer { appDelegate.closeAllWindows() }
    try require(
        NSApp.mainMenu?.items.first?.title == "Canvas" &&
            NSApp.mainMenu?.items.first?.submenu?.item(withTitle: "Quit Canvas") != nil,
        "App menu did not use 'Canvas' / 'Quit Canvas' titles"
    )

    // 1. Blank-canvas workflow: New -> add shape + adjacent thought + connection -> inline draft flush on Save -> Undo/Redo across Save -> Reopen.
    appDelegate.newDocument(nil)
    guard let untitledDoc = appDelegate.activeNativeDocument(),
          let untitledWindow = untitledDoc.canvasView.window else {
        throw CheckFailure(description: "File -> New did not create an active CanvasNativeDocument window")
    }
    try require(
        untitledDoc.quietAutosaveInterval == 5.0 && untitledDoc.maxContinuousAutosaveInterval == 30.0,
        "Default coalesced autosave intervals must be 5s quiet and 30s continuous"
    )
    try require(
        untitledDoc.persistenceState == .untitled(isDirty: false, hasPendingDraft: false) &&
            !untitledWindow.isDocumentEdited &&
            untitledDoc.fileURL == nil,
        "Fresh untitled document should start clean with no fileURL"
    )

    let canvas = untitledDoc.canvasView
    canvas.insertShape(.rectangle)
    guard let firstNodeID = canvas.selectedNodeID else {
        throw CheckFailure(description: "Insert Rectangle did not select the new node")
    }
    try require(
        untitledDoc.persistenceState == .untitled(isDirty: true, hasPendingDraft: false) &&
            untitledWindow.isDocumentEdited,
        "Inserting a shape on an untitled canvas did not mark it dirty"
    )

    // Grow an adjacent thought via N -> Right Arrow -> inline typing -> Return commit.
    canvas.beginAdjacentThought()
    try require(
        untitledDoc.persistenceState == .untitled(isDirty: true, hasPendingDraft: true),
        "Adjacent thought chooser should report pending draft state"
    )
    func keyEvent(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], chars: String = "") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: untitledWindow.windowNumber,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: code
        )!
    }
    canvas.keyDown(with: keyEvent(124)) // Right arrow
    guard let thoughtEditor = canvas.inlineTextEditorView else {
        throw CheckFailure(description: "Adjacent thought did not open inline text editor")
    }
    thoughtEditor.string = "Second thought"
    thoughtEditor.keyDown(with: keyEvent(36)) // Return commits adjacent thought
    guard let secondNodeID = canvas.selectedNodeID, secondNodeID != firstNodeID else {
        throw CheckFailure(description: "Adjacent thought commit did not select the new thought")
    }
    _ = try untitledDoc.session.insertConnection(
        source: firstNodeID,
        sourceSide: .right,
        target: secondNodeID,
        targetSide: .left,
        label: "flow"
    )
    canvas.reloadFromSession(clearingUndoHistory: false)

    // Open a caption editor on the first shape and test invalid draft refusal (>2,000 graphemes) before valid Save.
    canvas.selectNode(firstNodeID)
    canvas.beginTextEditing()
    guard let captionEditor = canvas.inlineTextEditorView else {
        throw CheckFailure(description: "beginTextEditing did not open inline caption editor")
    }
    captionEditor.string = String(repeating: "x", count: 2_001)
    let firstSaveURL = tempRoot.appendingPathComponent("brainstorm.json")
    untitledDoc.saveDestinationProvider = { _ in firstSaveURL }

    do {
        _ = try untitledDoc.saveDocumentExplicitly()
        throw CheckFailure(description: "Save succeeded despite an invalid 2,001-grapheme inline draft")
    } catch is CanvasPersistenceError {}
    try require(
        !fm.fileExists(atPath: firstSaveURL.path) &&
            canvas.hasActiveInlineTextEditor &&
            captionEditor.string.count == 2_001,
        "Invalid draft Save wrote a file or truncated/dismissed the draft"
    )

    // Fix the caption in the still-open inline editor and invoke Save (which must flush the valid draft once, then save).
    captionEditor.string = "Root idea"
    appDelegate.saveDocument(nil)
    try require(
        !canvas.hasActiveInlineTextEditor &&
            untitledDoc.session.text(of: firstNodeID) == "Root idea" &&
            untitledDoc.fileURL?.standardizedFileURL == firstSaveURL.standardizedFileURL &&
            untitledDoc.persistenceState == .saved(hasPendingDraft: false) &&
            !untitledWindow.isDocumentEdited,
        "First Save did not flush the valid inline draft and promote the untitled document to Saved"
    )
    let savedDoc = try CanvasDocument(data: Data(contentsOf: firstSaveURL))
    let savedNodes = savedDoc.root["nodes"] as? [[String: Any]] ?? []
    let savedEdges = savedDoc.root["edges"] as? [[String: Any]] ?? []
    try require(
        (savedDoc.root["version"] as? Int) == 2 &&
            savedNodes.count == 2 &&
            savedEdges.count == 1 &&
            (savedNodes[0]["id"] as? String) == firstNodeID &&
            (savedNodes[1]["id"] as? String) == secondNodeID,
        "Saved JSON bytes did not preserve IDs, node order, and connection"
    )

    // Verify Undo/Redo across Save remains intact and marks the document as having pending changes eligible for autosave.
    try require(canvas.undoManager?.canUndo == true, "Save cleared the document UndoManager history")
    appDelegate.undoMove(nil) // Undoes the flushed "Root idea" caption edit
    try require(
        untitledDoc.session.text(of: firstNodeID) == nil &&
            untitledDoc.persistenceState == .changesPending(hasPendingDraft: false) &&
            untitledWindow.isDocumentEdited,
        "Undoing after Save did not restore previous text or mark changesPending for autosave"
    )
    appDelegate.redoMove(nil)
    try require(
        untitledDoc.session.text(of: firstNodeID) == "Root idea" &&
            untitledDoc.persistenceState == .saved(hasPendingDraft: false) &&
            !untitledWindow.isDocumentEdited,
        "Redoing back to the saved snapshot did not return state to Saved"
    )

    // Reopening the already-open file activates the existing document rather than creating a second writer.
    let reopenedSame = appDelegate.openDocument(firstSaveURL)
    try require(
        reopenedSame === untitledDoc && appDelegate.openNativeDocuments.count == 1,
        "Reopening an already-open file created a duplicate document writer"
    )
    print("PASS blank-canvas authoring, draft flush/refusal on Save, first-save promotion, Undo/Redo across Save, and single-writer reopen")

    // 2. Coalesced autosave & deterministic in-flight write races (SPEC §4 invariant 5 & §8).
    untitledDoc.quietAutosaveInterval = 0.02
    untitledDoc.maxContinuousAutosaveInterval = 0.08
    _ = try untitledDoc.session.move(firstNodeID, to: CanvasPosition(x: 42, y: 84))
    canvas.reloadFromSession(clearingUndoHistory: false)
    try require(
        untitledDoc.persistenceState == .changesPending(hasPendingDraft: false) &&
            untitledDoc.isAutosaveScheduled,
        "Committed move did not schedule coalesced autosave"
    )
    let waitDeadline = Date().addingTimeInterval(1.0)
    while untitledDoc.persistenceState != .saved(hasPendingDraft: false) && Date() < waitDeadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    try require(
        untitledDoc.persistenceState == .saved(hasPendingDraft: false),
        "Coalesced autosave timer did not save committed move to disk"
    )
    let autoSavedOnDisk = try CanvasDocument(data: Data(contentsOf: firstSaveURL))
    let autoSession = CanvasSession(document: autoSavedOnDisk)
    try require(
        autoSession.position(of: firstNodeID) == CanvasPosition(x: 42, y: 84),
        "Coalesced autosave did not write updated coordinates to disk"
    )
    untitledDoc.quietAutosaveInterval = 5.0
    untitledDoc.maxContinuousAutosaveInterval = 30.0

    // Pointer-drag preview isolation: dragging without mouseUp must NOT mutate session.revision or serialize
    // unconfirmed coordinates on timer fire, and Escape must restore the pre-drag position with unchanged disk/recovery bytes.
    let preDragRevision = untitledDoc.session.revision
    let preDragDiskBytes = try Data(contentsOf: firstSaveURL)
    let startWorldPos = untitledDoc.session.position(of: firstNodeID)!
    let startViewPt = canvas.viewPoint(forWorldPoint: CGPoint(x: startWorldPos.x + 20, y: startWorldPos.y + 20))
    let draggedViewPt = CGPoint(x: startViewPt.x + 60, y: startViewPt.y + 45)
    func mouseEvent(_ type: NSEvent.EventType, at location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(location, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: untitledWindow.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }
    canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: startViewPt))
    canvas.mouseDragged(with: mouseEvent(.leftMouseDragged, at: draggedViewPt))
    try require(
        canvas.hasActivePointerDrag &&
            untitledDoc.session.revision == preDragRevision &&
            untitledDoc.session.position(of: firstNodeID) == startWorldPos &&
            !untitledDoc.isAutosaveScheduled,
        "Pointer mouseDragged prematurely mutated CanvasSession or scheduled autosave before mouseUp"
    )
    untitledDoc.triggerScheduledAutosaveNow()
    try require(
        (try Data(contentsOf: firstSaveURL)) == preDragDiskBytes &&
            !fm.fileExists(atPath: recoveryStore.envelopeURL(for: untitledDoc.sessionID).path),
        "Firing autosave timer mid-drag serialized an unconfirmed pointer-drag preview"
    )
    // Escape cancels the active pointer drag without history or disk changes:
    canvas.keyDown(with: keyEvent(53))
    try require(
        !canvas.hasActivePointerDrag &&
            untitledDoc.session.revision == preDragRevision &&
            untitledDoc.session.position(of: firstNodeID) == startWorldPos &&
            (try Data(contentsOf: firstSaveURL)) == preDragDiskBytes &&
            !fm.fileExists(atPath: recoveryStore.envelopeURL(for: untitledDoc.sessionID).path),
        "Escape during pointer drag did not cancel the preview cleanly"
    )

    // Deterministic in-flight write race: delay revision N write, edit again (revision N+1), complete revision N write,
    // verify disk has revision N while document stays changesPending, then complete revision N+1 write.
    var stagedWrites: [(rev: UInt64, gen: UInt64, run: () -> Void)] = []
    untitledDoc.writeInterceptor = { rev, gen, execute in
        stagedWrites.append((rev, gen, execute))
    }
    _ = try untitledDoc.session.move(firstNodeID, to: CanvasPosition(x: 100, y: 200))
    let revA = untitledDoc.session.revision
    untitledDoc.triggerScheduledAutosaveNow()
    try require(
        stagedWrites.count == 1 &&
            stagedWrites[0].rev == revA &&
            untitledDoc.persistenceState == .saving(hasPendingDraft: false),
        "Write interceptor did not stage revision A in .saving state"
    )

    // Edit again while revision A is in flight!
    _ = try untitledDoc.session.move(firstNodeID, to: CanvasPosition(x: 300, y: 400))
    let revB = untitledDoc.session.revision
    try require(revB > revA, "Second edit during in-flight write did not advance session revision")

    // Complete first write (revision A):
    stagedWrites.removeFirst().run()
    let diskAfterFirst = try CanvasSession(document: CanvasDocument(data: Data(contentsOf: firstSaveURL)))
    try require(
        diskAfterFirst.position(of: firstNodeID) == CanvasPosition(x: 100, y: 200) &&
            untitledDoc.acknowledgedRevision == revA &&
            untitledDoc.persistenceState == .changesPending(hasPendingDraft: false) &&
            untitledDoc.isAutosaveScheduled,
        "Completing older snapshot failed to write revA or falsely marked newer revB as Saved"
    )

    // Now let the follow-up autosave for revision B run without interception:
    untitledDoc.writeInterceptor = nil
    untitledDoc.triggerScheduledAutosaveNow()
    let diskAfterSecond = try CanvasSession(document: CanvasDocument(data: Data(contentsOf: firstSaveURL)))
    try require(
        diskAfterSecond.position(of: firstNodeID) == CanvasPosition(x: 300, y: 400) &&
            untitledDoc.acknowledgedRevision == revB &&
            untitledDoc.persistenceState == .saved(hasPendingDraft: false),
        "Follow-up autosave after in-flight edit did not persist latest revision B"
    )

    // Edit -> in-flight save -> Undo-to-baseline regression:
    // Baseline on disk is (300, 400). Edit via keyboard arrow (301, 400), stage save of (301, 400),
    // Undo back to (300, 400) while (301, 400) is in flight, then complete the in-flight save of (301, 400).
    // Because disk now has (301, 400) while session has (300, 400), document MUST be .changesPending (not .saved),
    // and the follow-up autosave must write (300, 400) back to disk!
    canvas.reloadFromSession(clearingUndoHistory: false)
    canvas.selectNode(firstNodeID)
    untitledDoc.writeInterceptor = { rev, gen, execute in
        stagedWrites.append((rev, gen, execute))
    }
    canvas.keyDown(with: keyEvent(124)) // Right arrow moves firstNodeID to (301, 400)
    let revMoved = untitledDoc.session.revision
    try require(
        untitledDoc.session.position(of: firstNodeID) == CanvasPosition(x: 301, y: 400),
        "Right arrow did not move node to (301, 400)"
    )
    untitledDoc.triggerScheduledAutosaveNow()
    try require(stagedWrites.count == 1 && stagedWrites[0].rev == revMoved, "Did not stage save of (301, 400)")

    // Undo back to baseline (300, 400) while (301, 400) save is still in flight:
    appDelegate.undoMove(nil)
    let revUndoneToBaseline = untitledDoc.session.revision
    try require(
        revUndoneToBaseline > revMoved &&
            untitledDoc.session.position(of: firstNodeID) == CanvasPosition(x: 300, y: 400),
        "Undo during in-flight save did not return session to (300, 400)"
    )

    // Complete the in-flight save of (301, 400):
    stagedWrites.removeFirst().run()
    let diskAfterMovedSave = try CanvasSession(document: CanvasDocument(data: Data(contentsOf: firstSaveURL)))
    try require(
        diskAfterMovedSave.position(of: firstNodeID) == CanvasPosition(x: 301, y: 400) &&
            untitledDoc.acknowledgedRevision == revMoved &&
            untitledDoc.hasUnacknowledgedCommittedChanges &&
            untitledDoc.persistenceState == .changesPending(hasPendingDraft: false) &&
            untitledDoc.isAutosaveScheduled,
        "Completing (301, 400) after in-flight Undo to (300, 400) falsely reported Saved while disk still had (301, 400)"
    )

    // Now run the follow-up autosave for the undone (300, 400) state:
    untitledDoc.writeInterceptor = nil
    untitledDoc.triggerScheduledAutosaveNow()
    let diskAfterUndoneSave = try CanvasSession(document: CanvasDocument(data: Data(contentsOf: firstSaveURL)))
    try require(
        diskAfterUndoneSave.position(of: firstNodeID) == CanvasPosition(x: 300, y: 400) &&
            untitledDoc.acknowledgedRevision == revUndoneToBaseline &&
            !untitledDoc.hasUnacknowledgedCommittedChanges &&
            untitledDoc.persistenceState == .saved(hasPendingDraft: false),
        "Follow-up autosave after Undo-to-baseline did not write (300, 400) back to disk"
    )

    // Stale source-generation race: stage an autosave on firstSaveURL, perform Save As to secondSaveURL, then run the staged write.
    untitledDoc.writeInterceptor = { rev, gen, execute in
        stagedWrites.append((rev, gen, execute))
    }
    _ = try untitledDoc.session.move(firstNodeID, to: CanvasPosition(x: 500, y: 600))
    untitledDoc.triggerScheduledAutosaveNow()
    try require(stagedWrites.count == 1, "Expected staged write before Save As")
    let staleWrite = stagedWrites.removeFirst()

    untitledDoc.writeInterceptor = nil
    let secondSaveURL = tempRoot.appendingPathComponent("brainstorm-save-as.json")
    _ = try untitledDoc.saveDocumentAs(to: secondSaveURL)
    let firstFileBytesBeforeStale = try Data(contentsOf: firstSaveURL)
    staleWrite.run()
    let firstFileBytesAfterStale = try Data(contentsOf: firstSaveURL)
    try require(
        untitledDoc.fileURL?.standardizedFileURL == secondSaveURL.standardizedFileURL &&
            untitledDoc.persistenceState == .saved(hasPendingDraft: false) &&
            firstFileBytesBeforeStale == firstFileBytesAfterStale,
        "Stale-generation write completion overwrote old file or reverted Save As destination"
    )

    // Completion-delayed-beyond-deadline regression: if NSDocument's completion callback is delayed past
    // synchronousWaitTimeout, never mark Saved or allow closing until the actual completion callback fires.
    untitledDoc.quietAutosaveInterval = 5.0
    untitledDoc.maxContinuousAutosaveInterval = 30.0
    untitledDoc.synchronousWaitTimeout = 0.02
    var delayedCompletionCallback: (() -> Void)?
    untitledDoc.saveCompletionDelayHook = { complete in
        delayedCompletionCallback = complete
    }
    _ = try untitledDoc.session.move(firstNodeID, to: CanvasPosition(x: 505, y: 605))
    let delayedRev = untitledDoc.session.revision
    do {
        _ = try untitledDoc.saveDocumentExplicitly()
        throw CheckFailure(description: "Save returned success before delayed NSDocument completion callback fired")
    } catch is CanvasPersistenceError {}
    try require(
        delayedCompletionCallback != nil &&
            untitledDoc.isSavingInFlight &&
            untitledDoc.persistenceState == .saving(hasPendingDraft: false) &&
            untitledDoc.acknowledgedRevision < delayedRev &&
            !untitledDoc.shouldCloseDocument(),
        "Deadline expiry falsely marked document Saved or permitted closing while NSDocument completion was still pending"
    )
    untitledDoc.saveCompletionDelayHook = nil
    untitledDoc.synchronousWaitTimeout = 5.0
    delayedCompletionCallback?()
    try require(
        !untitledDoc.isSavingInFlight &&
            untitledDoc.acknowledgedRevision == delayedRev &&
            untitledDoc.persistenceState == .saved(hasPendingDraft: false),
        "Delayed NSDocument completion callback did not acknowledge save once invoked"
    )
    print("PASS coalesced 5s/30s autosave, in-flight edit race, and stale-generation Save As isolation")

    // 3. External writer conflict detection (modified & deleted), pause of autosave, Keep Editing, Reload from Disk, and Save As.
    _ = try untitledDoc.session.move(firstNodeID, to: CanvasPosition(x: 510, y: 610))
    // Modify secondSaveURL externally through a non-cooperating writer before autosave runs:
    var externalRoot = try CanvasDocument(data: Data(contentsOf: secondSaveURL)).root
    var externalNodes = externalRoot["nodes"] as! [[String: Any]]
    externalNodes[0]["x"] = -999.0
    externalRoot["nodes"] = externalNodes
    let externalBytes = try CanvasDocument.encode(externalRoot)
    try externalBytes.write(to: secondSaveURL, options: .atomic)

    untitledDoc.triggerScheduledAutosaveNow()
    let diskBytesAfterConflict = try Data(contentsOf: secondSaveURL)
    try require(
        diskBytesAfterConflict == externalBytes &&
            untitledDoc.persistenceState.isAutosavePaused &&
            untitledDoc.conflictReason != nil &&
            untitledDoc.session.position(of: firstNodeID) == CanvasPosition(x: 510, y: 610),
        "External file change was overwritten or failed to pause autosave and retain local edits"
    )

    // Keep Editing leaves conflict active and autosave paused:
    _ = try untitledDoc.applyConflictDecision(.keepEditing)
    try require(
        untitledDoc.conflictReason != nil && untitledDoc.persistenceState.isAutosavePaused,
        "Keep Editing cleared conflict or resumed autosave"
    )

    // Unconfirmed Reload from Disk is a no-op:
    let didReloadUnconfirmed = try untitledDoc.reloadFromDisk(confirmed: false)
    try require(
        !didReloadUnconfirmed && untitledDoc.session.position(of: firstNodeID) == CanvasPosition(x: 510, y: 610),
        "Unconfirmed Reload from Disk discarded local edits"
    )
    // Reload from Disk must refuse if the pre-reload recovery write fails or is delayed beyond the deadline,
    // keeping local graph, active text draft, conflict state, and undo history intact:
    canvas.reloadFromSession(clearingUndoHistory: false)
    canvas.selectNode(firstNodeID)
    canvas.beginTextEditing()
    canvas.inlineTextEditorView?.string = "Draft before reload"
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recoveryDir.path)
    do {
        _ = try untitledDoc.reloadFromDisk(confirmed: true)
        throw CheckFailure(description: "reloadFromDisk succeeded despite failing to write pre-reload recovery")
    } catch {}
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryDir.path)
    try require(
        untitledDoc.conflictReason != nil &&
            untitledDoc.session.position(of: firstNodeID) == CanvasPosition(x: 510, y: 610) &&
            canvas.hasActiveInlineTextEditor &&
            canvas.inlineTextEditorView?.string == "Draft before reload" &&
            canvas.undoManager?.canUndo == true,
        "Failed pre-reload recovery write discarded local graph, active text draft, or undo history"
    )

    // Delayed recovery completion during reloadFromDisk must also refuse without discarding local work:
    var delayedReloadRecovery: (() -> Void)?
    untitledDoc.synchronousWaitTimeout = 0.02
    untitledDoc.saveCompletionDelayHook = { complete in
        delayedReloadRecovery = complete
    }
    do {
        _ = try untitledDoc.reloadFromDisk(confirmed: true)
        throw CheckFailure(description: "reloadFromDisk succeeded before delayed recovery completion fired")
    } catch {}
    try require(
        delayedReloadRecovery != nil &&
            untitledDoc.isRecoveryWriteInFlight &&
            untitledDoc.conflictReason != nil &&
            untitledDoc.session.position(of: firstNodeID) == CanvasPosition(x: 510, y: 610) &&
            canvas.hasActiveInlineTextEditor &&
            canvas.inlineTextEditorView?.string == "Draft before reload" &&
            canvas.undoManager?.canUndo == true,
        "Delayed pre-reload recovery completion discarded local graph, draft, or undo history"
    )
    untitledDoc.saveCompletionDelayHook = nil
    untitledDoc.synchronousWaitTimeout = 5.0
    delayedReloadRecovery?()

    // Confirmed Reload from Disk saves an independent recovery backup first, loads external disk bytes, clears conflict, and resets undo history:
    let didReloadConfirmed = try untitledDoc.reloadFromDisk(confirmed: true)
    guard let preReloadBackupID = untitledDoc.lastPreReloadRecoverySessionID else {
        throw CheckFailure(description: "Confirmed Reload from Disk did not record an independent pre-reload recovery session ID")
    }
    try require(
        preReloadBackupID != untitledDoc.sessionID &&
            didReloadConfirmed &&
            untitledDoc.conflictReason == nil &&
            untitledDoc.persistenceState == .saved(hasPendingDraft: false) &&
            untitledDoc.session.position(of: firstNodeID) == CanvasPosition(x: -999.0, y: 605) &&
            !canvas.hasActiveInlineTextEditor &&
            canvas.undoManager?.canUndo == false &&
            fm.fileExists(atPath: recoveryStore.envelopeURL(for: preReloadBackupID).path) &&
            fm.fileExists(atPath: recoveryStore.draftURL(for: preReloadBackupID).path),
        "Confirmed Reload from Disk did not adopt external file, clear conflict, reset history, or write independent recovery backup"
    )

    // Conflict -> Save As resolution:
    _ = try untitledDoc.session.move(firstNodeID, to: CanvasPosition(x: 777, y: 888))
    // Externally delete secondSaveURL to trigger missing-source conflict:
    try fm.removeItem(at: secondSaveURL)
    untitledDoc.triggerScheduledAutosaveNow()
    try require(
        untitledDoc.conflictReason == .missingOrReplaced &&
            !fm.fileExists(atPath: secondSaveURL.path),
        "Deleting source externally did not enter .missingOrReplaced conflict or recreated deleted file"
    )
    let conflictSaveAsURL = tempRoot.appendingPathComponent("conflict-preserved.json")
    _ = try untitledDoc.applyConflictDecision(.saveAs(conflictSaveAsURL))
    try require(
        untitledDoc.conflictReason == nil &&
            untitledDoc.fileURL?.standardizedFileURL == conflictSaveAsURL.standardizedFileURL &&
            untitledDoc.persistenceState == .saved(hasPendingDraft: false) &&
            !fm.fileExists(atPath: secondSaveURL.path),
        "Conflict Save As did not promote new destination or recreated deleted original source"
    )
    try require(
        fm.fileExists(atPath: recoveryStore.envelopeURL(for: preReloadBackupID).path) &&
            fm.fileExists(atPath: recoveryStore.draftURL(for: preReloadBackupID).path),
        "Subsequent Save As cleanup deleted the independent pre-reload recovery backup"
    )
    print("PASS external writer conflict detection (modified & deleted), paused autosave, Keep Editing, Reload from Disk, and Save As")

    // 4. Write failures (read-only file/directory, recovery failure separation) and Close/Quit guards.
    let readOnlyURL = tempRoot.appendingPathComponent("readonly.json")
    try Data(contentsOf: conflictSaveAsURL).write(to: readOnlyURL)
    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyURL.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnlyURL.path) }

    guard let readOnlyDoc = appDelegate.openDocument(readOnlyURL) else {
        throw CheckFailure(description: "Could not open read-only canvas file")
    }
    let readOnlyInitialBytes = try Data(contentsOf: readOnlyURL)
    let readOnlyInitialRoot = readOnlyDoc.session.root
    try require(
        readOnlyDoc.session.isReadOnly &&
            readOnlyDoc.canvasView.isReadOnly &&
            readOnlyDoc.persistenceState == .readOnly(
                reason: "File or folder is read-only; use Save As to save a copy.",
                hasPendingDraft: false
            ),
        "Read-only file did not open in .readOnly state with session/view isReadOnly=true"
    )
    // Verify mutating menu commands are disabled while Save As, Export PNG, Select All, and Style remain enabled:
    if let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
       let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
       let insertMenu = NSApp.mainMenu?.item(withTitle: "Insert")?.submenu {
        let saveItem = fileMenu.item(withTitle: "Save")!
        let saveAsItem = fileMenu.item(withTitle: "Save As…")!
        let exportItem = fileMenu.item(withTitle: "Export PNG…")!
        let insertRectItem = insertMenu.item(withTitle: "Rectangle")!
        let dupItem = editMenu.item(withTitle: "Duplicate")!
        let delItem = editMenu.item(withTitle: "Delete")!
        let lockItem = editMenu.item(withTitle: "Lock")!
        let styleItem = editMenu.item(withTitle: "Style…")!
        try require(
            !appDelegate.validateMenuItem(saveItem) &&
                appDelegate.validateMenuItem(saveAsItem) &&
                appDelegate.validateMenuItem(exportItem) &&
                !appDelegate.validateMenuItem(insertRectItem) &&
                !appDelegate.validateMenuItem(dupItem) &&
                !appDelegate.validateMenuItem(delItem) &&
                !appDelegate.validateMenuItem(lockItem) &&
                appDelegate.validateMenuItem(styleItem),
            "Read-only menu validation did not disable Save/Insert/Edit mutations while keeping Save As/Export/Style enabled"
        )
    }
    // Verify keyboard and pointer mutation attempts on readOnlyDoc leave graph, revision, undo history, and disk bytes unchanged:
    let roCanvas = readOnlyDoc.canvasView
    let roWin = roCanvas.window!
    roCanvas.selectNode(firstNodeID)
    let roNodePos = readOnlyDoc.session.position(of: firstNodeID)!
    let roPt = roCanvas.viewPoint(forWorldPoint: CGPoint(x: roNodePos.x + 20, y: roNodePos.y + 20))
    roCanvas.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: roCanvas.convert(roPt, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: roWin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
    )!)
    roCanvas.mouseDragged(with: NSEvent.mouseEvent(
        with: .leftMouseDragged, location: roCanvas.convert(CGPoint(x: roPt.x + 50, y: roPt.y + 50), to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: roWin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
    )!)
    roCanvas.mouseUp(with: NSEvent.mouseEvent(
        with: .leftMouseUp, location: roCanvas.convert(CGPoint(x: roPt.x + 50, y: roPt.y + 50), to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: roWin.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1.0
    )!)
    for (code, chars, mods) in [
        (UInt16(15), "r", NSEvent.ModifierFlags([])),
        (UInt16(17), "t", NSEvent.ModifierFlags([])),
        (UInt16(45), "n", NSEvent.ModifierFlags([])),
        (UInt16(5), "g", NSEvent.ModifierFlags([])),
        (UInt16(8), "c", NSEvent.ModifierFlags([])),
        (UInt16(51), "\u{7f}", NSEvent.ModifierFlags([])),
        (UInt16(124), "", NSEvent.ModifierFlags([])),
        (UInt16(2), "d", NSEvent.ModifierFlags([.command])),
        (UInt16(37), "l", NSEvent.ModifierFlags([.command]))
    ] {
        roCanvas.keyDown(with: NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
            windowNumber: roWin.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code
        )!)
    }
    do {
        _ = try readOnlyDoc.session.move(firstNodeID, to: CanvasPosition(x: 10, y: 10))
        throw CheckFailure(description: "Direct session.move succeeded on a read-only document")
    } catch is CanvasDocumentError {}
    do {
        _ = try readOnlyDoc.saveDocumentExplicitly()
        throw CheckFailure(description: "Explicit in-place Save succeeded on a read-only source")
    } catch is CanvasPersistenceError {}
    try require(
        readOnlyDoc.session.revision == 0 &&
            NSDictionary(dictionary: readOnlyDoc.session.root).isEqual(to: readOnlyInitialRoot) &&
            roCanvas.undoManager?.canUndo == false &&
            !roCanvas.hasActiveInlineTextEditor &&
            !roCanvas.hasGeometryPreview &&
            (try Data(contentsOf: readOnlyURL)) == readOnlyInitialBytes,
        "Pointer or keyboard mutation attempt modified read-only graph, history, or disk bytes"
    )
    // Save As to a writable destination promotes readOnlyDoc to an editable document:
    let promotedWritableURL = tempRoot.appendingPathComponent("promoted-writable.json")
    _ = try readOnlyDoc.saveDocumentAs(to: promotedWritableURL)
    try require(
        !readOnlyDoc.session.isReadOnly &&
            !roCanvas.isReadOnly &&
            readOnlyDoc.persistenceState == .saved(hasPendingDraft: false),
        "Save As from read-only document did not promote it to writable .saved state"
    )
    _ = try readOnlyDoc.session.move(firstNodeID, to: CanvasPosition(x: 10, y: 10))
    try require(
        readOnlyDoc.session.position(of: firstNodeID) == CanvasPosition(x: 10, y: 10) &&
            readOnlyDoc.persistenceState == .changesPending(hasPendingDraft: false),
        "Promoted writable document did not allow editing after Save As"
    )
    // Make conflictSaveAsURL unwritable after opening to exercise .saveFailed on an editable connected document:
    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: conflictSaveAsURL.path)
    _ = try untitledDoc.session.move(firstNodeID, to: CanvasPosition(x: 900, y: 900))
    untitledDoc.triggerScheduledAutosaveNow()
    let failedState = untitledDoc.persistenceState
    if case .saveFailed = failedState {} else {
        throw CheckFailure(description: "Unwritable destination did not transition to .saveFailed (got \(failedState))")
    }
    try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: conflictSaveAsURL.path)

    // Separate recovery write failure from source write success:
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recoveryDir.path)
    do {
        try untitledDoc.writeRecoverySnapshotNow()
        throw CheckFailure(description: "Recovery write succeeded in an unwritable recovery directory")
    } catch {}
    try require(
        untitledDoc.lastRecoveryError != nil,
        "Failed recovery write did not record lastRecoveryError separately"
    )
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryDir.path)

    // Exercise Close / Quit guards: Cancel keeps window open; Save with cancelled panel keeps window open; Keep Recovery writes recovery and closes.
    untitledDoc.closeDecisionProvider = { _ in .cancel }
    try require(
        !appDelegate.windowShouldClose(untitledWindow) &&
            appDelegate.applicationShouldTerminate(NSApp) == .terminateCancel,
        "Cancel close decision allowed window close or app termination"
    )
    untitledDoc.saveDestinationProvider = { _ in nil } // Simulate cancelled Save panel
    untitledDoc.closeDecisionProvider = { _ in .save(destinationURL: nil) }
    // Promoted readOnlyDoc has unsaved changes; put it into conflict so .save(nil) requires Save As panel,
    // then cancel the panel to verify close is refused:
    readOnlyDoc.saveDestinationProvider = { _ in nil }
    try externalBytes.write(to: promotedWritableURL, options: .atomic)
    _ = readOnlyDoc.checkExternalSourceStatus()
    readOnlyDoc.closeDecisionProvider = { _ in .save(destinationURL: nil) }
    try require(
        !readOnlyDoc.shouldCloseDocument(),
        "Cancelled Save As panel during close allowed closing with unsaved work"
    )

    // Save untitledDoc cleanly and close readOnlyDoc with .discardChanges:
    _ = try untitledDoc.saveDocumentExplicitly()
    try require(
        untitledDoc.persistenceState == .saved(hasPendingDraft: false) &&
            appDelegate.windowShouldClose(untitledWindow),
        "Clean saved document was refused closing"
    )
    readOnlyDoc.closeDecisionProvider = { _ in .discardChanges }
    try require(
        readOnlyDoc.shouldCloseDocument(),
        "Explicit discardChanges did not allow closing"
    )
    appDelegate.closeAllWindows()
    print("PASS read-only handling, write failure retention, separate recovery error tracking, and Close/Quit lifecycle guards")

    // 5. Launch recovery: untitled + active text draft, connected unchanged source, connected changed source -> untitled, and corrupt recovery.
    let launchRecoveryDir = tempRoot.appendingPathComponent("LaunchRecovery", isDirectory: true)
    let launchDraftsDir = tempRoot.appendingPathComponent("LaunchDrafts", isDirectory: true)
    let launchStore = CanvasRecoveryStore(directoryURL: launchRecoveryDir, draftsDirectoryURL: launchDraftsDir)

    // 5a: Untitled document with committed node AND active inline adjacent-thought text draft.
    let sessionA = try CanvasNativeDocument(untitledDisplayName: "Untitled Brainstorm", recoveryStore: launchStore)
    let appA = CanvasAppDelegate(recoveryStore: launchStore)
    _ = appA.showNativeDocument(sessionA)
    sessionA.canvasView.insertShape(.rectangle)
    let rootShapeID = sessionA.canvasView.selectedNodeID!
    sessionA.canvasView.beginAdjacentThought()
    sessionA.canvasView.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: sessionA.canvasView.window!.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125 // Down arrow
    )!)
    sessionA.canvasView.inlineTextEditorView?.string = "Uncommitted active draft text"
    try sessionA.writeRecoverySnapshotNow()

    // Verify the recovery envelope does NOT duplicate the committed nodes JSON (which lives in NSDocument's autosavedContentsFileURL):
    let envRawString = String(data: try Data(contentsOf: launchStore.envelopeURL(for: sessionA.sessionID)), encoding: .utf8) ?? ""
    try require(
        !envRawString.contains("\"nodes\"") &&
            sessionA.autosavedContentsFileURL != nil &&
            fm.fileExists(atPath: sessionA.autosavedContentsFileURL!.path),
        "Recovery envelope duplicated committed snapshot instead of referencing NSDocument's autosavedContentsFileURL"
    )

    // 5b: Connected document whose source on disk remains unchanged.
    let connectedSourceB = tempRoot.appendingPathComponent("connected-unchanged.json")
    try Data(contentsOf: conflictSaveAsURL).write(to: connectedSourceB)
    let originalBytesB = try Data(contentsOf: connectedSourceB)
    let sessionB = try CanvasNativeDocument(opening: connectedSourceB, recoveryStore: launchStore)
    _ = appA.showNativeDocument(sessionB)
    _ = try sessionB.session.setText(firstNodeID, to: "Recovered connected edit")
    try sessionB.writeRecoverySnapshotNow()

    // 5c: Connected document whose source on disk is modified externally before relaunch.
    let connectedSourceC = tempRoot.appendingPathComponent("connected-changed.json")
    try Data(contentsOf: conflictSaveAsURL).write(to: connectedSourceC)
    let sessionC = try CanvasNativeDocument(opening: connectedSourceC, recoveryStore: launchStore)
    _ = appA.showNativeDocument(sessionC)
    _ = try sessionC.session.setText(firstNodeID, to: "Recovered before external change")
    try sessionC.writeRecoverySnapshotNow()
    // External writer modifies connectedSourceC before relaunch:
    try externalBytes.write(to: connectedSourceC, options: .atomic)

    // 5d: Corrupt recovery envelope file.
    let corruptEnvURL = launchRecoveryDir.appendingPathComponent("\(UUID().uuidString).envelope.json")
    try Data("{corrupt json".utf8).write(to: corruptEnvURL)

    // Simulate termination of appA and relaunch in appB:
    appA.closeAllWindows()

    let appB = CanvasAppDelegate(recoveryStore: launchStore)
    defer { appB.closeAllWindows() }
    appB.recoveryLaunchDecisionProvider = { inspection in
        if case .corrupt = inspection { return .discard }
        return .restore
    }
    let restoredDocs = appB.processPendingRecoveriesOnLaunch()
    try require(
        restoredDocs.count == 3 &&
            appB.corruptRecoveryNotices.count == 1 &&
            !fm.fileExists(atPath: corruptEnvURL.path),
        "Launch recovery did not restore all 3 valid sessions and discard the 1 corrupt recovery"
    )

    // Verify 5a restored both the committed shape AND the active inline text draft:
    guard let restoredA = restoredDocs.first(where: { $0.sessionID == sessionA.sessionID }) else {
        throw CheckFailure(description: "Missing restored untitled session A")
    }
    try require(
        restoredA.fileURL == nil &&
            restoredA.session.position(of: rootShapeID) != nil &&
            restoredA.canvasView.hasAdjacentThoughtDraft &&
            restoredA.canvasView.adjacentThoughtDraftText == "Uncommitted active draft text",
        "Untitled recovery did not restore both committed node and active inline adjacent-thought draft"
    )
    // Saving restoredA to disk cleans up both NSDocument's draft file and the recovery envelope:
    let savedRestoredAURL = tempRoot.appendingPathComponent("restored-a-saved.json")
    _ = try restoredA.saveDocumentAs(to: savedRestoredAURL)
    try require(
        restoredA.autosavedContentsFileURL == nil &&
            !fm.fileExists(atPath: launchStore.envelopeURL(for: restoredA.sessionID).path) &&
            !fm.fileExists(atPath: launchStore.draftURL(for: restoredA.sessionID).path),
        "Saving restored untitled document did not clean up NSDocument draft and recovery envelope"
    )

    // Verify 5b restored connected to connectedSourceB without overwriting connectedSourceB on disk yet:
    guard let restoredB = restoredDocs.first(where: { $0.sessionID == sessionB.sessionID }) else {
        throw CheckFailure(description: "Missing restored connected session B")
    }
    try require(
        restoredB.fileURL?.standardizedFileURL == connectedSourceB.standardizedFileURL &&
            restoredB.session.text(of: firstNodeID) == "Recovered connected edit" &&
            restoredB.persistenceState == .changesPending(hasPendingDraft: false) &&
            (try Data(contentsOf: connectedSourceB)) == originalBytesB,
        "Connected recovery overwrote source on launch or lost recovered edit"
    )

    // Verify 5c restored as a separate Untitled document because connectedSourceC changed on disk:
    guard let restoredC = restoredDocs.first(where: { $0.sessionID == sessionC.sessionID }) else {
        throw CheckFailure(description: "Missing restored session C")
    }
    try require(
        restoredC.fileURL == nil &&
            restoredC.displayNameTitle == "Recovered — connected-changed" &&
            restoredC.session.text(of: firstNodeID) == "Recovered before external change" &&
            (try Data(contentsOf: connectedSourceC)) == externalBytes,
        "Changed-source recovery did not restore as a separate Untitled document or modified the changed source file"
    )
    print("PASS launch recovery: NSDocument draft + envelope without snapshot duplication, active text draft restore, unchanged vs changed source, and corrupt discard")
    appB.closeAllWindows()

    // 6. Explicit v1 -> v2 conversion copy preserves original v1 source, baseline, dirty state, and undo history.
    let v1FixtureURL = repository.appendingPathComponent("shared/fixtures/v1/compatibility.json")
    let v1WorkingURL = tempRoot.appendingPathComponent("v1-working.json")
    let v1OriginalBytes = try Data(contentsOf: v1FixtureURL)
    try v1OriginalBytes.write(to: v1WorkingURL)

    guard let v1Doc = appB.openDocument(v1WorkingURL) else {
        throw CheckFailure(description: "Could not open temporary v1 compatibility document")
    }
    _ = try v1Doc.session.setText("triangle", to: "V1 local edit")
    let v2CopyURL = tempRoot.appendingPathComponent("v1-converted-copy.json")
    try v1Doc.saveVersion2Copy(to: v2CopyURL)

    let v2CopyLoaded = try CanvasDocument(data: Data(contentsOf: v2CopyURL))
    try require(
        (v2CopyLoaded.root["version"] as? Int) == 2 &&
            ((v2CopyLoaded.root["future"] as? [String: Any])?["sequence"] as? NSNumber)?.int64Value == 9_007_199_254_740_993 &&
            (v1Doc.session.root["version"] as? Int) == 1 &&
            v1Doc.fileURL?.standardizedFileURL == v1WorkingURL.standardizedFileURL &&
            v1Doc.persistenceState == .changesPending(hasPendingDraft: false) &&
            (try Data(contentsOf: v1WorkingURL)) == v1OriginalBytes,
        "Explicit v1->v2 copy mutated original v1 document version, source identity, dirty state, or original bytes"
    )
    // Choosing the opened v1 file (or a hardlink alias to it) as the version-2 copy destination must be refused
    // without overwriting the v1 file or changing its version/dirty state:
    let v1HardlinkAliasURL = tempRoot.appendingPathComponent("v1-hardlink-alias.json")
    try fm.linkItem(at: v1WorkingURL, to: v1HardlinkAliasURL)
    for badCopyTarget in [v1WorkingURL, v1HardlinkAliasURL] {
        do {
            try v1Doc.saveVersion2Copy(to: badCopyTarget)
            throw CheckFailure(description: "saveVersion2Copy allowed overwriting the current v1 source via \(badCopyTarget.lastPathComponent)")
        } catch is CanvasPersistenceError {}
    }
    try require(
        (try Data(contentsOf: v1WorkingURL)) == v1OriginalBytes &&
            (v1Doc.session.root["version"] as? Int) == 1 &&
            v1Doc.persistenceState == .changesPending(hasPendingDraft: false),
        "Refused same-file saveVersion2Copy mutated original v1 bytes or state"
    )

    // Choosing the conflicted source itself (or a hardlink alias to it) in Save As must be refused
    // so Save As cannot force-overwrite an externally modified file:
    try externalBytes.write(to: v1WorkingURL, options: .atomic)
    _ = v1Doc.checkExternalSourceStatus()
    try require(v1Doc.conflictReason != nil, "Expected external conflict on v1WorkingURL")
    let conflictedHardlinkURL = tempRoot.appendingPathComponent("v1-conflicted-alias.json")
    try? fm.removeItem(at: conflictedHardlinkURL)
    try fm.linkItem(at: v1WorkingURL, to: conflictedHardlinkURL)
    for badSaveAsTarget in [v1WorkingURL, conflictedHardlinkURL] {
        do {
            _ = try v1Doc.saveDocumentAs(to: badSaveAsTarget)
            throw CheckFailure(description: "Conflicted saveDocumentAs allowed force-overwriting current source via \(badSaveAsTarget.lastPathComponent)")
        } catch is CanvasPersistenceError {}
    }
    try require(
        (try Data(contentsOf: v1WorkingURL)) == externalBytes &&
            v1Doc.conflictReason != nil &&
            v1Doc.persistenceState.isAutosavePaused,
        "Refused same-file Save As during conflict modified external bytes or cleared conflict"
    )
    // Restore v1OriginalBytes and reload so we can test normal in-place v1 save:
    try v1OriginalBytes.write(to: v1WorkingURL, options: .atomic)
    _ = try v1Doc.reloadFromDisk(confirmed: true)
    _ = try v1Doc.session.setText("triangle", to: "V1 local edit")
    // Saving the v1 document in-place keeps it version 1:
    _ = try v1Doc.saveDocumentExplicitly()
    let v1SavedLoaded = try CanvasDocument(data: Data(contentsOf: v1WorkingURL))
    try require(
        (v1SavedLoaded.root["version"] as? Int) == 1 &&
            v1Doc.persistenceState == .saved(hasPendingDraft: false),
        "Saving v1 document after v2 copy export did not preserve version 1"
    )
    print("PASS explicit v1->v2 copy conversion and preserved v1 in-place save")

    // 7. Multi-window Quit cancellation regression: if Window 1 approves termination (.keepRecovery or .discardChanges)
    // and Window 2 cancels (.cancel), Window 1 must remain open, active (!isClosed), and able to edit and save to disk/recovery.
    appB.newDocument(nil)
    guard let secondWinDoc = appB.activeNativeDocument(), secondWinDoc !== v1Doc else {
        throw CheckFailure(description: "Could not create second window for multi-window Quit test")
    }
    _ = try v1Doc.session.setText("triangle", to: "Window 1 unsaved before cancelled Quit")
    secondWinDoc.canvasView.insertShape(.ellipse)
    v1Doc.closeDecisionProvider = { _ in .discardChanges }
    secondWinDoc.closeDecisionProvider = { _ in .cancel }

    try require(
        appB.applicationShouldTerminate(NSApp) == .terminateCancel,
        "applicationShouldTerminate did not cancel when second window returned .cancel"
    )
    try require(
        !v1Doc.isClosed &&
            !secondWinDoc.isClosed &&
            v1Doc.session.text(of: "triangle") == "Window 1 unsaved before cancelled Quit",
        "Cancelled Quit prematurely tore down or marked closed the first window"
    )
    // Edit and save Window 1 after the cancelled Quit to prove its persistence and recovery remain active:
    _ = try v1Doc.session.setText("triangle", to: "Window 1 saved after cancelled Quit")
    try v1Doc.writeRecoverySnapshotNow()
    try require(
        fm.fileExists(atPath: launchStore.envelopeURL(for: v1Doc.sessionID).path),
        "Window 1 could not write recovery after cancelled Quit"
    )
    _ = try v1Doc.saveDocumentExplicitly()
    let v1AfterCancelledQuit = try CanvasSession(document: CanvasDocument(data: Data(contentsOf: v1WorkingURL)))
    try require(
        v1AfterCancelledQuit.text(of: "triangle") == "Window 1 saved after cancelled Quit" &&
            v1Doc.persistenceState == .saved(hasPendingDraft: false),
        "Window 1 failed to save to disk after a subsequent window cancelled Quit"
    )
    print("PASS same-source copy/Save-As refusal and multi-window cancelled-Quit preservation")

    // 8. Real NSSavePanel modal invocation & cancellation (with saveDestinationProvider == nil) and
    //    multi-process SIGKILL crash -> fresh OS process relaunch recovery proof.
    secondWinDoc.saveDestinationProvider = nil
    RunLoop.main.perform(inModes: [.modalPanel, .common]) {
        MainActor.assumeIsolated {
            NSApp.abortModal()
        }
    }
    let modalPanelResult = secondWinDoc.chooseSaveDestination(suggestedName: "real-save-panel.json")
    try require(
        modalPanelResult == nil &&
            secondWinDoc.fileURL == nil &&
            secondWinDoc.persistenceState == .untitled(isDirty: true, hasPendingDraft: false),
        "Cancelling real NSSavePanel modal loop did not return nil or mutated untitled document state"
    )

    // Spawn Child Process 1 to author committed + inline draft state, write NSDocument draft + recovery envelope,
    // then terminate Child Process 1 with SIGKILL and spawn Child Process 2 to restore and save across OS processes:
    let multiProcRecoveryDir = tempRoot.appendingPathComponent("MultiProcRecovery", isDirectory: true)
    let readyFlagURL = tempRoot.appendingPathComponent("writer-ready.flag")
    let recoveredSavedURL = tempRoot.appendingPathComponent("recovered-across-processes.json")
    let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])

    let writerProc = Process()
    writerProc.executableURL = executableURL
    writerProc.arguments = ["--child-crash-writer", multiProcRecoveryDir.path, readyFlagURL.path]
    var env = ProcessInfo.processInfo.environment
    env["ELIXIR_CANVAS_RECOVERY_DIR"] = multiProcRecoveryDir.path
    writerProc.environment = env
    try writerProc.run()

    let flagDeadline = Date().addingTimeInterval(10.0)
    while !fm.fileExists(atPath: readyFlagURL.path) && Date() < flagDeadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    try require(
        fm.fileExists(atPath: readyFlagURL.path) && writerProc.isRunning,
        "Child crash-writer process did not signal ready before deadline"
    )
    // Terminate Child Process 1 abruptly with SIGKILL:
    Darwin.kill(writerProc.processIdentifier, SIGKILL)
    writerProc.waitUntilExit()
    try require(
        writerProc.terminationReason == .uncaughtSignal,
        "Child crash-writer process was not terminated by SIGKILL"
    )

    let multiProcStore = CanvasRecoveryStore(directoryURL: multiProcRecoveryDir)
    let onDiskInspections = multiProcStore.inspectAll()
    try require(
        onDiskInspections.count == 1,
        "Expected 1 restorable recovery record on disk after SIGKILL of child process (got \(onDiskInspections.count))"
    )

    // Spawn Child Process 2 (fresh OS process) to restore from multiProcRecoveryDir, commit the recovered inline draft, and save:
    let restorerProc = Process()
    restorerProc.executableURL = executableURL
    restorerProc.arguments = ["--child-crash-restorer", multiProcRecoveryDir.path, recoveredSavedURL.path]
    restorerProc.environment = env
    try restorerProc.run()
    restorerProc.waitUntilExit()
    try require(
        restorerProc.terminationStatus == 0 && fm.fileExists(atPath: recoveredSavedURL.path),
        "Child crash-restorer process failed (status \(restorerProc.terminationStatus)) or did not write recovered file"
    )
    let crossProcDoc = try CanvasDocument(data: Data(contentsOf: recoveredSavedURL))
    let crossProcNodes = crossProcDoc.root["nodes"] as? [[String: Any]] ?? []
    try require(
        crossProcNodes.count == 2 &&
            crossProcNodes.contains(where: { ($0["data"] as? [String: Any])?["text"] as? String == "Cross-process draft" }) &&
            multiProcStore.inspectAll().isEmpty,
        "Cross-process relaunch recovery did not restore and save both the committed shape and the active inline text draft"
    )
    print("PASS real NSSavePanel modal cancellation and multi-process SIGKILL crash -> fresh-process relaunch recovery")
}

@MainActor
func runChildCrashWriter(recoveryDirPath: String, readyFlagPath: String) throws {
    _ = NSApplication.shared
    let store = CanvasRecoveryStore(directoryURL: URL(fileURLWithPath: recoveryDirPath, isDirectory: true))
    let appDelegate = CanvasAppDelegate(recoveryStore: store)
    appDelegate.installMenu()
    appDelegate.newDocument(nil)
    guard let doc = appDelegate.activeNativeDocument(),
          let win = doc.canvasView.window else {
        throw CheckFailure(description: "Child writer could not create untitled document")
    }
    doc.canvasView.insertShape(.rectangle)
    doc.canvasView.beginAdjacentThought()
    doc.canvasView.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: win.windowNumber, context: nil, characters: "",
        charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124
    )!)
    doc.canvasView.inlineTextEditorView?.string = "Cross-process draft"
    try doc.writeRecoverySnapshotNow(requireAcknowledgement: true)
    try Data("ready".utf8).write(to: URL(fileURLWithPath: readyFlagPath))
    while true {
        Thread.sleep(forTimeInterval: 1.0)
    }
}

@MainActor
func runChildCrashRestorer(recoveryDirPath: String, outputPath: String) throws {
    _ = NSApplication.shared
    let store = CanvasRecoveryStore(directoryURL: URL(fileURLWithPath: recoveryDirPath, isDirectory: true))
    let appDelegate = CanvasAppDelegate(recoveryStore: store)
    appDelegate.installMenu()
    appDelegate.recoveryLaunchDecisionProvider = { _ in .restore }
    let restored = appDelegate.processPendingRecoveriesOnLaunch()
    guard restored.count == 1, let doc = restored.first else {
        throw CheckFailure(description: "Child restorer did not restore 1 session")
    }
    try require(
        doc.canvasView.hasAdjacentThoughtDraft &&
            doc.canvasView.adjacentThoughtDraftText == "Cross-process draft",
        "Child restorer did not restore active inline adjacent-thought draft"
    )
    _ = try doc.saveDocumentAs(to: URL(fileURLWithPath: outputPath))
}

@MainActor
func runStandaloneWorkflowVerification(in workspaceURL: URL) throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    try fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    let recoveryDir = workspaceURL.appendingPathComponent("Recovery", isDirectory: true)
    let appDelegate = CanvasAppDelegate(recoveryStore: CanvasRecoveryStore(directoryURL: recoveryDir))
    appDelegate.installMenu()
    defer { appDelegate.closeAllWindows() }

    try require(
        CanvasTypography.customFontDirectoryURL == nil && CanvasTypography.ensureRegistered(),
        "Bundled Neo-Acid and Amatic SC fonts failed to register from .app bundle without customFontDirectoryURL"
    )
    guard let registeredFontDir = CanvasTypography.registeredFontDirectoryURL?.canonicalFileURL else {
        throw CheckFailure(description: "CanvasTypography did not record registeredFontDirectoryURL")
    }
    try require(
        registeredFontDir.path.contains(".app/Contents/Resources/Fonts"),
        "Fonts were not loaded from inside the .app bundle (got \(registeredFontDir.path))"
    )
    let bundledIconURL = registeredFontDir.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
    try require(
        fm.fileExists(atPath: bundledIconURL.path)
            && (Bundle.main.infoDictionary?["CFBundleIconFile"] as? String) == "AppIcon"
            && NSImage(contentsOf: bundledIconURL)?.representations.count == 10,
        "Bundled Canvas.app is missing AppIcon.icns or CFBundleIconFile in Info.plist"
    )

    appDelegate.newDocument(nil)
    guard let doc = appDelegate.activeNativeDocument(),
          let win = doc.canvasView.window else {
        throw CheckFailure(description: "File -> New did not create an active CanvasNativeDocument window")
    }
    let canvas = doc.canvasView
    func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], chars: String = "") -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: win.windowNumber,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            keyCode: code
        )!
    }

    canvas.insertShape(.rectangle)
    guard let rectID = canvas.selectedNodeID else {
        throw CheckFailure(description: "Insert Rectangle did not select the new shape")
    }
    canvas.beginTextEditing()
    canvas.inlineTextEditorView?.string = "Native Architecture"
    canvas.inlineTextEditorView?.keyDown(with: key(36))

    canvas.selectNode(rectID)
    canvas.beginAdjacentThought()
    canvas.keyDown(with: key(124))
    canvas.inlineTextEditorView?.string = "Local JSON Store"
    canvas.inlineTextEditorView?.keyDown(with: key(36))
    guard let thoughtID = canvas.selectedNodeID, thoughtID != rectID else {
        throw CheckFailure(description: "Adjacent thought commit did not create and select a second node")
    }

    canvas.insertShape(.text)
    canvas.inlineTextEditorView?.string = "Zero Web Runtime"
    canvas.inlineTextEditorView?.keyDown(with: key(36))
    guard let textID = canvas.selectedNodeID, textID != thoughtID else {
        throw CheckFailure(description: "Insert Text did not create and select a third node")
    }

    let conn = try doc.session.insertConnection(
        source: rectID,
        sourceSide: .right,
        target: thoughtID,
        targetSide: .left,
        label: "autosaves to"
    )
    canvas.reloadFromSession(clearingUndoHistory: false)

    canvas.selectNode(thoughtID)
    let initialThoughtPos = doc.session.position(of: thoughtID)!
    let startPt = canvas.viewPoint(forWorldPoint: CGPoint(x: initialThoughtPos.x + 20, y: initialThoughtPos.y + 20))
    let endPt = CGPoint(x: startPt.x + 40, y: startPt.y + 30)
    func mouse(_ type: NSEvent.EventType, _ pt: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(pt, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: win.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
    }
    canvas.mouseDown(with: mouse(.leftMouseDown, startPt))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, endPt))
    canvas.mouseUp(with: mouse(.leftMouseUp, endPt))
    let movedThoughtPos = doc.session.position(of: thoughtID)!
    try require(movedThoughtPos != initialThoughtPos, "Pointer drag did not rearrange thought node")
    appDelegate.undoMove(nil)
    try require(doc.session.position(of: thoughtID) == initialThoughtPos, "Undo did not restore pre-drag position")
    appDelegate.redoMove(nil)
    try require(doc.session.position(of: thoughtID) == movedThoughtPos, "Redo did not restore dragged position")

    let jsonURL = workspaceURL.appendingPathComponent("standalone-diagram.json")
    doc.saveDestinationProvider = { _ in jsonURL }
    appDelegate.saveDocument(nil)
    try require(
        doc.fileURL?.canonicalFileURL == jsonURL.canonicalFileURL &&
            doc.persistenceState == .saved(hasPendingDraft: false),
        "First Save did not promote untitled document to standalone-diagram.json"
    )

    doc.quietAutosaveInterval = 0.03
    doc.maxContinuousAutosaveInterval = 0.15
    canvas.selectNode(rectID)
    try canvas.applyStyle(.fill, to: .string("yellow"))
    try require(
        doc.persistenceState == .changesPending(hasPendingDraft: false) && doc.isAutosaveScheduled,
        "Style edit did not schedule coalesced autosave"
    )
    let autosaveDeadline = Date().addingTimeInterval(2.0)
    while doc.persistenceState != .saved(hasPendingDraft: false) && Date() < autosaveDeadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    try require(
        doc.persistenceState == .saved(hasPendingDraft: false) && canvas.undoManager?.canUndo == true,
        "Coalesced autosave did not complete or cleared undo history"
    )

    try require(
        appDelegate.windowShouldClose(win),
        "Clean saved window shouldClose returned false"
    )
    appDelegate.closeAllWindows()
    try require(appDelegate.openNativeDocuments.isEmpty, "closeAllWindows did not clear openNativeDocuments")
    guard let reopenedDoc = appDelegate.openDocument(jsonURL) else {
        throw CheckFailure(description: "Failed to reopen standalone-diagram.json")
    }
    let reopenedNodes = (reopenedDoc.session.root["nodes"] as? [[String: Any]]) ?? []
    let reopenedIDs = reopenedNodes.compactMap { $0["id"] as? String }
    try require(
        reopenedIDs == [rectID, thoughtID, textID] &&
            reopenedDoc.session.position(of: thoughtID) == movedThoughtPos &&
            reopenedDoc.session.effectiveNodeStyle(of: rectID)?[.fill] == .string("yellow") &&
            reopenedDoc.session.connectionState(of: conn.id)?.label == "autosaves to",
        "Reopened document did not preserve IDs, order, geometry, style, or connection"
    )

    let pngURL = workspaceURL.appendingPathComponent("standalone-diagram.png")
    try reopenedDoc.canvasView.exportPNG(to: pngURL)
    let pngData = try Data(contentsOf: pngURL)
    guard let rep = NSBitmapImageRep(data: pngData),
          max(rep.pixelsWide, rep.pixelsHigh) == 2048,
          (rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1.0) == 0.0 else {
        throw CheckFailure(description: "Exported PNG did not match 2048px longest side with transparent background")
    }

    let savedJSONBytes = try Data(contentsOf: jsonURL)
    let fp = CanvasFileFingerprint(data: savedJSONBytes)
    let receipt: [String: Any] = [
        "registeredFontDirectory": registeredFontDir.path,
        "pid": Int(ProcessInfo.processInfo.processIdentifier),
        "jsonSHA256": fp.sha256Hex,
        "jsonByteCount": fp.byteCount,
        "nodeIDs": reopenedIDs,
        "connectionID": conn.id,
        "pngWidth": rep.pixelsWide,
        "pngHeight": rep.pixelsHigh
    ]
    let receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
    try receiptData.write(to: workspaceURL.appendingPathComponent("standalone-receipt.json"), options: .atomic)
}
