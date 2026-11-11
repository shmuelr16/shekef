import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppState.shared.openFiles(urls, forceNewDeck: true) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.saveNow() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        let args = CommandLine.arguments
        // מצבי בדיקה משורת הפקודה: --import <קובץ> <חבילה> | --export <חבילה> <קובץ יעד> | --thumb <חבילה> <png> <מספר שקף>
        guard args.count >= 4, ["--import", "--export", "--thumb", "--readtest"].contains(args[1]) else { return }
        Task { @MainActor in
            let app = AppState.shared
            let a = URL(fileURLWithPath: args[2]), b = URL(fileURLWithPath: args[3])
            switch args[1] {
            case "--import":
                try? FileManager.default.removeItem(at: b)
                let ctx = ImportContext(packageURL: b)
                do {
                    let d = try await Importer.importAny([a], ctx: ctx, app: app)
                    try AppState.writePackage(d, to: b)
                    print("OK slides=\(d.slides.count) elements=\(d.slides.map { $0.elements.count })")
                } catch { print("FAIL \((error as? ImportError)?.message ?? "\(error)")") }
            case "--export":
                app.loadPackage(a)
                await app.export(b.pathExtension.lowercased(), to: b)
                print(app.errorMessage ?? "OK")
            case "--readtest":
                app.loadPackage(a)
                app.goto((Int(args[3]) ?? 1) - 1)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                let click = "(()=>{const n=document.querySelector('.el-read');if(!n)return;const r=n.getBoundingClientRect();const o={bubbles:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2,button:0};n.dispatchEvent(new MouseEvent('mousedown',o));n.dispatchEvent(new MouseEvent('mouseup',o));n.dispatchEvent(new MouseEvent('click',o))})()"
                app.editor.js(click)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                print("EDITOR", app.audio.debugState)
                app.audio.stopVoice()
                app.present(fromStart: false)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                app.player.debugJS(click)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                print("PLAYER", app.audio.debugState)
                app.audio.stopVoice()
            default:
                app.loadPackage(a)
                let i = args.count > 4 ? (Int(args[4]) ?? 1) - 1 : 0
                if let d = app.deck, d.slides.indices.contains(i), let img = await app.renderer.snapshot(d.slides[i], deck: d, width: 960), let png = pngData(img) {
                    try? png.write(to: b); print("OK")
                } else { print("FAIL") }
            }
            exit(0)
        }
    }
}

@main
struct ShekefApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window("שקף", id: "main") {
            ContentView().environmentObject(app)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("מצגת חדשה") { app.newDeck() }.keyboardShortcut("n")
                Button("פתח…") { app.openPanel() }.keyboardShortcut("o")
                Divider()
                Button("שמור") { app.saveClicked() }.keyboardShortcut("s").disabled(app.deck == nil)
                Button("דף הבית") { app.goHome() }.keyboardShortcut("h", modifiers: [.command, .shift]).disabled(app.deck == nil)
                Button("שמור בשם…") { app.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift]).disabled(app.deck == nil)
                Button("סגור מצגת") { app.closeDeck() }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(app.deck == nil)
                Divider()
                Menu("ייצוא") {
                    Button("PowerPoint (pptx)…") { app.exportPanel("pptx") }
                    Button("PDF…") { app.exportPanel("pdf") }
                    Button("HTML…") { app.exportPanel("html") }
                }.disabled(app.deck == nil)
            }
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("בטל") { app.undo() }.keyboardShortcut("z").disabled(app.deck == nil)
                Button("בצע שוב") { app.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(app.deck == nil)
            }
            CommandMenu("שקף") {
                Button("שקף חדש") { app.addSlide() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("שכפל שקף") { app.duplicateSlide() }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("מחק שקף") { app.deleteSlide() }
                Divider()
                Button("הזז שקף למעלה") { app.moveSlide(by: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("הזז שקף למטה") { app.moveSlide(by: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button("השקף הבא") { app.goto(app.current + 1) }.keyboardShortcut(.pageDown, modifiers: [])
                Button("השקף הקודם") { app.goto(app.current - 1) }.keyboardShortcut(.pageUp, modifiers: [])
            }
            CommandMenu("הוספה") {
                Button("תיבת טקסט") { app.addText() }.keyboardShortcut("t", modifiers: [.command, .shift])
                Button("תמונה…") { app.chooseImage() }.keyboardShortcut("i", modifiers: [.command, .shift])
                Menu("צורה") { ForEach(SHAPES, id: \.id) { s in Button(s.name) { app.addShape(s.id) } } }
            }
            CommandMenu("סידור") {
                Button("שכפל") { app.duplicateSelection() }.keyboardShortcut("d")
                Button("מחק") { app.deleteSelection() }
                Divider()
                Button("הבא לחזית") { app.arrange("front") }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("קדימה") { app.arrange("forward") }.keyboardShortcut("]")
                Button("אחורה") { app.arrange("backward") }.keyboardShortcut("[")
                Button("שלח לרקע") { app.arrange("back") }.keyboardShortcut("[", modifiers: [.command, .shift])
                Divider()
                Button("מודגש") { app.textCommand("bold") }.keyboardShortcut("b")
                Button("נטוי") { app.textCommand("italic") }.keyboardShortcut("i")
                Button("קו תחתון") { app.textCommand("underline") }.keyboardShortcut("u")
            }
            CommandMenu("הצגה") {
                Button("הצג מההתחלה") { app.present(fromStart: true) }.keyboardShortcut(.return, modifiers: [.command])
                Button("הצג מהשקף הנוכחי") { app.present(fromStart: false) }.keyboardShortcut(.return, modifiers: [.command, .shift])
            }
        }
    }
}
