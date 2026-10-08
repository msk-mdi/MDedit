import Foundation
import MarkdownKit

/// `MdEdit --render [file | -] [options]` prints HTML and exits, so documents
/// can be converted in scripts and the renderer checked without a window.
@MainActor
enum CommandLineRenderer {
    static let usage = """
    usage: MdEdit --render [file | -] [--output file] [--standalone] [--theme name]
                           [--toc] [--number-headings] [--embed-images]

    Renders markdown to HTML. Reads standard input when the file is - or left out.

      -o, --output file    write to a file instead of standard output
      -s, --standalone     a whole page with the theme's stylesheet, not just the body
      --theme name         the theme for --standalone (default: the editor's)
      --toc                add a table of contents
      --number-headings    number headings 1, 1.1, 1.2…
      --embed-images       put local images in the page as data: URIs

    """

    struct Invocation: Equatable {
        var input: String?
        var output: String?
        var standalone = false
        var themeName: String?
        var tableOfContents = false
        var numberHeadings = false
        var embedImages = false
    }

    enum Failure: LocalizedError, Equatable {
        case usage(String)

        var errorDescription: String? {
            switch self {
            case let .usage(message): message
            }
        }
    }

    /// The arguments after `--render`.
    static func parse(_ arguments: [String]) throws -> Invocation {
        var invocation = Invocation()
        var remaining = arguments[...]
        func value(for flag: String) throws -> String {
            guard let value = remaining.popFirst() else { throw Failure.usage("\(flag) needs a value") }
            return value
        }
        while let argument = remaining.popFirst() {
            switch argument {
            case "-o", "--output": invocation.output = try value(for: argument)
            case "-s", "--standalone": invocation.standalone = true
            case "--theme": invocation.themeName = try value(for: argument)
            case "--toc": invocation.tableOfContents = true
            case "--number-headings": invocation.numberHeadings = true
            case "--embed-images": invocation.embedImages = true
            case "-h", "--help": throw Failure.usage("")
            case "-": invocation.input = nil
            default:
                guard !argument.hasPrefix("-") else { throw Failure.usage("unknown option \(argument)") }
                guard invocation.input == nil else { throw Failure.usage("one input file at a time") }
                invocation.input = argument
            }
        }
        return invocation
    }

    /// The HTML for an invocation's markdown.
    static func render(_ markdown: String, invocation: Invocation, baseURL: URL?) -> String {
        let settings = Settings()
        var options = ExportOptions()
        options.themeName = invocation.themeName
        options.tableOfContents = invocation.tableOfContents
        options.embedImages = invocation.embedImages
        options.offlineScripts = true
        var renderer = Exporter.renderer(baseURL: baseURL, options: options, settings: settings)
        renderer.numberHeadings = invocation.numberHeadings || settings.numberHeadings
        let source = invocation.tableOfContents ? Exporter.withTableOfContents(markdown, extensions: settings.extensions) : markdown
        guard invocation.standalone else { return renderer.render(markdown: source) }
        let title = baseURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return renderer.renderDocument(
            markdown: source,
            title: title,
            css: Exporter.stylesheet(themeName: invocation.themeName, settings: settings)
        )
    }

    static func run(arguments: [String]) -> Int32 {
        do {
            let invocation = try parse(arguments)
            let markdown: String
            let baseURL: URL?
            if let input = invocation.input {
                let url = URL(fileURLWithPath: input)
                markdown = try FileFormat.decode(Data(contentsOf: url)).text
                baseURL = url
            } else {
                markdown = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                // Relative images resolve against where the command runs.
                baseURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("stdin.md")
            }
            let html = render(markdown, invocation: invocation, baseURL: baseURL)
            if let output = invocation.output {
                try html.write(to: URL(fileURLWithPath: output), atomically: true, encoding: .utf8)
            } else {
                FileHandle.standardOutput.write(Data(html.utf8))
            }
            return 0
        } catch let Failure.usage(message) {
            if !message.isEmpty { FileHandle.standardError.write(Data("mdedit: \(message)\n".utf8)) }
            FileHandle.standardError.write(Data(usage.utf8))
            return message.isEmpty ? 0 : 2
        } catch {
            FileHandle.standardError.write(Data("mdedit: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
