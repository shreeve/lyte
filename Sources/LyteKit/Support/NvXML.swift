import Foundation

/// Minimal parser for GameStream/Sunshine XML responses.
///
/// Responses look like:
///   <root status_code="200"><paired>1</paired><plaincert>...</plaincert></root>
/// `applist` additionally contains repeated <App><ID>..</ID><AppTitle>..</AppTitle></App>.
public struct NvXML {
    public let statusCode: Int
    public let statusMessage: String?
    public let fields: [String: String]        // top-level leaf elements
    public let apps: [(id: String, title: String)]

    public subscript(_ key: String) -> String? { fields[key] }

    public init(data: Data) throws {
        let parser = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else {
            throw LyteError.http("bad XML: \(xml.parserError?.localizedDescription ?? "unknown")")
        }
        self.statusCode = Int(parser.rootAttributes["status_code"] ?? "") ?? -1
        self.statusMessage = parser.rootAttributes["status_message"]
        self.fields = parser.fields
        self.apps = parser.apps
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var rootAttributes: [String: String] = [:]
        var fields: [String: String] = [:]
        var apps: [(id: String, title: String)] = []

        private var path: [String] = []
        private var text = ""
        private var currentAppID: String?
        private var currentAppTitle: String?

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if path.isEmpty { rootAttributes = attributes }
            path.append(name)
            text = ""
            if name == "App" { currentAppID = nil; currentAppTitle = nil }
        }

        func parser(_ p: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (path.count, name) {
            case (2, _):                        // direct child of root
                fields[name] = value
            case (3, "ID") where path[1] == "App":
                currentAppID = value
            case (3, "AppTitle") where path[1] == "App":
                currentAppTitle = value
            default: break
            }
            if name == "App", let id = currentAppID, let title = currentAppTitle {
                apps.append((id: id, title: title))
            }
            path.removeLast()
            text = ""
        }
    }
}
