import Foundation

/// What a tokenizer needs to know about one programming language.
///
/// Deliberately a data table rather than a grammar: fenced code blocks in a
/// markdown editor need to look right, not to compile.
public struct Language: Sendable {
    /// Canonical name, also used for equality.
    public let id: String

    public var keywords: Set<String> = []
    /// Types and built-in classes, coloured apart from keywords.
    public var types: Set<String> = []
    /// Constants and built-in values: `true`, `nil`, `NULL`, `self`.
    public var constants: Set<String> = []

    public var lineComments: [String] = []
    public var blockComment: (open: String, close: String)?
    /// Quote characters that start a single-line string.
    public var stringDelimiters: [Character] = ["\"", "'"] {
        didSet { stringDelimiterUnits = stringDelimiters.map { UInt16($0.unicodeScalars.first!.value) } }
    }

    /// The same delimiters as UTF-16 units, which is what the scanner compares.
    public private(set) var stringDelimiterUnits: [UInt16] = [0x22, 0x27]
    /// Triple-quoted strings that may span lines, as in Python.
    public var tripleQuotes: [String] = []
    public var escapeCharacter: Character? = "\\"

    /// `$name` and `${name}` are variables, as in shells and PHP.
    public var dollarVariables = false
    /// A leading `#` line is a preprocessor directive, as in C.
    public var preprocessorHash = false
    /// `"key":` is coloured as a key, as in JSON.
    public var jsonStyleKeys = false
    /// Tag-and-attribute markup, as in HTML and XML.
    public var markupTags = false
    /// Whole-line colouring by leading `+` / `-`, as in diffs.
    public var lineDiff = false
    /// An identifier immediately before `(` is a call.
    public var callsAreFunctions = true

    init(id: String) {
        self.id = id
    }

    /// Looks a language up by the fence's info string, e.g. ```` ```swift ````.
    public static func named(_ info: String) -> Language? {
        let token = info
            .split(separator: " ").first
            .map(String.init)?
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}.,"))
        guard let token, !token.isEmpty else { return nil }
        return registry[token]
    }
}

extension Language: Equatable {
    public static func == (lhs: Language, rhs: Language) -> Bool { lhs.id == rhs.id }
}

private func language(_ id: String, _ configure: (inout Language) -> Void) -> Language {
    var value = Language(id: id)
    configure(&value)
    return value
}

private let cKeywords: Set<String> = [
    "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern",
    "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static",
    "struct", "switch", "typedef", "union", "volatile", "while",
]

private let cTypes: Set<String> = [
    "bool", "char", "double", "float", "int", "long", "short", "signed", "unsigned", "void",
    "size_t", "ssize_t", "int8_t", "int16_t", "int32_t", "int64_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t", "FILE",
]

/// Every language the editor knows, by name and by common alias.
let registry: [String: Language] = {
    var table: [String: Language] = [:]

    func register(_ value: Language, aliases: [String] = []) {
        table[value.id] = value
        for alias in aliases { table[alias] = value }
    }

    register(language("c") { lang in
        lang.keywords = cKeywords
        lang.types = cTypes
        lang.constants = ["NULL", "true", "false"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.preprocessorHash = true
    }, aliases: ["h"])

    register(language("cpp") { lang in
        lang.keywords = cKeywords.union([
            "class", "namespace", "template", "typename", "public", "private", "protected",
            "virtual", "override", "final", "new", "delete", "try", "catch", "throw",
            "using", "friend", "operator", "explicit", "constexpr", "consteval", "noexcept",
            "co_await", "co_return", "co_yield", "concept", "requires", "mutable", "decltype",
        ])
        lang.types = cTypes.union([
            "string", "vector", "map", "set", "array", "pair", "unique_ptr", "shared_ptr",
            "wchar_t", "char8_t", "char16_t", "char32_t", "auto",
        ])
        lang.constants = ["nullptr", "true", "false", "this"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.preprocessorHash = true
    }, aliases: ["c++", "cc", "hpp", "cxx"])

    register(language("objective-c") { lang in
        lang.keywords = cKeywords.union([
            "@interface", "@implementation", "@end", "@property", "@synthesize", "@selector",
            "@protocol", "@class", "@autoreleasepool", "@synchronized", "@try", "@catch",
            "in", "self", "super",
        ])
        lang.types = cTypes.union(["id", "SEL", "IMP", "Class", "NSString", "NSArray", "NSDictionary", "instancetype", "BOOL"])
        lang.constants = ["nil", "Nil", "YES", "NO", "NULL"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.preprocessorHash = true
    }, aliases: ["objc", "m", "mm"])

    register(language("swift") { lang in
        lang.keywords = [
            "actor", "associatedtype", "as", "async", "await", "break", "case", "catch", "class",
            "continue", "default", "defer", "deinit", "do", "else", "enum", "extension",
            "fallthrough", "fileprivate", "for", "func", "guard", "if", "import", "in", "init",
            "inout", "internal", "is", "let", "lazy", "mutating", "nonisolated", "open",
            "operator", "override", "private", "protocol", "public", "repeat", "required",
            "return", "self", "static", "struct", "subscript", "super", "switch", "throw",
            "throws", "try", "typealias", "var", "where", "while", "some", "any", "final",
            "convenience", "indirect", "package", "borrowing", "consuming",
        ]
        lang.types = [
            "Int", "Double", "Float", "String", "Bool", "Character", "Array", "Dictionary",
            "Set", "Optional", "Result", "Data", "Date", "URL", "Task", "Error", "Void",
            "UInt", "CGFloat", "Range", "NSRange", "Self",
        ]
        lang.constants = ["true", "false", "nil"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.stringDelimiters = ["\""]
        lang.tripleQuotes = ["\"\"\""]
    })

    register(language("python") { lang in
        lang.keywords = [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
            "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
            "is", "lambda", "match", "case", "nonlocal", "not", "or", "pass", "raise", "return",
            "try", "while", "with", "yield",
        ]
        lang.types = [
            "int", "float", "str", "bool", "bytes", "list", "dict", "set", "tuple", "frozenset",
            "object", "type", "complex",
        ]
        lang.constants = ["True", "False", "None", "self", "cls", "__name__"]
        lang.lineComments = ["#"]
        lang.tripleQuotes = ["\"\"\"", "'''"]
    }, aliases: ["py", "python3"])

    register(language("bash") { lang in
        lang.keywords = [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while",
            "until", "do", "done", "in", "function", "time", "coproc", "return", "break",
            "continue", "local", "export", "readonly", "declare", "typeset", "unset", "shift",
            "source", "alias", "trap", "set",
        ]
        lang.types = [
            "echo", "printf", "read", "cd", "pwd", "ls", "cat", "grep", "sed", "awk", "cut",
            "sort", "uniq", "head", "tail", "find", "xargs", "curl", "wget", "git", "make",
            "sudo", "chmod", "chown", "mkdir", "rm", "cp", "mv", "touch", "test", "exit", "eval",
            "exec", "kill", "ps", "tar", "ssh", "scp", "docker", "swift", "python", "node", "npm",
        ]
        lang.constants = ["true", "false"]
        lang.lineComments = ["#"]
        lang.dollarVariables = true
        lang.stringDelimiters = ["\"", "'", "`"]
        lang.callsAreFunctions = false
    }, aliases: ["sh", "shell", "zsh", "fish", "console", "shell-session"])

    register(language("javascript") { lang in
        lang.keywords = [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
            "default", "delete", "do", "else", "export", "extends", "finally", "for", "function",
            "if", "import", "in", "instanceof", "let", "new", "of", "return", "static", "super",
            "switch", "this", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
            "get", "set",
        ]
        lang.types = [
            "Array", "Boolean", "Date", "Error", "Function", "JSON", "Map", "Math", "Number",
            "Object", "Promise", "RegExp", "Set", "String", "Symbol", "WeakMap", "console",
            "document", "window",
        ]
        lang.constants = ["true", "false", "null", "undefined", "NaN", "Infinity"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.stringDelimiters = ["\"", "'", "`"]
    }, aliases: ["js", "jsx", "mjs", "cjs", "node"])

    register(language("typescript") { lang in
        let javascript = table["javascript"]!
        lang.keywords = javascript.keywords.union([
            "abstract", "as", "declare", "enum", "implements", "interface", "namespace",
            "private", "protected", "public", "readonly", "satisfies", "type", "keyof", "infer",
        ])
        lang.types = javascript.types.union([
            "any", "boolean", "never", "number", "string", "unknown", "void", "Record", "Partial",
        ])
        lang.constants = javascript.constants
        lang.lineComments = javascript.lineComments
        lang.blockComment = javascript.blockComment
        lang.stringDelimiters = javascript.stringDelimiters
    }, aliases: ["ts", "tsx"])

    register(language("java") { lang in
        lang.keywords = [
            "abstract", "assert", "break", "case", "catch", "class", "continue", "default", "do",
            "else", "enum", "extends", "final", "finally", "for", "if", "implements", "import",
            "instanceof", "interface", "native", "new", "package", "private", "protected",
            "public", "record", "return", "sealed", "static", "super", "switch", "synchronized",
            "this", "throw", "throws", "transient", "try", "var", "volatile", "while", "yield",
        ]
        lang.types = [
            "boolean", "byte", "char", "double", "float", "int", "long", "short", "void",
            "String", "Integer", "Double", "Boolean", "Object", "List", "Map", "Set", "Optional",
        ]
        lang.constants = ["true", "false", "null"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.stringDelimiters = ["\"", "'"]
        lang.tripleQuotes = ["\"\"\""]
    })

    register(language("kotlin") { lang in
        lang.keywords = [
            "as", "break", "by", "catch", "class", "companion", "const", "constructor",
            "continue", "data", "do", "else", "enum", "false", "final", "finally", "for", "fun",
            "if", "import", "in", "init", "interface", "internal", "is", "lateinit", "object",
            "open", "override", "package", "private", "protected", "public", "return", "sealed",
            "suspend", "this", "throw", "try", "typealias", "val", "var", "when", "while",
        ]
        lang.types = ["Int", "Long", "Double", "Float", "Boolean", "String", "Char", "Any", "Unit", "List", "Map", "Set"]
        lang.constants = ["true", "false", "null", "it"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.stringDelimiters = ["\"", "'"]
        lang.tripleQuotes = ["\"\"\""]
    }, aliases: ["kt", "kts"])

    register(language("go") { lang in
        lang.keywords = [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
            "package", "range", "return", "select", "struct", "switch", "type", "var",
        ]
        lang.types = [
            "bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int",
            "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
            "uint32", "uint64", "uintptr", "any",
        ]
        lang.constants = ["true", "false", "nil", "iota"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.stringDelimiters = ["\"", "'", "`"]
    }, aliases: ["golang"])

    register(language("rust") { lang in
        lang.keywords = [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move",
            "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait", "type",
            "unsafe", "use", "where", "while",
        ]
        lang.types = [
            "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str",
            "u8", "u16", "u32", "u64", "u128", "usize", "String", "Vec", "Option", "Result",
            "Box", "Rc", "Arc", "HashMap", "Self",
        ]
        lang.constants = ["true", "false", "None", "Some", "Ok", "Err"]
        lang.lineComments = ["//"]
        lang.blockComment = ("/*", "*/")
        lang.stringDelimiters = ["\"", "'"]
    }, aliases: ["rs"])

    register(language("ruby") { lang in
        lang.keywords = [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
            "elsif", "end", "ensure", "for", "if", "in", "module", "next", "not", "or", "redo",
            "require", "require_relative", "rescue", "retry", "return", "self", "super", "then",
            "unless", "until", "when", "while", "yield", "attr_accessor", "attr_reader",
        ]
        lang.types = ["Array", "Hash", "String", "Symbol", "Integer", "Float", "Struct", "Proc", "Range"]
        lang.constants = ["true", "false", "nil", "__FILE__"]
        lang.lineComments = ["#"]
        lang.stringDelimiters = ["\"", "'"]
    }, aliases: ["rb"])

    register(language("php") { lang in
        lang.keywords = [
            "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
            "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif",
            "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global",
            "if", "implements", "include", "instanceof", "interface", "match", "namespace",
            "new", "or", "print", "private", "protected", "public", "readonly", "require",
            "return", "static", "switch", "throw", "trait", "try", "use", "var", "while", "yield",
        ]
        lang.types = ["int", "float", "string", "bool", "void", "mixed", "object", "iterable", "self"]
        lang.constants = ["true", "false", "null", "$this"]
        lang.lineComments = ["//", "#"]
        lang.blockComment = ("/*", "*/")
        lang.dollarVariables = true
    })

    register(language("lua") { lang in
        lang.keywords = [
            "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if",
            "in", "local", "not", "or", "repeat", "return", "then", "until", "while",
        ]
        lang.types = ["string", "table", "math", "io", "os", "coroutine"]
        lang.constants = ["true", "false", "nil", "self"]
        lang.lineComments = ["--"]
        lang.blockComment = ("--[[", "]]")
    })

    register(language("sql") { lang in
        lang.keywords = [
            "select", "from", "where", "insert", "into", "values", "update", "set", "delete",
            "create", "table", "drop", "alter", "add", "index", "view", "join", "inner", "left",
            "right", "outer", "full", "on", "group", "by", "order", "having", "limit", "offset",
            "union", "all", "distinct", "as", "and", "or", "not", "in", "like", "between",
            "case", "when", "then", "else", "end", "with", "returning", "primary", "key",
            "foreign", "references", "constraint", "default", "begin", "commit", "rollback",
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "TABLE", "DROP", "ALTER", "JOIN", "LEFT", "GROUP", "BY", "ORDER", "LIMIT",
            "AND", "OR", "NOT", "IN", "AS", "ON", "DISTINCT", "PRIMARY", "KEY",
        ]
        lang.types = ["int", "integer", "text", "varchar", "boolean", "date", "timestamp", "numeric", "serial", "uuid", "jsonb"]
        lang.constants = ["null", "NULL", "true", "false"]
        lang.lineComments = ["--"]
        lang.blockComment = ("/*", "*/")
        lang.stringDelimiters = ["'", "\""]
    })

    register(language("json") { lang in
        lang.constants = ["true", "false", "null"]
        lang.stringDelimiters = ["\""]
        lang.jsonStyleKeys = true
        lang.callsAreFunctions = false
    }, aliases: ["json5", "jsonc"])

    register(language("yaml") { lang in
        lang.constants = ["true", "false", "null", "yes", "no", "on", "off", "~"]
        lang.lineComments = ["#"]
        lang.jsonStyleKeys = true
        lang.callsAreFunctions = false
    }, aliases: ["yml"])

    register(language("toml") { lang in
        lang.constants = ["true", "false"]
        lang.lineComments = ["#"]
        lang.jsonStyleKeys = true
        lang.callsAreFunctions = false
    }, aliases: ["ini", "cfg", "conf"])

    register(language("css") { lang in
        lang.keywords = [
            "@media", "@import", "@keyframes", "@supports", "@font-face", "!important",
            "from", "to", "and", "not", "only",
        ]
        lang.types = [
            "color", "background", "margin", "padding", "border", "display", "position", "font",
            "width", "height", "flex", "grid", "gap", "top", "left", "right", "bottom",
            "transform", "transition", "opacity", "overflow", "z-index", "content",
        ]
        lang.lineComments = []
        lang.blockComment = ("/*", "*/")
        lang.callsAreFunctions = true
    }, aliases: ["scss", "less", "sass"])

    register(language("html") { lang in
        lang.markupTags = true
        lang.blockComment = ("<!--", "-->")
        lang.callsAreFunctions = false
    }, aliases: ["xml", "svg", "vue", "xhtml"])

    register(language("diff") { lang in
        lang.lineDiff = true
        lang.callsAreFunctions = false
    }, aliases: ["patch"])

    register(language("makefile") { lang in
        lang.keywords = ["ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "export"]
        lang.lineComments = ["#"]
        lang.dollarVariables = true
        lang.callsAreFunctions = false
    }, aliases: ["make", "mk"])

    register(language("dockerfile") { lang in
        lang.keywords = [
            "FROM", "RUN", "CMD", "LABEL", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT",
            "VOLUME", "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS",
        ]
        lang.lineComments = ["#"]
        lang.dollarVariables = true
        lang.callsAreFunctions = false
    }, aliases: ["docker"])

    return table
}()
