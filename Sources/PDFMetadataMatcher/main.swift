import SwiftUI
import AppKit
import Foundation
import UniformTypeIdentifiers

struct Field: Identifiable {
    let id: String
    let source: String
    let destination: String
    var matches: Bool { source == destination }
}

enum PDFTools {
    static func executable(_ name: String) -> String? {
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
    static func run(_ tool: String, _ args: [String]) throws -> String {
        guard let path = executable(tool) else { throw NSError(domain: "PDFMetadataMatcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(tool). Install with: brew install exiftool qpdf poppler"]) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 { throw NSError(domain: "PDFMetadataMatcher", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output]) }
        return output
    }
    static func metadata(_ url: URL) throws -> [String: String] {
        let text = try run("exiftool", ["-j", "-a", "-G1", "-s", url.path])
        guard let data = text.data(using: .utf8), let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], let dict = array.first else { return [:] }
        var result = dict.reduce(into: [String: String]()) { out, pair in
            out[pair.key] = String(describing: pair.value)
        }
        let xattrs = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        result["Filesystem:Created"] = xattrs?.creationDate?.description ?? ""
        result["Filesystem:Modified"] = xattrs?.contentModificationDate?.description ?? ""
        if let signature = try? run("pdfsig", [url.path]) {
            result["Signature:Status"] = signature.contains("Signature #") ? "SIGNED — protected from metadata matching" : "No signature reported"
        } else {
            result["Signature:Status"] = "Unknown — signature check unavailable"
        }
        result["PDF:StructureCheck"] = (try? run("qpdf", ["--check", url.path]))?.contains("No syntax or stream encoding errors") == true ? "Valid" : "Check unavailable or warnings"
        return result
    }
    static let editableTags: [String: String] = [
        "Author": "PDF:Author",
        "Title": "PDF:Title",
        "Subject": "PDF:Subject",
        "Keywords": "PDF:Keywords",
        "Creator": "PDF:Creator",
        "Producer": "PDF:Producer",
        "Created": "PDF:CreateDate",
        "Modified": "PDF:ModifyDate",
        "XMP Creator Tool": "XMP-xmp:CreatorTool",
        "XMP Producer": "XMP-pdf:Producer",
        "XMP Created": "XMP-xmp:CreateDate",
        "XMP Modified": "XMP-xmp:ModifyDate",
        "XMP Metadata Date": "XMP-xmp:MetadataDate",
        "XMP Format": "XMP-dc:Format",
        "XMP Description": "XMP-dc:Description",
        "XMP Rights": "XMP-dc:Rights",
        "XMP Label": "XMP-xmp:Label"
    ]

    static func match(source: URL, destination: URL, values: [String: String]) throws -> URL {
        let a = try metadata(source), b = try metadata(destination)
        guard a["Signature:Status"]?.hasPrefix("No signature") == true,
              b["Signature:Status"]?.hasPrefix("No signature") == true else {
            throw NSError(domain: "PDFMetadataMatcher", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Signed PDFs are inspection-only. Editing metadata can invalidate signatures."
            ])
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = destination.deletingPathExtension().lastPathComponent + ".matched.pdf"
        guard panel.runModal() == .OK, let output = panel.url else {
            throw NSError(domain: "PDFMetadataMatcher", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Save cancelled."
            ])
        }
        guard output != destination && output != source else {
            throw NSError(domain: "PDFMetadataMatcher", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Choose a new output path; source and target are preserved."
            ])
        }
        try FileManager.default.copyItem(at: destination, to: output)
        var args = ["-overwrite_original"]
        for (name, tag) in editableTags.sorted(by: { $0.key < $1.key }) {
            if let value = values[name] {
                args.append("-\(tag)=\(value)")
            }
        }
        if args.count > 1 {
            args.append(output.path)
            do { _ = try run("exiftool", args) }
            catch { try? FileManager.default.removeItem(at: output); throw error }
        }
        do { _ = try run("qpdf", ["--check", output.path]) }
        catch { try? FileManager.default.removeItem(at: output); throw error }
        return output
    }
}

@MainActor final class Model: ObservableObject {
    @Published var source: URL?
    @Published var destination: URL?
    @Published var fields: [Field] = []
    @Published var edits: [String: String] = [:]
    @Published var message = "Choose a source and a target PDF to begin."
    @Published var busy = false
    @Published var showAll = false
    @Published var search = ""
    @Published var onlyDifferences = false

    var editableNames: [String] {
        ["Author", "Title", "Subject", "Keywords", "Creator", "Producer",
         "Created", "Modified", "XMP Creator Tool", "XMP Producer",
         "XMP Created", "XMP Modified", "XMP Metadata Date", "XMP Format",
         "XMP Description", "XMP Rights", "XMP Label"]
    }
    @Published var sourceEdits: [String: String] = [:]
    func tagKey(_ name: String) -> String { PDFTools.editableTags[name] ?? "PDF:" + name }
    var sourceValues: [String: String] = [:]
    var destinationValues: [String: String] = [:]
    var isSigned: Bool {
        (sourceValues["Signature:Status"] ?? "").contains("SIGNED") ||
        (destinationValues["Signature:Status"] ?? "").contains("SIGNED")
    }
    var visibleFields: [Field] {
        fields.filter { row in
            (!onlyDifferences || !row.matches) &&
            (search.isEmpty || row.id.localizedCaseInsensitiveContains(search) ||
             row.source.localizedCaseInsensitiveContains(search) ||
             row.destination.localizedCaseInsensitiveContains(search))
        }
    }
    func assign(_ url: URL, source isSource: Bool) {
        guard url.pathExtension.lowercased() == "pdf" else { message = "Only PDF files are supported."; return }
        if isSource { source = url } else { destination = url }
        compare()
    }
    func choose(source isSource: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            assign(url, source: isSource)
        }
    }
    func compare() {
        guard let source, let destination else { return }
        busy = true
        do {
            let a = try PDFTools.metadata(source)
            let b = try PDFTools.metadata(destination)
            sourceValues = a
            destinationValues = b
            let keys = Set(a.keys).union(b.keys).sorted()
            fields = keys.map { Field(id: $0, source: a[$0] ?? "—", destination: b[$0] ?? "—") }
            edits = Dictionary(uniqueKeysWithValues: editableNames.map { name in
                (name, b[tagKey(name)] ?? "")
            })
            sourceEdits = Dictionary(uniqueKeysWithValues: editableNames.map { name in
                (name, a[tagKey(name)] ?? "")
            })
            message = "Compared \(fields.count) fields; \(fields.filter { !$0.matches }.count) differences."
        } catch { message = error.localizedDescription }
        busy = false
    }
    func matchAll() {
        for name in editableNames {
            edits[name] = sourceEdits[name] ?? ""
        }
        message = "All supported source fields staged. Review the target values, then Save Copy."
    }
    func save() {
        guard let source, let destination else { return }
        busy = true
        do {
            let output = try PDFTools.match(source: source, destination: destination, values: edits)
            message = "Saved: \(output.path)"
        } catch { message = error.localizedDescription }
        busy = false
    }
}

struct PDFPane: View {
    @ObservedObject var model: Model
    let isSource: Bool
    @State private var targeted = false

    private var url: URL? { isSource ? model.source : model.destination }
    private var title: String { isSource ? "Source" : "Target" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: isSource ? "doc.text.magnifyingglass" : "square.and.pencil")
                    .foregroundStyle(.secondary)
                Text(title).font(.title2.weight(.semibold))
                Spacer()
                Button("Choose PDF…") { model.choose(source: isSource) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Button { model.choose(source: isSource) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.richtext").font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(url?.lastPathComponent ?? "Drop a PDF here")
                            .font(.headline).lineLimit(2)
                        Text(url == nil ? "Or click to browse" : url!.path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "arrow.down.doc").foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, minHeight: 92)
                .contentShape(RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .modifier(GlassPanel(active: targeted))
            .padding(.horizontal, 18)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { value, _ in
                    guard let url = value else { return }
                    DispatchQueue.main.async { model.assign(url, source: isSource) }
                }
                return true
            }

            HStack {
                Text("EDITABLE FIELDS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if url != nil { Text("\(model.editableNames.count) fields").font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 15) {
                    ForEach(model.editableNames, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name).font(.subheadline.weight(.medium))
                            TextField("Not specified", text: Binding(
                                get: { isSource ? (model.sourceEdits[name] ?? "") : (model.edits[name] ?? "") },
                                set: { newValue in
                                    if isSource { model.sourceEdits[name] = newValue }
                                    else { model.edits[name] = newValue }
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .disabled(url == nil || model.isSigned)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct GlassPanel: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 2)
                }
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(active ? Color.accentColor : Color.secondary.opacity(0.15), lineWidth: active ? 2 : 1)
                }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    @State private var showInspector = false

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                PDFPane(model: model, isSource: true)
                PDFPane(model: model, isSource: false)
            }
            if showInspector && model.source != nil && model.destination != nil {
                Divider()
                VStack(spacing: 8) {
                    HStack {
                        Text("Complete Metadata Comparison").font(.headline)
                        Spacer()
                        Toggle("Differences only", isOn: $model.onlyDifferences).toggleStyle(.checkbox)
                        TextField("Search", text: $model.search).frame(width: 220)
                    }
                    Table(model.visibleFields) {
                        TableColumn("Field", value: \.id).width(min: 170)
                        TableColumn("Source", value: \.source).width(min: 220)
                        TableColumn("Target", value: \.destination).width(min: 220)
                    }
                }
                .padding(12)
                .frame(minHeight: 210, idealHeight: 300)
            }
            Divider()
            HStack(spacing: 12) {
                Image(systemName: model.isSigned ? "lock.shield" : "info.circle")
                    .foregroundColor(model.isSigned ? .orange : .secondary)
                Text(model.isSigned ? "Signed PDF: inspection only. Editing could invalidate signatures." : model.message)
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .font(.caption)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(minWidth: 920, minHeight: 640)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.matchAll()
                } label: {
                    Label("Match All", systemImage: "arrow.right")
                }
                .disabled(model.source == nil || model.destination == nil || model.isSigned)

                Button {
                    model.save()
                } label: {
                    Label("Save Copy", systemImage: "square.and.arrow.down")
                }
                .disabled(model.source == nil || model.destination == nil || model.isSigned || model.busy)
                .buttonStyle(.borderedProminent)

                Button {
                    showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .disabled(model.source == nil || model.destination == nil)

                Button {
                    model.compare()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.source == nil || model.destination == nil)
            }
        }
    }
}

@main struct PDFMetadataMatcherApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowStyle(.automatic)
            .commands { CommandGroup(replacing: .newItem) { } }
    }
}
