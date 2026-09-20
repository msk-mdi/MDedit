import Foundation
import MarkdownKit

/// `MdEdit --render file.md` prints HTML and exits, so the renderer can be
/// checked without launching a window.
enum CommandLineRenderer {
    static func run(path: String) {
        let url = URL(fileURLWithPath: path)
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            var renderer = HTMLRenderer()
            renderer.baseURL = url
            print(renderer.render(markdown: text))
        } catch {
            FileHandle.standardError.write(Data("mdedit: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
