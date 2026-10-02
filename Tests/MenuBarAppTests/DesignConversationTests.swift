import AppKit
import SwiftUI
import Testing
@testable import MenuBarApp

struct DesignConversationLayoutTests {
    @Test func panelFitsNarrowAndShortWorkspacesWithTheSameAnchor() {
        for workspace in [CGSize(width: 1200, height: 800), CGSize(width: 480, height: 600),
                          CGSize(width: 280, height: 120), .zero] {
            for expanded in [false, true] {
                let size = DesignConversationLayout.size(in: workspace, expanded: expanded)
                let inset = DesignConversationLayout.inset(in: workspace)
                #expect(size.width >= 0 && size.height >= 0)
                #expect(size.width + inset * 2 <= workspace.width)
                #expect(size.height + inset * 2 <= workspace.height)
            }
        }
        let workspace = CGSize(width: 1200, height: 800)
        #expect(DesignConversationLayout.size(in: workspace, expanded: false)
                == CGSize(width: 405, height: 144))
        #expect(DesignConversationLayout.size(in: workspace, expanded: true)
                == CGSize(width: 1080, height: 704))
        #expect(DesignConversationLayout.size(in: CGSize(width: 600, height: 600), expanded: true)
                == CGSize(width: 564, height: 564))
    }

    @Test func previewUsesLatestLinesAndSkipsEmptyToolMessages() {
        let messages = [ChatMessage(role: .user, text: "Earlier prompt"),
                        ChatMessage(role: .assistant, text: "First\nSecond\nThird\nFourth"),
                        ChatMessage(role: .assistant, text: " \n")]
        #expect(DesignConversationLayout.preview(messages) == "Second\nThird\nFourth")
        #expect(!DesignConversationLayout.preview([]).isEmpty)
        #expect(DesignConversationLayout.preview([ChatMessage(role: .assistant,
            text: String(repeating: "x", count: 1000) + "latest")]).hasSuffix("latest"))
    }
}

@MainActor
struct DesignConversationDismissalTests {
    @Test func outsideClicksCollapseAndPassThroughWhileInsideClicksDoNothing() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let observer = DesignConversationDismissal.ObserverView(frame: CGRect(x: 20, y: 20, width: 405, height: 144))
        window.contentView?.addSubview(observer)
        defer { observer.stop() }
        var collapses = [Bool]()
        observer.expanded = true
        observer.collapse = { collapses.append($0) }
        func click(_ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        let inside = try click(CGPoint(x: 100, y: 100))
        #expect(observer.handle(inside, frontmost: window) === inside)
        #expect(collapses.isEmpty)
        let outside = try click(CGPoint(x: 600, y: 400))
        #expect(observer.handle(outside, frontmost: window) === outside)
        #expect(collapses == [false])
        observer.expanded = false
        #expect(observer.handle(outside, frontmost: window) === outside)
        #expect(collapses == [false])
        observer.expanded = true
        observer.isHidden = true
        #expect(observer.handle(outside, frontmost: window) === outside)
        #expect(collapses == [false])
    }
}

@MainActor
struct DesignConversationViewTests {
    @Test func foldingKeepsTheComposerTranscriptAndReadingPosition() async throws {
        let (store, scratch) = TestStore.make()
        let project = try TestStore.project(in: store)
        let session = store.newSession(in: project.id, seed: .init(agent: .codex, mode: .design))
        let artifact = try #require(store.designArtifactURL(for: session))
        try FileManager.default.createDirectory(at: artifact.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "<!doctype html><html><body><h1>Design canvas</h1><input value='Keep canvas state'></body></html>"
            .write(to: artifact, atomically: true, encoding: .utf8)
        for index in 0..<20 {
            store.append(ChatMessage(role: .assistant, text: "Message \(index)\n\n" +
                String(repeating: "Keep the reader's place in this conversation. ", count: 12)), to: session.id)
        }
        let runner = SessionRunner(paths: [.codex: "/usr/bin/true"])
        runner.editDraft(session.id) { $0.text = "Keep this draft" }
        let preferences = try #require(UserDefaults(suiteName: "design-floating-\(UUID().uuidString)"))
        let hosting = NSHostingController(rootView:
            DesignView(sessionID: session.id)
                .environment(store)
                .environment(runner)
                .environment(AppSettings(agentAvatarURL: scratch.path("avatar.png"), preferences: preferences))
                .environment(ShortcutStore(storageURL: scratch.path("shortcuts.json"), siteDefaults: SiteDefaults()))
                .environment(GlobalCommandPaletteController())
                .background(Theme.background)
                .appOverlays())
        hosting.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1000, height: 800))
        hosting.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            runner.stopAll()
        }
        func descendants(_ view: NSView) -> [NSView] {
            view.subviews + view.subviews.flatMap(descendants)
        }
        func settle() async throws {
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(20))
                hosting.view.layoutSubtreeIfNeeded()
            }
        }
        func click(_ point: CGPoint) throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: point,
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
            }
        }
        try await settle()
        let observer = try #require(descendants(hosting.view).compactMap {
            $0 as? DesignConversationDismissal.ObserverView
        }.first)
        #expect(!observer.expanded)
        #expect(observer.bounds.size == CGSize(width: 405, height: 144))
        let composer = try #require(descendants(hosting.view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let composerFrame = composer.convert(composer.bounds, to: nil)
        let transcript = try #require(descendants(hosting.view).compactMap { $0 as? NSScrollView }.first {
            !($0.documentView is NSTextView) && $0.contentView.documentRect.height > 1000
        })
        let viewport = try #require(descendants(hosting.view).compactMap { $0 as? DesignCanvasViewport }.first)
        let canvasFrame = viewport.convert(viewport.bounds, to: nil)
        let transcriptSize = transcript.bounds.size
        let compactFrame = observer.convert(observer.bounds, to: nil)
        try click(CGPoint(x: compactFrame.midX, y: compactFrame.midY))
        try await settle()
        #expect(observer.expanded)
        #expect(composer.convert(composer.bounds, to: nil) == composerFrame)
        #expect(transcript.bounds.size == transcriptSize)
        #expect(viewport.convert(viewport.bounds, to: nil) == canvasFrame)
        let selectedText = try #require(descendants(transcript).compactMap { $0 as? NSTextView }.first)
        selectedText.setSelectedRange(NSRange(location: 2, length: 4))
        transcript.contentView.scroll(to: CGPoint(x: 0, y: 200))
        transcript.reflectScrolledClipView(transcript.contentView)
        try await settle()
        let readingPosition = transcript.documentVisibleRect
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        #expect(observer.handle(escape, frontmost: window) == nil)
        try await settle()
        #expect(!observer.expanded)
        #expect(window.firstResponder !== composer)
        store.append(ChatMessage(role: .assistant, text: "A response while the panel is folded."), to: session.id)
        try await settle()
        #expect(!observer.expanded)
        #expect(runner.draft(session.id).text == "Keep this draft")
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let space = try #require(NSEvent.keyEvent(with: type, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49))
            window.sendEvent(space)
        }
        try await settle()
        #expect(observer.expanded)
        #expect(transcript.documentVisibleRect == readingPosition)
        #expect(descendants(hosting.view).contains { $0 === composer })
        #expect(descendants(hosting.view).contains { $0 === transcript })
        #expect(descendants(hosting.view).contains { $0 === viewport })
        #expect(selectedText.selectedRange() == NSRange(location: 2, length: 4))
        for width: CGFloat in [480, 700, 1000] {
            window.setContentSize(CGSize(width: width, height: 800))
            try await settle()
            let panel = observer.convert(observer.bounds, to: nil)
            let canvas = viewport.convert(viewport.bounds, to: nil)
            #expect(panel.minX >= canvas.minX && panel.maxX <= canvas.maxX)
            #expect(panel.minY >= canvas.minY && panel.maxY <= canvas.maxY)
        }
    }
}
