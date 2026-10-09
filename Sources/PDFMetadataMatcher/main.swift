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
        let signature = (try? run("pdfsig", [url.path])) ?? "Signature check unavailable"
        result["Signature:Status"] = signature.contains("Signature #") ? "SIGNED — protected from metadata matching" : "No signature reported"
        result["PDF:StructureCheck"] = (try? run("qpdf", ["--check", url.path]))?.contains("No syntax or stream encoding errors") == true ? "Valid" : "Check unavailable or warnings"
        return result
    }
    static let editableTags: [String: String] = [
        "Author": "PDF:Author",
        "Title": "PDF:Title",
        "Subject": "PDF:Subject",
        "Keywords": "PDF:Keywords"
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
                args.append("-\\(tag)=\\(value)")
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

    var editableNames: [String] { ["Author", "Title", "Subject", "Keywords"] }
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
    func choose(source isSource: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if isSource { source = url } else { destination = url }
            compare()
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
                (name, b["PDF:" + name] ?? "")
            })
            message = "Compared \\(fields.count) fields; \\(fields.filter { !$0.matches }.count) differences."
        } catch { message = error.localizedDescription }
        busy = false
    }
    func matchAll() {
        for name in editableNames {
            edits[name] = sourceValues["PDF:" + name] ?? ""
        }
        message = "Source values staged. Review them, then choose Save Copy."
    }
    func save() {
        guard let source, let destination else { return }
        busy = true
        do {
            let output = try PDFTools.match(source: source, destination: destination, values: edits)
            message = "Saved: \\(output.path)"
        } catch { message = error.localizedDescription }
        busy = false
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    var body: some View {
        VStack(spacing: 0) {
            if model.source == nil || model.destination == nil {
                VStack(spacing: 20) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 54, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                    Text("Compare PDF Metadata").font(.largeTitle.weight(.semibold))
                    Text("Choose a source PDF and a target PDF to inspect their metadata.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        filePicker("Source PDF", url: model.source) { model.choose(source: true) }
                        filePicker("Target PDF", url: model.destination) { model.choose(source: false) }
                    }
                    .frame(maxWidth: 760)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 16) {
                        filePicker("Source", url: model.source) { model.choose(source: true) }
                        filePicker("Target", url: model.destination) { model.choose(source: false) }
                    }
                    .padding()
                    Divider()
                    HStack {
                        Text("Editable Metadata").font(.title3.weight(.semibold))
                        Spacer()
                        Button("Match") { model.matchAll() }
                            .disabled(model.isSigned)
                        Button("Save Copy") { model.save() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.isSigned)
                    }
                    .padding(.horizontal)
                    .padding(.top, 14)
                    if model.isSigned {
                        Label("A digital signature was detected. This document is inspection-only.", systemImage: "signature")
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    Form {
                        ForEach(model.editableNames, id: \.self) { name in
                            HStack(spacing: 16) {
                                Text(name).frame(width: 90, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Source").font(.caption).foregroundStyle(.secondary)
                                    Text(model.sourceValues["PDF:" + name] ?? "Not set")
                                        .textSelection(.enabled)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Target").font(.caption).foregroundStyle(.secondary)
                                    TextField(name, text: Binding(
                                        get: { model.edits[name] ?? "" },
                                        set: { model.edits[name] = $0 }
                                    ))
                                    .disabled(model.isSigned)
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .frame(height: 310)
                    Divider()
                    HStack {
                        Text("All Detected Metadata").font(.headline)
                        Spacer()
                        Toggle("Differences only", isOn: $model.onlyDifferences).toggleStyle(.checkbox)
                        TextField("Search fields", text: $model.search).frame(width: 210)
                    }
                    .padding()
                    Table(model.visibleFields) {
                        TableColumn("Field", value: \.id).width(min: 170)
                        TableColumn("Source", value: \.source).width(min: 220)
                        TableColumn("Target", value: \.destination).width(min: 220)
                        TableColumn("Match") { field in
                            Image(systemName: field.matches ? "checkmark.circle" : "circle.dotted")
                                .foregroundColor(field.matches ? .green : .secondary)
                        }.width(60)
                    }
                }
            }
            Divider()
            HStack {
                Text(model.message).lineLimit(2).textSelection(.enabled)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(10)
        }
        .frame(minWidth: 940, minHeight: 680)
        .toolbar {
            ToolbarItemGroup {
                Button("Source", systemImage: "doc") { model.choose(source: true) }
                Button("Target", systemImage: "doc.badge.plus") { model.choose(source: false) }
                Button("Refresh", systemImage: "arrow.clockwise") { model.compare() }
                    .disabled(model.source == nil || model.destination == nil)
            }
        }
    }

    func filePicker(_ title: String, url: URL?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Button(action: action) {
                Label(url?.lastPathComponent ?? "Choose PDF…", systemImage: "doc.text")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }
}

@main struct PDFMetadataMatcherApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
