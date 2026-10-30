import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 메모에 붙여 넣은 이미지: 메모 폴더의 attachments/에 파일로 두고, 메모에는 ![](경로) 링크만
@MainActor
enum ImageAttachments {
    static let folderName = "attachments"

    /// 붙여 넣을 게 이미지면 저장하고 넣을 글자를 돌려줌. 글자를 복사한 거면 nil (보통 붙여넣기)
    static func paste(from pasteboard: NSPasteboard, into document: NoteDocument) -> String? {
        guard let root = document.library?.root else { return nil }
        let folder = root.appendingPathComponent(folderName, isDirectory: true)
        let noteFolder = document.url.deletingLastPathComponent()

        // Finder에서 복사한 이미지 파일
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]) as? [URL]) ?? []
        if !files.isEmpty {
            let links = files.compactMap { file -> String? in
                guard let saved = try? save(folder: folder, name: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension, write: { try FileManager.default.copyItem(at: file, to: $0) })
                else { return nil }
                return link(alt: file.deletingPathExtension().lastPathComponent, to: saved, from: noteFolder)
            }
            return links.isEmpty ? nil : links.joined(separator: "\n")
        }

        // 화면 캡처·웹에서 복사한 그림. 서식 있는 글(문서에서 복사한 글자)에 딸려 온 그림은 글자로 붙임
        let types = pasteboard.types ?? []
        guard !types.contains(.rtf), !types.contains(.rtfd), !types.contains(.html) || pasteboard.string(forType: .string) == nil,
              let data = pngData(from: pasteboard)
        else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        guard let saved = try? save(folder: folder, name: "image-" + formatter.string(from: Date()), ext: "png", write: { try data.write(to: $0) })
        else { return nil }
        return link(alt: "이미지", to: saved, from: noteFolder)
    }

    private static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    /// 겹치지 않는 이름으로 저장 (이름.png, 이름-2.png, …)
    private static func save(folder: URL, name: String, ext: String, write: (URL) throws -> Void) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var number = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(name)-\(number)").appendingPathExtension(ext)
            number += 1
        }
        try write(destination)
        return destination
    }

    /// 메모 위치 기준 상대 경로로 ![설명](경로). 공백·괄호는 링크가 끊기지 않게 %로
    private static func link(alt: String, to file: URL, from noteFolder: URL) -> String {
        let target = file.standardizedFileURL.pathComponents
        let base = noteFolder.standardizedFileURL.pathComponents
        let common = zip(target, base).prefix { $0 == $1 }.count
        let relative = (Array(repeating: "..", count: base.count - common) + target[common...]).joined(separator: "/")
        let escaped = relative
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
        let cleanAlt = alt.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        return "![\(cleanAlt)](\(escaped))"
    }

    /// 링크에 적힌 주소 → 파일이나 웹 주소. 상대 경로는 메모가 있는 폴더 기준
    static func resolve(_ address: String, relativeTo note: URL) -> URL? {
        if address.hasPrefix("http://") || address.hasPrefix("https://") { return URL(string: address) }
        let path = address.removingPercentEncoding ?? address
        if path.hasPrefix("file://") { return URL(string: address) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return note.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }
}

/// 이미지 칩을 누르면 뜨는 말풍선: 그림 + 이름, 누르면 기본 앱으로 열기
struct ImagePreview: View {
    let source: URL
    @State private var image: NSImage?
    @State private var failed = false

    private static let maxSize = CGSize(width: 520, height: 420)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                let size = Self.fitted(image.size)
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { open() }
                    .help("기본 앱으로 열기")
            } else if failed {
                Label("이미지를 열 수 없어요", systemImage: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .frame(width: 220, height: 80)
            } else {
                ProgressView().frame(width: 220, height: 120)
            }
            HStack {
                Text(source.isFileURL ? source.lastPathComponent : source.absoluteString)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Button("열기", action: open).controlSize(.small)
            }
            .frame(maxWidth: image.map { Self.fitted($0.size).width } ?? 220)
        }
        .padding(10)
        .task { await load() }
    }

    private func open() {
        NSWorkspace.shared.open(source)
    }

    private func load() async {
        if source.isFileURL {
            image = NSImage(contentsOf: source)
        } else if let (data, _) = try? await URLSession.shared.data(from: source) {
            image = NSImage(data: data)
        }
        failed = image == nil
    }

    /// 비율을 지키며 최대 크기 안으로 (작은 그림은 그대로)
    private static func fitted(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 220, height: 120) }
        let scale = min(1, maxSize.width / size.width, maxSize.height / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }
}
