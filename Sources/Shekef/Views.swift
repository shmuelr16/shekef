import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct EditorWebView: NSViewRepresentable {
    let controller: EditorController
    func makeNSView(context: Context) -> WKWebView { controller.web }
    func updateNSView(_ v: WKWebView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        ZStack {
            if app.deck == nil { WelcomeView() } else { EditorLayout() }
            if let b = app.busy {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 14) { ProgressView().controlSize(.large); Text(b).font(.headline) }
                    .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(minWidth: 1080, minHeight: 660)
        .environment(\.layoutDirection, .rightToLeft)
        .navigationTitle(app.deck == nil ? "שקף" : app.title)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var urls: [URL] = []
            let g = DispatchGroup()
            for p in providers {
                g.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { DispatchQueue.main.async { urls.append(u) } }; DispatchQueue.main.async { g.leave() } }
            }
            g.notify(queue: .main) { app.openFiles(urls) }
            return true
        }
        .alert("שקף", isPresented: Binding(get: { app.errorMessage != nil }, set: { if !$0 { app.errorMessage = nil } })) {
            Button("אישור") { app.errorMessage = nil }
        } message: { Text(app.errorMessage ?? "") }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let recents = app.recents.filter { FileManager.default.fileExists(atPath: $0) }
        ScrollView {
            VStack(spacing: 22) {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("שקף").font(.system(size: 40, weight: .bold))
                        Text("עריכה והצגה של מצגות, בעברית").font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { app.newDeck() } label: { Label("מצגת חדשה", systemImage: "plus.rectangle").frame(width: 150, height: 32) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { app.openPanel() } label: { Label("פתח קובץ…", systemImage: "folder").frame(width: 150, height: 32) }
                        .controlSize(.large)
                }
                Text("אפשר גם לגרור לכאן קובץ: pptx, ppt, key, odp, pdf, html או תמונות")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text("מצגות אחרונות").font(.title2.bold()).frame(maxWidth: .infinity, alignment: .leading)
                if recents.isEmpty {
                    Text("עדיין אין מצגות. התחל במצגת חדשה או פתח קובץ.").foregroundStyle(.secondary).padding(.top, 30)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 320), spacing: 20)], spacing: 22) {
                        ForEach(recents, id: \.self) { p in RecentCard(path: p) }
                    }
                }
            }.padding(36)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RecentCard: View {
    @EnvironmentObject var app: AppState
    let path: String
    @State private var hover = false
    var body: some View {
        let url = URL(fileURLWithPath: path)
        let date = (try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent("deck.json").path)[.modificationDate]) as? Date
        Button { app.loadPackage(url) } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.15))
                    if let img = NSImage(contentsOf: url.appendingPathComponent("thumb.png")) { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
                    else { Image(systemName: "rectangle.on.rectangle").font(.system(size: 40)).foregroundStyle(.secondary) }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(hover ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: hover ? 2.5 : 1))
                .shadow(color: .black.opacity(hover ? 0.22 : 0.08), radius: hover ? 10 : 4, y: 3)
                Text(url.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                if let date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu {
            Button("פתח") { app.loadPackage(url) }
            Button("הצג ב-Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("הסר מהרשימה") { app.removeRecent(path) }
        }
    }
}

struct EditorLayout: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        HStack(spacing: 0) {
            SidebarView().frame(width: 200)
            Divider()
            EditorWebView(controller: app.editor)
            Divider()
            InspectorView().frame(width: 290)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { app.goHome() } label: { Label("בית", systemImage: "house") }.help("חזרה לדף הבית")
                Button { app.saveClicked() } label: { Label(app.savedFlash ? "נשמר" : "שמור", systemImage: app.savedFlash ? "checkmark.circle.fill" : "square.and.arrow.down") }
                    .help("שמור (נשמר גם אוטומטית)")
                Button { app.addSlide() } label: { Label("שקף חדש", systemImage: "plus.rectangle") }.help("שקף חדש")
            }
            ToolbarItemGroup(placement: .principal) {
                Button { app.addText() } label: { Label("טקסט", systemImage: "textformat") }.help("תיבת טקסט")
                Button { app.chooseImage() } label: { Label("תמונה", systemImage: "photo") }.help("תמונה")
                Menu { ForEach(SHAPES, id: \.id) { s in Button { app.addShape(s.id) } label: { Label(s.name, systemImage: s.icon) } } }
                    label: { Label("צורה", systemImage: "square.on.circle") }.help("צורה")
                Divider()
                Button { app.undo() } label: { Label("בטל", systemImage: "arrow.uturn.forward") }.disabled(app.undoStack.isEmpty && app.editingText == nil).help("בטל")
                Button { app.redo() } label: { Label("בצע שוב", systemImage: "arrow.uturn.backward") }.disabled(app.redoStack.isEmpty && app.editingText == nil).help("בצע שוב")
                Divider()
                Button { app.textCommand("bold") } label: { Label("מודגש", systemImage: "bold") }.help("מודגש")
                Button { app.textCommand("italic") } label: { Label("נטוי", systemImage: "italic") }.help("נטוי")
                Button { app.textCommand("underline") } label: { Label("קו תחתון", systemImage: "underline") }.help("קו תחתון")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("PowerPoint (pptx)") { app.exportPanel("pptx") }
                    Button("PDF") { app.exportPanel("pdf") }
                    Button("HTML") { app.exportPanel("html") }
                } label: { Label("ייצוא", systemImage: "square.and.arrow.up") }.help("ייצוא")
                Button { app.present(fromStart: false) } label: { Label("הצג", systemImage: "play.fill") }.help("הצגה במסך מלא")
            }
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var app: AppState
    var body: some View {
        let slides = app.deck?.slides ?? []
        ScrollViewReader { proxy in
            List(selection: Binding<String?>(
                get: { app.slide?.id },
                set: { id in if let id, let i = slides.firstIndex(where: { $0.id == id }) { app.goto(i) } })) {
                ForEach(Array(slides.enumerated()), id: \.element.id) { i, s in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(i + 1)").font(.caption).foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
                        ZStack {
                            Rectangle().fill(Color(css: s.bg, fallback: .white))
                            if let img = app.thumbs[s.id] { Image(nsImage: img).resizable() }
                        }
                        .aspectRatio(SLIDE_W / app.deckHeight, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(i == app.current ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: i == app.current ? 2.5 : 1))
                    }
                    .padding(.vertical, 3)
                    .tag(s.id).id(s.id)
                    .contextMenu {
                        Button("שקף חדש") { app.goto(i); app.addSlide() }
                        Button("שכפל") { app.goto(i); app.duplicateSlide() }
                        Divider()
                        Button("הזז למעלה") { app.goto(i); app.moveSlide(by: -1) }.disabled(i == 0)
                        Button("הזז למטה") { app.goto(i); app.moveSlide(by: 1) }.disabled(i == slides.count - 1)
                        Divider()
                        Button("מחק", role: .destructive) { app.goto(i); app.deleteSlide() }.disabled(slides.count < 2)
                    }
                }
                .onMove { app.moveSlides(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { app.deleteSlide() }
            .onChange(of: app.current) { _, _ in if let id = app.slide?.id { withAnimation { proxy.scrollTo(id) } } }
        }
    }
}

// MARK: מפקח

struct InspectorView: View {
    @EnvironmentObject var app: AppState

    func el<T>(_ kp: WritableKeyPath<Element, T>, _ key: String) -> Binding<T>? {
        guard let first = app.selectedElements.first else { return nil }
        return Binding(get: { app.selectedElements.first?[keyPath: kp] ?? first[keyPath: kp] },
                       set: { v in app.mutateSelected(key) { $0[keyPath: kp] = v } })
    }
    func color(_ kp: WritableKeyPath<Element, String?>, _ key: String, fallback: Color) -> Binding<Color> {
        Binding(get: { Color(css: app.selectedElements.first?[keyPath: kp], fallback: fallback) },
                set: { v in app.mutateSelected(key) { $0[keyPath: kp] = v.css } })
    }
    func num(_ kp: WritableKeyPath<Element, Double?>, _ key: String, _ def: Double) -> Binding<Double> {
        Binding(get: { app.selectedElements.first?[keyPath: kp] ?? def },
                set: { v in app.mutateSelected(key) { $0[keyPath: kp] = v } })
    }
    func pick(_ kp: WritableKeyPath<Element, String?>, _ key: String, _ def: String) -> Binding<String> {
        Binding(get: { app.selectedElements.first?[keyPath: kp] ?? def },
                set: { v in app.mutateSelected(key) { $0[keyPath: kp] = v } })
    }
    func flag(_ kp: WritableKeyPath<Element, Bool?>, _ key: String) -> Binding<Bool> {
        Binding(get: { app.selectedElements.first?[keyPath: kp] ?? false },
                set: { v in app.mutateSelected(key) { $0[keyPath: kp] = v ? true : nil } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let sel = app.selectedElements
                if let e = sel.first {
                    elementSection(e, count: sel.count)
                } else {
                    Text("בחר אלמנט כדי לערוך אותו, או ערוך את השקף למטה.").font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                slideSection
            }.padding(14)
        }.background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder func elementSection(_ e: Element, count: Int) -> some View {
        let typeName = ["text": "טקסט", "image": "תמונה", "shape": "צורה", "embed": "אנימציה", "read": "כפתור הקראה"][e.type] ?? e.type
        Text(count > 1 ? "\(count) אלמנטים" : typeName).font(.headline)
        if e.type == "text" {
            Group {
                Picker("גופן", selection: pick(\.font, "font", "Arial Hebrew")) {
                    let fonts = Array(Set((app.deck?.fonts ?? []).map { $0.family })).sorted() + SYSTEM_FONTS
                    ForEach(Array(NSOrderedSet(array: (e.font.map { [$0] } ?? []) + fonts)) as! [String], id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("גודל")
                    TextField("", value: num(\.size, "size", 48), format: .number.precision(.fractionLength(0))).frame(width: 60)
                    Stepper("", value: num(\.size, "size", 48), in: 8...400, step: 4).labelsHidden()
                    Spacer()
                    ColorPicker("", selection: color(\.color, "color", fallback: Color(css: "#1b2540"))).labelsHidden()
                }
                HStack {
                    Picker("", selection: pick(\.align, "align", "right")) {
                        Image(systemName: "text.alignright").tag("right")
                        Image(systemName: "text.aligncenter").tag("center")
                        Image(systemName: "text.alignleft").tag("left")
                        Image(systemName: "text.justify").tag("justify")
                    }.pickerStyle(.segmented).labelsHidden()
                }
                HStack {
                    Picker("", selection: pick(\.valign, "valign", "top")) {
                        Image(systemName: "arrow.up.to.line").tag("top")
                        Image(systemName: "arrow.up.and.down").tag("middle")
                        Image(systemName: "arrow.down.to.line").tag("bottom")
                    }.pickerStyle(.segmented).labelsHidden()
                    Toggle(isOn: flag(\.bold, "bold")) { Image(systemName: "bold") }.toggleStyle(.button)
                    Toggle(isOn: flag(\.italic, "italic")) { Image(systemName: "italic") }.toggleStyle(.button)
                }
                HStack { Text("מרווח שורות"); Slider(value: num(\.lineHeight, "lh", 1.3), in: 0.8...2.5) }
                Picker("כיוון", selection: pick(\.dir, "dir", "rtl")) { Text("ימין לשמאל").tag("rtl"); Text("שמאל לימין").tag("ltr") }
                Toggle("כפתור הקראה לטקסט הזה", isOn: Binding(get: { app.readButton(for: e.id) != nil }, set: { _ in app.toggleReadButton(for: e.id) }))
                    .toggleStyle(.switch)
            }
        }
        if e.type == "read" {
            Group {
                HStack { Text("כיתוב"); TextField("הקראה", text: Binding(get: { e.label ?? "הקראה" }, set: { v in app.mutateSelected("label") { $0.label = v } })) }
                HStack {
                    Text(e.src == nil ? "קול עברי של המק" : "קובץ שמע מצורף").foregroundStyle(.secondary)
                    Spacer()
                    if e.src != nil { Button("הסר") { app.mutateSelected { $0.src = nil } } }
                    Button(e.src == nil ? "צרף שמע…" : "החלף…") { if let n = app.chooseAudio() { app.mutateSelected { $0.src = n } } }
                }
                Button { app.previewRead(e.id) } label: { Label(app.speakingID == e.id ? "עצור" : "השמע", systemImage: app.speakingID == e.id ? "stop.fill" : "speaker.wave.2.fill") }
                HStack { Text("צבע כיתוב"); Spacer(); ColorPicker("", selection: color(\.color, "color", fallback: .white)).labelsHidden() }
            }
        }
        if e.type == "image" {
            Picker("התאמה", selection: pick(\.fit, "fit", "contain")) { Text("הכל נראה").tag("contain"); Text("מילוי וחיתוך").tag("cover"); Text("מתיחה").tag("fill") }
        }
        if e.type != "image" && e.type != "embed" {
            HStack {
                Text(e.type == "text" ? "רקע" : "מילוי"); Spacer()
                if e.fill != nil { Button("ללא") { app.mutateSelected { $0.fill = nil } }.controlSize(.small) }
                ColorPicker("", selection: color(\.fill, "fill", fallback: e.type == "read" ? Color(css: "#1f6feb") : .clear)).labelsHidden()
            }
            HStack {
                Text("קו מתאר"); Spacer()
                TextField("", value: num(\.strokeW, "sw", 0), format: .number.precision(.fractionLength(0))).frame(width: 44)
                Stepper("", value: num(\.strokeW, "sw", 0), in: 0...60).labelsHidden()
                ColorPicker("", selection: color(\.stroke, "stroke", fallback: .black)).labelsHidden()
            }
        }
        if e.type != "embed" && !(e.type == "shape" && !["rect", "round"].contains(e.shape ?? "rect")) {
            HStack { Text("פינות"); Slider(value: num(\.radius, "radius", 0), in: 0...200) }
        }
        Toggle("צל", isOn: flag(\.shadow, "shadow"))
        HStack { Text("שקיפות"); Slider(value: num(\.opacity, "opacity", 1), in: 0.05...1) }
        HStack(spacing: 6) {
            ForEach([("x", \Element.x), ("y", \Element.y), ("רוחב", \Element.w), ("גובה", \Element.h)], id: \.0) { item in
                VStack(spacing: 1) {
                    TextField("", value: Binding(get: { app.selectedElements.first?[keyPath: item.1] ?? 0 }, set: { v in app.mutateSelected("geo") { $0[keyPath: item.1] = v } }), format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.center)
                    Text(item.0).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        HStack {
            Text("סדר")
            Spacer()
            Button { app.arrange("front") } label: { Image(systemName: "square.3.layers.3d.top.filled") }.help("הבא לחזית")
            Button { app.arrange("forward") } label: { Image(systemName: "square.2.layers.3d.top.filled") }.help("קדימה")
            Button { app.arrange("backward") } label: { Image(systemName: "square.2.layers.3d.bottom.filled") }.help("אחורה")
            Button { app.arrange("back") } label: { Image(systemName: "square.3.layers.3d.bottom.filled") }.help("שלח לרקע")
        }
        HStack {
            Text("יישור לשקף")
            Spacer()
            Button { app.alignSelection("hcenter") } label: { Image(systemName: "align.horizontal.center") }.help("מרכז אופקי")
            Button { app.alignSelection("vcenter") } label: { Image(systemName: "align.vertical.center") }.help("מרכז אנכי")
        }
        Divider()
        Text("אנימציית כניסה").font(.headline)
        Picker("אפקט", selection: pick(\.anim, "anim", "none")) { ForEach(ANIMS, id: \.id) { Text($0.name).tag($0.id) } }
        if (e.anim ?? "none") != "none" {
            Toggle("יחד עם האלמנט הקודם", isOn: flag(\.animWith, "animWith"))
            Picker("סאונד", selection: Binding(get: { e.aSound ?? "" }, set: { v in app.mutateSelected { $0.aSound = v.isEmpty ? nil : v }; if !v.isEmpty { app.audio.sfx(v) } })) {
                Text("ללא").tag(""); ForEach(SFX, id: \.id) { Text($0.name).tag($0.id) }
            }
            Text("האלמנט ייכנס בלחיצה בזמן ההצגה.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var slideSection: some View {
        if let s = app.slide {
            Text("שקף \(app.current + 1)").font(.headline)
            HStack {
                Text("רקע"); Spacer()
                ColorPicker("", selection: Binding(get: { Color(css: s.bg, fallback: .white) }, set: { v in app.mutateSlide("bg") { $0.bg = v.css } })).labelsHidden()
            }
            HStack {
                Text("תמונת רקע"); Spacer()
                if s.bgImage != nil { Button("הסר") { app.mutateSlide { $0.bgImage = nil } } }
                Button("בחר…") { app.chooseBackgroundImage() }
            }
            Button("החל רקע על כל השקפים") { app.mutate { d in for i in d.slides.indices { d.slides[i].bg = s.bg; d.slides[i].bgImage = s.bgImage } } }.controlSize(.small)
            Picker("מעבר", selection: Binding(get: { s.transition ?? "fade" }, set: { v in app.mutateSlide { $0.transition = v } })) {
                ForEach(TRANSITIONS, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("סאונד מעבר", selection: Binding(get: { s.tSound ?? "" }, set: { v in app.mutateSlide { $0.tSound = v.isEmpty ? nil : v }; if !v.isEmpty { app.audio.sfx(v) } })) {
                Text("ללא").tag(""); ForEach(SFX, id: \.id) { Text($0.name).tag($0.id) }
            }
            Button("החל מעבר על כל השקפים") { app.mutate { d in for i in d.slides.indices { d.slides[i].transition = s.transition; d.slides[i].tSound = s.tSound } } }.controlSize(.small)
            HStack {
                Text("שמע לשקף"); Spacer()
                if s.audio != nil {
                    Button { app.previewSlideAudio() } label: { Image(systemName: "play.fill") }
                    Button("הסר") { app.mutateSlide { $0.audio = nil } }
                }
                Button(s.audio == nil ? "צרף…" : "החלף…") { if let n = app.chooseAudio() { app.mutateSlide { $0.audio = n; $0.audioAuto = true } } }
            }
            if s.audio != nil {
                Toggle("נגן אוטומטית בכניסה לשקף", isOn: Binding(get: { s.audioAuto ?? true }, set: { v in app.mutateSlide { $0.audioAuto = v } }))
            }
        }
    }
}
