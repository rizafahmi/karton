import AppKit
import CanvasCore
import CanvasUI

@MainActor
func runAttachmentImportChecks() throws {
    let fm = FileManager.default
    let tempDir = fm.temporaryDirectory.appendingPathComponent("CanvasAttachImport-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    // Prepare test files
    let mdContent = "\u{feff}# Native Attachment\r\n\t- Literal UTF-8 😀\r<script>inert</script>\n"
    let mdURL = tempDir.appendingPathComponent("notes.md")
    try Data(mdContent.utf8).write(to: mdURL)

    let emptyURL = tempDir.appendingPathComponent("empty.txt")
    try Data().write(to: emptyURL)

    let exURL = tempDir.appendingPathComponent("worker.ex")
    try Data("defmodule W, do: :ok\n".utf8).write(to: exURL)

    let binaryURL = tempDir.appendingPathComponent("blob.bin")
    try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0xFF]).write(to: binaryURL)

    let controlURL = tempDir.appendingPathComponent("bell.txt")
    try Data("hi\u{0007}there".utf8).write(to: controlURL)

    let oversizedURL = tempDir.appendingPathComponent("huge.txt")
    try Data(repeating: 0x61, count: CanvasAttachment.fileByteLimit + 1).write(to: oversizedURL)

    let maxChunkURL = tempDir.appendingPathComponent("chunk.txt")
    try Data(repeating: 0x78, count: CanvasAttachment.fileByteLimit).write(to: maxChunkURL)

    let subDirURL = tempDir.appendingPathComponent("folder", isDirectory: true)
    try fm.createDirectory(at: subDirURL, withIntermediateDirectories: true)

    // 1. Verify v1 canvas supports native text attachment import without upgrading version
    let v1Doc = try CanvasDocument(data: Data(#"{"version":1,"nodes":[],"edges":[]}"#.utf8))
    let v1Session = CanvasSession(document: v1Doc)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let view = CanvasView(session: v1Session)
    view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    window.contentView = view
    window.makeFirstResponder(view)

    // Verify drag-and-drop registration
    try require(
        view.registeredDraggedTypes.contains(.fileURL),
        "CanvasView did not register .fileURL dragged type for attachment drop"
    )

    // Picker cancellation leaves canvas clean with no nodes or history
    view.attachmentImportURLProvider = { nil }
    view.attachTextFile()
    try require(
        (v1Session.root["nodes"] as? [[String: Any]])?.isEmpty == true &&
        view.undoManager?.canUndo != true,
        "Cancelled Attach Text File created a node or history entry"
    )

    // Import Markdown file via picker hook
    view.attachmentImportURLProvider = { mdURL }
    view.attachTextFile()
    guard let mdID = view.selectedNodeID,
          let mdAttachment = v1Session.attachment(of: mdID),
          let mdGeo = v1Session.geometry(of: mdID) else {
        throw CheckFailure(description: "Markdown attachment import did not create/select attachment card")
    }
    try require(
        v1Session.version == 1 &&
        mdAttachment.filename == "notes.md" &&
        mdAttachment.mediaType == "text/markdown" &&
        mdAttachment.encoding == "utf-8" &&
        mdAttachment.content == mdContent &&
        v1Session.text(of: mdID) == "notes.md" &&
        mdGeo.width == CanvasAttachment.defaultWidth &&
        mdGeo.height == CanvasAttachment.defaultHeight,
        "Imported Markdown attachment did not match v1 contract or altered literal bytes"
    )

    // Snapshot isolation: mutating/deleting the source file on disk does not affect the embedded attachment
    try Data("modified on disk".utf8).write(to: mdURL)
    try fm.removeItem(at: mdURL)
    try require(
        v1Session.attachment(of: mdID)?.content == mdContent,
        "Embedded attachment was affected by disk file deletion"
    )

    // Undo / Redo restores attachment atomically with stable ID
    view.undoMove(nil)
    try require((v1Session.root["nodes"] as? [[String: Any]])?.isEmpty == true, "Undo did not remove imported attachment")
    view.redoMove(nil)
    try require(v1Session.attachment(of: mdID)?.content == mdContent, "Redo did not restore imported attachment")

    // Empty 0-byte file and source code file (.ex -> text/plain)
    let emptyID = try view.importAttachment(from: emptyURL, centeredAt: CGPoint(x: 300, y: 200))
    let exID = try view.importAttachment(from: exURL, centeredAt: CGPoint(x: 560, y: 200))
    try require(
        v1Session.attachment(of: emptyID)?.content == "" &&
        v1Session.attachment(of: emptyID)?.mediaType == "text/plain" &&
        v1Session.attachment(of: exID)?.mediaType == "text/plain" &&
        v1Session.attachment(of: exID)?.content == "defmodule W, do: :ok\n",
        "Empty or .ex attachment failed media type or literal content check"
    )

    // 2. Refusals: binary, control chars, >256 KiB, directory — no node added, visible importError banner
    let nodeCountBeforeRefusals = (v1Session.root["nodes"] as? [[String: Any]])?.count ?? 0
    for badURL in [binaryURL, controlURL, oversizedURL, subDirURL] {
        view.attachmentImportURLProvider = { badURL }
        view.attachTextFile()
        let countNow = (v1Session.root["nodes"] as? [[String: Any]])?.count ?? 0
        try require(
            countNow == nodeCountBeforeRefusals && !view.statusBanner.isHidden,
            "Invalid attachment \(badURL.lastPathComponent) was not refused cleanly"
        )
        if case .importError = view.statusBanner.activeKind {
            // expected
        } else {
            throw CheckFailure(description: "Refused attachment \(badURL.lastPathComponent) did not show importError banner")
        }
    }

    // 3. Aggregate 1 MiB quota enforcement across multiple 256 KiB attachments
    let quotaDoc = try CanvasDocument.blank()
    let quotaSession = CanvasSession(document: quotaDoc)
    let quotaView = CanvasView(session: quotaSession)
    quotaView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    for idx in 0..<4 {
        _ = try quotaView.importAttachment(from: maxChunkURL, centeredAt: CGPoint(x: Double(idx * 260), y: 100))
    }
    var threwAggregateLimit = false
    do {
        _ = try quotaView.importAttachment(from: exURL)
    } catch {
        threwAggregateLimit = error.localizedDescription.contains("1048576")
    }
    try require(threwAggregateLimit, "5th attachment exceeding 1 MiB aggregate canvas limit was not refused")

    // 4. AttachmentPreviewSheet Save Copy writes exact literal UTF-8 bytes without dirtying or history
    //    and cancelling Save Copy leaves session clean.
    let exportedCopyURL = tempDir.appendingPathComponent("exported-notes.md")
    let revBeforeSaveCopy = v1Session.revision
    view.selectNode(mdID)
    view.attachmentSaveCopyURLProvider = { _ in nil }
    view.beginAttachmentPreview()
    guard let cancelSheet = window.attachedSheet,
          let cancelSaveBtn = cancelSheet.contentView?.subviews.first(where: {
              $0.identifier?.rawValue == "attachment-preview-save-copy"
          }) as? NSButton,
          let cancelCloseBtn = cancelSheet.contentView?.subviews.first(where: {
              $0.identifier?.rawValue == "attachment-preview-close"
          }) as? NSButton else {
        throw CheckFailure(description: "AttachmentPreviewSheet did not expose Save Copy button for cancel check")
    }
    cancelSaveBtn.performClick(nil)
    cancelCloseBtn.performClick(nil)
    try require(
        v1Session.revision == revBeforeSaveCopy && !fm.fileExists(atPath: exportedCopyURL.path),
        "Cancelling Save Copy mutated session or wrote a file"
    )

    view.attachmentSaveCopyURLProvider = { suggested in
        suggested == "notes.md" ? exportedCopyURL : nil
    }
    view.beginAttachmentPreview()
    guard let sheet = window.attachedSheet,
          let saveCopyButton = sheet.contentView?.subviews.first(where: {
              $0.identifier?.rawValue == "attachment-preview-save-copy"
          }) as? NSButton,
          let closeButton = sheet.contentView?.subviews.first(where: {
              $0.identifier?.rawValue == "attachment-preview-close"
          }) as? NSButton else {
        throw CheckFailure(description: "AttachmentPreviewSheet did not expose Save Copy button")
    }
    saveCopyButton.performClick(nil)
    closeButton.performClick(nil)
    let exportedBytes = try Data(contentsOf: exportedCopyURL)
    try require(
        exportedBytes.elementsEqual(mdContent.utf8) && v1Session.revision == revBeforeSaveCopy,
        "AttachmentPreviewSheet Save Copy did not write exact literal UTF-8/BOM/CRLF bytes or mutated session"
    )

    // 4b. Symlink to directory is refused cleanly; v2 canvas also supports attachment import.
    let dirSymlinkURL = tempDir.appendingPathComponent("folder-link")
    try fm.createSymbolicLink(at: dirSymlinkURL, withDestinationURL: subDirURL)
    var threwDirSymlink = false
    do {
        _ = try CanvasAttachment.load(from: dirSymlinkURL)
    } catch {
        threwDirSymlink = true
    }
    try require(threwDirSymlink, "Symlink to directory was not refused by CanvasAttachment.load")

    let v2AttachDoc = try CanvasDocument.blank()
    let v2AttachSession = CanvasSession(document: v2AttachDoc)
    let v2AttachView = CanvasView(session: v2AttachSession)
    v2AttachView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    let v2AttID = try v2AttachView.importAttachment(from: exURL, centeredAt: CGPoint(x: 200, y: 200))
    try require(
        v2AttachSession.version == 2 &&
        v2AttachSession.attachment(of: v2AttID)?.filename == "worker.ex",
        "v2 canvas attachment import failed"
    )

    // 5. Menu wiring check in CanvasAppDelegate + v1 JSON round-trip
    let delegate = CanvasAppDelegate()
    delegate.installMenu()
    let insertMenu = NSApplication.shared.mainMenu?.item(withTitle: "Insert")?.submenu
    try require(
        insertMenu?.item(withTitle: "Attach Text File…") != nil,
        "Insert menu is missing Attach Text File… item"
    )

    let encoded = try v1Session.encodedData()
    let reopened = try CanvasDocument(data: encoded)
    let reopenedSession = CanvasSession(document: reopened)
    try require(
        reopenedSession.version == 1 &&
        reopenedSession.attachment(of: mdID)?.content == mdContent &&
        reopenedSession.attachment(of: emptyID)?.content == "",
        "v1 JSON round-trip altered imported attachments"
    )

    print("PASS native text attachment import: v1/v2 picker & drag-and-drop registration, literal BOM/CRLF/empty files, binary/control/256KiB/1MiB refusals, Save Copy export, Undo/Redo and JSON round-trip")
}
