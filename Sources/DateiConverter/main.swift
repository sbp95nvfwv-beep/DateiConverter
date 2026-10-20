import SwiftUI
import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import CoreGraphics
import CoreText

@main
struct DateiConverterApp: App {
    var body: some Scene {
        WindowGroup { ContentView().frame(minWidth: 640, minHeight: 650) }
            .windowResizability(.contentSize)
    }
}

private enum FileKind: String, Hashable {
    case image = "Bild", audio = "Audio", video = "Video", document = "Dokument"
}

private enum ConverterError: LocalizedError {
    case unsupported, noImage, emptyDocument, exportFailed(String)
    var errorDescription: String? {
        switch self {
        case .unsupported: "Diese Umwandlung wird nicht unterstützt. Wähle ein anderes Zielformat."
        case .noImage: "Die Bilddatei konnte nicht gelesen werden."
        case .emptyDocument: "Aus der Datei konnte kein Text gelesen werden."
        case .exportFailed(let reason): reason
        }
    }
}

private enum ConversionEngine {
    static let formats: [FileKind: [String]] = [
        .image: ["jpg", "png", "tiff", "bmp", "gif"],
        .audio: ["m4a", "wav", "aiff", "caf"],
        .video: ["mp4", "mov", "m4v"],
        .document: ["txt", "rtf", "html", "pdf"]
    ]

    static func kind(for ext: String) -> FileKind? {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "tiff", "tif", "bmp", "gif": .image
        case "mp3", "m4a", "aac", "wav", "aiff", "aif", "caf": .audio
        case "mp4", "mov", "m4v": .video
        case "txt", "rtf", "rtfd", "html", "htm", "doc", "docx", "odt", "pdf": .document
        default: nil
        }
    }

    static func convert(input: URL, output: URL, format: String, kind: FileKind) async throws {
        switch kind {
        case .image: try convertImage(input: input, output: output, format: format)
        case .audio:
            if format == "m4a" { try await exportAudioAsM4A(input: input, output: output) }
            else { try convertPCM(input: input, output: output, format: format) }
        case .video: try await convertVideo(input: input, output: output, format: format)
        case .document: try convertDocument(input: input, output: output, format: format)
        }
    }

    private static func convertImage(input: URL, output: URL, format: String) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConverterError.noImage }
        let type: CFString
        switch format {
        case "jpg": type = UTType.jpeg.identifier as CFString
        case "png": type = UTType.png.identifier as CFString
        case "tiff": type = UTType.tiff.identifier as CFString
        case "bmp": type = UTType.bmp.identifier as CFString
        case "gif": type = UTType.gif.identifier as CFString
        default: throw ConverterError.unsupported
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw ConverterError.exportFailed("Das Zielformat konnte nicht erstellt werden.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConverterError.exportFailed("Das Bild konnte nicht gespeichert werden.")
        }
    }

    private static func convertPCM(input: URL, output: URL, format: String) throws {
        let inputFile = try AVAudioFile(forReading: input)
        let channels = Int(inputFile.processingFormat.channelCount)
        let settings: [String: Any]
        switch format {
        case "wav", "caf":
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: inputFile.processingFormat.sampleRate,
                        AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case "aiff":
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: inputFile.processingFormat.sampleRate,
                        AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        default: throw ConverterError.unsupported
        }
        let outputFile = try AVAudioFile(forWriting: output, settings: settings)
        let capacity: AVAudioFrameCount = 8192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat, frameCapacity: capacity) else {
            throw ConverterError.exportFailed("Der Audio-Puffer konnte nicht angelegt werden.")
        }
        while true {
            try inputFile.read(into: buffer, frameCount: capacity)
            if buffer.frameLength == 0 { break }
            try outputFile.write(from: buffer)
        }
    }

    private static func exportAudioAsM4A(input: URL, output: URL) async throws {
        let asset = AVURLAsset(url: input)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw ConverterError.exportFailed("Dieses Audio kann nicht als M4A exportiert werden.")
        }
        try await export(exporter, to: output, type: .m4a)
    }

    private static func convertVideo(input: URL, output: URL, format: String) async throws {
        let asset = AVURLAsset(url: input)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw ConverterError.exportFailed("Dieses Video kann auf diesem Mac nicht exportiert werden.")
        }
        let type: AVFileType
        switch format {
        case "mp4": type = .mp4
        case "mov": type = .mov
        case "m4v": type = .m4v
        default: throw ConverterError.unsupported
        }
        try await export(exporter, to: output, type: type)
    }

    private static func export(_ exporter: AVAssetExportSession, to output: URL, type: AVFileType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            exporter.outputURL = output
            exporter.outputFileType = type
            exporter.shouldOptimizeForNetworkUse = true
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: continuation.resume()
                case .failed: continuation.resume(throwing: exporter.error ?? ConverterError.exportFailed("Der Export ist fehlgeschlagen."))
                case .cancelled: continuation.resume(throwing: ConverterError.exportFailed("Der Export wurde abgebrochen."))
                default: continuation.resume(throwing: ConverterError.exportFailed("Der Export konnte nicht abgeschlossen werden."))
                }
            }
        }
    }

    private static func convertDocument(input: URL, output: URL, format: String) throws {
        let text: String
        if input.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: input) else { throw ConverterError.emptyDocument }
            text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n\n")
        } else {
            text = try NSAttributedString(url: input, options: [:], documentAttributes: nil).string
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConverterError.emptyDocument }
        let attributed = NSAttributedString(string: text)
        let range = NSRange(location: 0, length: attributed.length)
        switch format {
        case "txt": try Data(text.utf8).write(to: output)
        case "rtf":
            let data = try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: output)
        case "html":
            let data = try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
            try data.write(to: output)
        case "pdf":
            try writePDF(attributed, to: output)
        default: throw ConverterError.unsupported
        }
    }

    private static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &page, nil) else {
            throw ConverterError.exportFailed("Die PDF-Datei konnte nicht erstellt werden.")
        }
        let styled = NSAttributedString(string: text.string, attributes: [.font: NSFont.systemFont(ofSize: 11)])
        let framesetter = CTFramesetterCreateWithAttributedString(styled as CFAttributedString)
        var offset = 0
        while offset < styled.length {
            context.beginPDFPage(nil)
            let textRect = CGRect(x: 48, y: 48, width: 499, height: 746)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.endPDFPage(); context.closePDF()
                throw ConverterError.exportFailed("Der Text konnte nicht in das PDF geschrieben werden.")
            }
            offset += visible.length
            context.endPDFPage()
        }
        context.closePDF()
    }
}

struct ContentView: View {
    @State private var inputURL: URL?
    @State private var outputFormat = ""
    @State private var outputFolder: URL?
    @State private var isConverting = false
    @State private var resultText = "Wähle eine Datei aus, um passende Zielformate zu sehen."
    @State private var resultIsError = false

    private var fileKind: FileKind? { inputURL.flatMap { ConversionEngine.kind(for: $0.pathExtension) } }
    private var availableFormats: [String] { fileKind.flatMap { ConversionEngine.formats[$0] } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 19) {
                fileCard
                if inputURL != nil {
                    formatsPanel
                    folderRow
                    Button(action: startConversion) {
                        HStack(spacing: 9) {
                            if isConverting { ProgressView().controlSize(.small).tint(.white) }
                            Text(isConverting ? "Wird umgewandelt …" : "Jetzt umwandeln")
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .font(.system(size: 15, weight: .semibold))
                        .background(Color(red: 0.16, green: 0.38, blue: 0.32), in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain).disabled(isConverting || outputFormat.isEmpty || fileKind == nil)
                    .opacity(isConverting || outputFormat.isEmpty || fileKind == nil ? 0.55 : 1)
                }
                resultBanner
                privacyNote
            }
            .padding(26).frame(maxWidth: 620)
            Spacer(minLength: 8)
        }
        .background(Color(red: 0.96, green: 0.97, blue: 0.95))
        .onChange(of: inputURL) { newValue in
            outputFolder = newValue?.deletingLastPathComponent()
            outputFormat = availableFormats.first ?? ""
            if newValue != nil && fileKind == nil {
                resultText = "Dieser Dateityp wird noch nicht unterstützt."; resultIsError = true
            } else if let fileKind {
                resultText = "\(fileKind.rawValue) erkannt. Wähle das gewünschte Zielformat."; resultIsError = false
            }
        }
        .onChange(of: fileKind) { _ in outputFormat = availableFormats.first ?? "" }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.16, green: 0.38, blue: 0.32)).frame(width: 42, height: 42)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("DateiConverter").font(.system(size: 17, weight: .bold)).foregroundStyle(Color(red: 0.09, green: 0.15, blue: 0.14))
                Text("Konvertierung direkt auf deinem Mac").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Label("Lokal", systemImage: "lock.fill").font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(red: 0.16, green: 0.38, blue: 0.32))
                .padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.8), in: Capsule())
        }
        .padding(.horizontal, 28).padding(.vertical, 19).background(.white)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1) }
    }

    private var fileCard: some View {
        VStack(spacing: 13) {
            Image(systemName: inputURL == nil ? "square.and.arrow.down" : iconName)
                .font(.system(size: 25, weight: .medium)).foregroundStyle(Color(red: 0.16, green: 0.38, blue: 0.32))
                .frame(width: 56, height: 56).background(Color(red: 0.91, green: 0.95, blue: 0.92), in: RoundedRectangle(cornerRadius: 17))
            if let inputURL {
                Text(inputURL.lastPathComponent).font(.system(size: 16, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                Text("\(fileSize(inputURL)) · \(fileKind?.rawValue ?? "Unbekannt")").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Andere Datei wählen", action: chooseFile).buttonStyle(.link).font(.system(size: 12, weight: .medium))
            } else {
                Text("Wähle eine Datei aus").font(.system(size: 19, weight: .semibold))
                Text("Bilder, Audio, Video oder Dokumente").font(.system(size: 13)).foregroundStyle(.secondary)
                Button(action: chooseFile) {
                    Text("Datei auswählen").font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Color(red: 0.16, green: 0.38, blue: 0.32), in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(.white)
                }.buttonStyle(.plain).padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 18)
        .background(.white, in: RoundedRectangle(cornerRadius: 17))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(Color(red: 0.86, green: 0.89, blue: 0.86), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private var formatsPanel: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("DATEITYP").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                Text(fileKind?.rawValue ?? "—").font(.system(size: 14, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 40).padding(.horizontal, 11)
                    .background(.white, in: RoundedRectangle(cornerRadius: 9))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("UMWANDELN IN").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                Picker("Zielformat", selection: $outputFormat) {
                    ForEach(availableFormats, id: \.self) { Text($0.uppercased()).tag($0) }
                }.labelsHidden().frame(height: 40).padding(.horizontal, 8).background(.white, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var folderRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").foregroundStyle(Color(red: 0.16, green: 0.38, blue: 0.32))
            VStack(alignment: .leading, spacing: 1) {
                Text("Speicherort").font(.system(size: 12, weight: .semibold))
                Text(outputFolder?.path ?? "Ordner auswählen").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Ändern") { chooseFolder() }.buttonStyle(.bordered).controlSize(.small)
        }.padding(12).background(.white, in: RoundedRectangle(cornerRadius: 11))
    }

    private var resultBanner: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: resultIsError ? "exclamationmark.circle.fill" : "checkmark.shield.fill")
                .foregroundStyle(resultIsError ? Color.red : Color(red: 0.16, green: 0.38, blue: 0.32))
            Text(resultText).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 10))
    }

    private var privacyNote: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            Text("Deine Dateien bleiben auf deinem Mac. Es wird nichts hochgeladen.").font(.system(size: 11))
        }.foregroundStyle(.secondary).frame(maxWidth: .infinity)
    }

    private var iconName: String {
        switch fileKind {
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .document: "doc.text"
        case .none: "doc"
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.title = "Datei auswählen"
        if panel.runModal() == .OK { inputURL = panel.url }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.title = "Speicherort auswählen"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }

    private func startConversion() {
        guard let inputURL, let fileKind, let folder = outputFolder else { return }
        let name = inputURL.deletingPathExtension().lastPathComponent
        var outputURL = folder.appendingPathComponent(name).appendingPathExtension(outputFormat)
        var suffix = 2
        while FileManager.default.fileExists(atPath: outputURL.path) {
            outputURL = folder.appendingPathComponent("\(name) (\(suffix))").appendingPathExtension(outputFormat)
            suffix += 1
        }
        isConverting = true; resultText = "Die Datei wird auf deinem Mac umgewandelt …"; resultIsError = false
        Task {
            do {
                try await ConversionEngine.convert(input: inputURL, output: outputURL, format: outputFormat, kind: fileKind)
                resultText = "Fertig: \(outputURL.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
            } catch {
                resultText = error.localizedDescription; resultIsError = true
                try? FileManager.default.removeItem(at: outputURL)
            }
            isConverting = false
        }
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let formatter = ByteCountFormatter(); formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
