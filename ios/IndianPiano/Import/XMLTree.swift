import Foundation

/// A tiny DOM built with `XMLParser`; MusicXML files are small enough to hold in memory.
final class XMLTreeElement {
    let name: String
    let attributes: [String: String]
    private(set) var children: [XMLTreeElement] = []
    fileprivate(set) var text = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    func child(_ name: String) -> XMLTreeElement? { children.first { $0.name == name } }
    func children(_ name: String) -> [XMLTreeElement] { children.filter { $0.name == name } }
    func has(_ name: String) -> Bool { children.contains { $0.name == name } }

    /// Follows a path of child names, e.g. `element["pitch", "step"]`.
    subscript(path: String...) -> XMLTreeElement? {
        var current: XMLTreeElement? = self
        for component in path { current = current?.child(component) }
        return current
    }

    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var doubleValue: Double? { Double(trimmedText) }
    var intValue: Int? { Int(trimmedText) ?? doubleValue.map { Int($0.rounded()) } }

    /// All descendants with the given name, depth first.
    func descendants(_ name: String) -> [XMLTreeElement] {
        var result: [XMLTreeElement] = []
        for child in children {
            if child.name == name { result.append(child) }
            result += child.descendants(name)
        }
        return result
    }

    fileprivate func append(_ child: XMLTreeElement) { children.append(child) }

    static func parse(_ data: Data) throws -> XMLTreeElement {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else {
            let reason = parser.parserError?.localizedDescription ?? "malformed XML"
            throw ScoreImportError.invalidFormat(reason)
        }
        return root
    }
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLTreeElement?
    private var stack: [XMLTreeElement] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = XMLTreeElement(name: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.append(element) } else { root = element }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}
