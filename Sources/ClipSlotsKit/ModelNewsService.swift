import Foundation

public struct ModelNewsRefresh: Sendable {
    public var items: [ModelNewsItem]
    public var errors: [String: String]
    public var successfulSources: Set<String>
}

public struct ModelNewsService: Sendable {
    private let transport: any ModelHTTPTransport
    public init(transport: any ModelHTTPTransport = ModelURLSessionTransport()) { self.transport = transport }
    public func refresh(sources: [ModelNewsSource], now: Date = Date()) async -> ModelNewsRefresh {
        var items: [ModelNewsItem] = [], errors: [String: String] = [:], success = Set<String>()
        // Bounded sequential fetching avoids a burst of timers and large XML buffers.
        for source in sources where source.enabled {
            do {
                try ModelProfile.validateURL(source.url)
                guard let url = URL(string: source.url) else { throw ModelWorkspaceError.response }
                var request = URLRequest(url: url, timeoutInterval: 25)
                request.setValue("application/rss+xml, application/atom+xml, application/xml", forHTTPHeaderField: "Accept")
                let (data, status) = try await transport.send(request)
                guard (200...299).contains(status), data.count <= 8 * 1024 * 1024 else { throw ModelWorkspaceError.http(status) }
                items += try Self.parse(data, source: source, now: now)
                success.insert(source.id)
            } catch { errors[source.id] = error.localizedDescription }
        }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.url).inserted }.sorted {
            ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
        }
        return .init(items: Array(items.prefix(600)), errors: errors, successfulSources: success)
    }
    public static func parse(_ data: Data, source: ModelNewsSource, now: Date = Date()) throws -> [ModelNewsItem] {
        let delegate = ModelFeedParser(source: source, now: now)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.recognized else { throw ModelWorkspaceError.response }
        return delegate.items
    }
}

private final class ModelFeedParser: NSObject, XMLParserDelegate {
    let source: ModelNewsSource
    let now: Date
    var items: [ModelNewsItem] = []
    var recognized = false
    private var inEntry = false
    private var stack: [String] = []
    private var values: [String: String] = [:]
    private var atomURL = ""
    init(source: ModelNewsSource, now: Date) { self.source = source; self.now = now }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let name = elementName.lowercased()
        stack.append(name)
        if ["rss", "feed", "rdf:rdf"].contains(name) { recognized = true }
        if ["item", "entry"].contains(name) { inEntry = true; values = [:]; atomURL = "" }
        if inEntry, name == "link", let href = attributeDict["href"],
           attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" { atomURL = href }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inEntry else { return }
        for key in stack where ["title", "link", "description", "summary", "pubdate", "published", "updated", "dc:date"].contains(key) {
            if (values[key]?.utf8.count ?? 0) < 64_000 { values[key, default: ""] += string }
        }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if ["item", "entry"].contains(elementName.lowercased()), inEntry {
            inEntry = false
            let title = clean(values["title"] ?? "")
            let rawURL = (atomURL.isEmpty ? values["link"] ?? "" : atomURL).trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: rawURL, relativeTo: URL(string: source.url))?.absoluteURL,
               ["http", "https"].contains(url.scheme ?? ""), url.user == nil, url.password == nil, !title.isEmpty {
                let date = values["published"] ?? values["pubdate"] ?? values["dc:date"] ?? values["updated"]
                items.append(.init(title: title, url: url.absoluteString, sourceID: source.id, sourceName: source.name,
                    summary: clean(values["summary"] ?? values["description"] ?? ""), publishedAt: date.flatMap(Self.date), fetchedAt: now))
            }
        }
        if !stack.isEmpty { stack.removeLast() }
    }
    private func clean(_ raw: String) -> String {
        String(raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
    }
    private static func date(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
