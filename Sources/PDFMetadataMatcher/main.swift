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
    static func match(source: URL, destination: URL) throws -> URL {
        let s = try metadata(source), d = try metadata(destination)
        guard s["Signature:Status"]?.hasPrefix("No signature") == true,
              d["Signature:Status"]?.hasPrefix("No signature") == true else {
            throw NSError(domain: "PDFMetadataMatcher", code: 2, userInfo: [NSLocalizedDescriptionKey: "Signed PDFs are comparison-only. A metadata rewrite can invalidate or misrepresent signature coverage."])
        }
        let output = destination.deletingPathExtension().appendingPathExtension("matched.pdf")
        if FileManager.default.fileExists(atPath: output.path) { throw NSError(domain: "PDFMetadataMatcher", code: 3, userInfo: [NSLocalizedDescriptionKey: "Output already exists: \(output.lastPathComponent). Rename it before retrying."]) }
        try FileManager.default.copyItem(at: destination, to: output)
        // Only descriptive fields, not signatures, provenance, timestamps or software origin.
        let tags = ["PDF:Title", "PDF:Subject", "PDF:Keywords", "PDF:Author"]
        var args = ["-overwrite_original"]
        for tag in tags {
            if let value = s[tag], !value.isEmpty { args.append("-\(tag)=\(value)") }
        }
        if args.count > 1 {
            args.append(output.path)
            do { _ = try run("exiftool", args) } catch { try? FileManager.default.removeItem(at: output); throw error }
        }
        _ = try run("qpdf", ["--check", output.path])
        return output
    }
}

@MainActor final class Model: ObservableObject {
    @Published var source: URL?
    @Published var destination: URL?
    @Published var fields: [Field] = []
    @Published var message = "Select both PDFs to compare."
    @Published var busy = false
    func choose(source isSource: Bool) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            if isSource { source = url } else { destination = url }
            compare()
        }
    }
    func compare() {
        guard let source, let destination else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let a = try PDFTools.metadata(source), b = try PDFTools.metadata(destination)
                let keys = Set(a.keys).union(b.keys).sorted()
                let rows = keys.map { Field(id: $0, source: a[$0] ?? "—", destination: b[$0] ?? "—") }
                DispatchQueue.main.async { self.fields = rows; self.message = "Compared \(rows.count) fields; \(rows.filter { !$0.matches }.count) differences."; self.busy = false }
            } catch {
                DispatchQueue.main.async { self.message = error.localizedDescription; self.busy = false }
            }
        }
    }
    func match() {
        guard let source, let destination else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try PDFTools.match(source: source, destination: destination)
                DispatchQueue.main.async { self.message = "Created \(url.path)"; self.busy = false }
            } catch {
                DispatchQueue.main.async { self.message = error.localizedDescription; self.busy = false }
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = Model()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PDF Metadata Matcher").font(.largeTitle.bold())
            HStack {
                Button("Choose Source PDF") { model.choose(source: true) }
                Text(model.source?.lastPathComponent ?? "No source selected").lineLimit(1)
            }
            HStack {
                Button("Choose Destination PDF") { model.choose(source: false) }
                Text(model.destination?.lastPathComponent ?? "No destination selected").lineLimit(1)
            }
            HStack {
                Button("Compare") { model.compare() }.disabled(model.source == nil || model.destination == nil || model.busy)
                Button("Match Metadata (Unsigned PDFs)") { model.match() }.disabled(model.source == nil || model.destination == nil || model.busy)
                if model.busy { ProgressView().controlSize(.small) }
            }
            Text(model.message).font(.caption).textSelection(.enabled)
            Table(model.fields) {
                TableColumn("Field", value: \.id).width(min: 180)
                TableColumn("Source", value: \.source).width(min: 240)
                TableColumn("Destination", value: \.destination).width(min: 240)
                TableColumn("Match") { field in Text(field.matches ? "✓" : "≠") }.width(55)
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 600)
    }
}

@main struct PDFMetadataMatcherApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
