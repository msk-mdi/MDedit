import AppKit
import MarkdownKit

/// What VoiceOver reads for a stretch of the editor: the text as drawn, not
/// the markdown under it.
///
/// Concealed markers are skipped, as they have no glyphs; bullets, task boxes
/// and emoji are read as what they are drawn as; a typeset formula reads as
/// its TeX, and an image line announces itself before its caption. Ranges
/// stay in the storage's own offsets, so the caret and selection that
/// assistive apps see still match the text.
enum SpokenText {
    static func attributedString(of storage: NSAttributedString, in range: NSRange) -> NSAttributedString {
        let range = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        let text = storage.string as NSString
        let result = NSMutableAttributedString()

        func append(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            guard !string.isEmpty else { return }
            var kept: [NSAttributedString.Key: Any] = [:]
            kept[.font] = attributes[.font]
            if let destination = attributes[.mdLink] as? String, let url = URL(string: destination) {
                kept[.link] = url
            }
            result.append(NSAttributedString(string: string, attributes: kept))
        }

        storage.enumerateAttributes(in: range) { attributes, run, _ in
            if attributes[.mdFolded] != nil { return }

            // An image line says so once, where the image's run begins.
            if let image = attributes[.mdImage] as? InlineImage, !image.below,
               run.location == 0 || storage.attribute(.mdImage, at: run.location - 1, effectiveRange: nil) as? InlineImage !== image {
                append(image.label.isEmpty
                    ? String(localized: "Image, ")
                    : String(localized: "Image: \(image.label). "), [:])
            }
            if let math = attributes[.mdMath] as? InlineImage {
                append(math.label, attributes)
                return
            }
            if attributes[.mdConcealed] != nil { return }
            if let color = attributes[.foregroundColor] as? NSColor, color == .clear { return }
            if let emoji = attributes[.mdEmoji] as? String {
                append(emoji, attributes)
                return
            }
            if let raw = attributes[.mdMarker] as? Int, let kind = MarkerKind(rawValue: raw) {
                switch kind {
                case .listBullet where "-*+".contains(text.substring(with: NSRange(location: run.location, length: 1))):
                    append("•" + text.substring(with: NSRange(location: run.location + 1, length: run.length - 1)), attributes)
                    return
                case .taskChecked:
                    append(String(localized: "checked"), attributes)
                    return
                case .taskUnchecked:
                    append(String(localized: "unchecked"), attributes)
                    return
                default:
                    break
                }
            }
            append(text.substring(with: run), attributes)
        }
        return result
    }

    static func string(of storage: NSAttributedString, in range: NSRange) -> String {
        attributedString(of: storage, in: range).string
    }
}
