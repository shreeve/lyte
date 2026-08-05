// Lightweight Swift lexical equipment for repository architecture tests.
// It is deliberately not a compiler: it removes comments and strings, keeps
// the identifiers/punctuation needed by structural ratchets, and recognizes
// every supported spelling of an import declaration.

public enum SwiftSourceScanner {
    public static func tokens(in source: String) -> [String] {
        let characters = Array(source)
        var tokens: [String] = []
        var identifier = ""
        var index = 0
        var blockDepth = 0
        var inLineComment = false
        var stringHashes: Int?
        var stringQuotes = 0

        func flush() {
            if !identifier.isEmpty {
                tokens.append(identifier)
                identifier.removeAll(keepingCapacity: true)
            }
        }

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count
                ? characters[index + 1] : "\0"

            if inLineComment {
                if character == "\n" { inLineComment = false }
                index += 1
                continue
            }
            if blockDepth > 0 {
                if character == "/", next == "*" {
                    blockDepth += 1
                    index += 2
                } else if character == "*", next == "/" {
                    blockDepth -= 1
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if let hashes = stringHashes {
                if hashes == 0, character == "\\" {
                    index = min(index + 2, characters.count)
                    continue
                }
                if delimiter(
                    quoteCount: stringQuotes,
                    hashCount: hashes,
                    matches: characters,
                    at: index
                ) {
                    index += stringQuotes + hashes
                    stringHashes = nil
                } else {
                    index += 1
                }
                continue
            }
            if character == "/", next == "/" {
                flush()
                inLineComment = true
                index += 2
                continue
            }
            if character == "/", next == "*" {
                flush()
                blockDepth = 1
                index += 2
                continue
            }
            var hashes = 0
            while index + hashes < characters.count,
                  characters[index + hashes] == "#" {
                hashes += 1
            }
            let quoteIndex = index + hashes
            if quoteIndex < characters.count,
               characters[quoteIndex] == "\"" {
                flush()
                stringHashes = hashes
                stringQuotes = delimiter(
                    quoteCount: 3,
                    hashCount: 0,
                    matches: characters,
                    at: quoteIndex
                ) ? 3 : 1
                index = quoteIndex + stringQuotes
                continue
            }
            if character.isLetter || character.isNumber || character == "_" {
                identifier.append(character)
            } else {
                flush()
                if [".", "(", ")", "=", "{", "}"].contains(character) {
                    tokens.append(String(character))
                }
            }
            index += 1
        }
        flush()
        return tokens
    }

    public static func contains(
        _ needle: [String],
        in tokens: [String]
    ) -> Bool {
        guard !needle.isEmpty, tokens.count >= needle.count else {
            return false
        }
        return (0...(tokens.count - needle.count)).contains { start in
            Array(tokens[start..<(start + needle.count)]) == needle
        }
    }

    public static func importedModules(in source: String) -> [String] {
        let importKinds: Set<String> = [
            "class", "enum", "func", "let", "macro", "protocol", "struct",
            "typealias", "var",
        ]
        let sourceTokens = tokens(in: source)
        return sourceTokens.indices.compactMap { importIndex in
            guard sourceTokens[importIndex] == "import" else { return nil }
            var moduleIndex = importIndex + 1
            guard moduleIndex < sourceTokens.endIndex else { return nil }
            if importKinds.contains(sourceTokens[moduleIndex]) {
                moduleIndex += 1
            }
            guard moduleIndex < sourceTokens.endIndex else { return nil }
            return sourceTokens[moduleIndex]
        }
    }

    private static func delimiter(
        quoteCount: Int,
        hashCount: Int,
        matches characters: [Character],
        at start: Int
    ) -> Bool {
        let delimiter = Array(repeating: Character("\""), count: quoteCount)
            + Array(repeating: Character("#"), count: hashCount)
        guard start + delimiter.count <= characters.count else { return false }
        return Array(characters[start..<(start + delimiter.count)]) == delimiter
    }
}
