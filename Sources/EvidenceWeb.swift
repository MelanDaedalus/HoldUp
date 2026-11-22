import Darwin
import Foundation
import PDFKit
@preconcurrency import libxml2

struct EvidenceReference: Identifiable, Sendable {
    let url: URL
    let title: String
    let context: String
    var id: String { url.absoluteString }
}

struct EvidencePage: Sendable {
    let url: URL
    let title: String
    let text: String
    let publishedDate: String?
    let references: [EvidenceReference]

    init(url: URL, title: String, text: String, publishedDate: String?, references: [EvidenceReference] = []) {
        self.url = url
        self.title = title
        self.text = text
        self.publishedDate = publishedDate
        self.references = references
    }
}

enum EvidenceWeb {
    private static let maxPageBytes = 2 * 1024 * 1024
    private static let responseMarker = "\nHold UP HTTP response\n"

    static func page(_ address: String) async throws -> EvidencePage {
        let url = try checkedURL(address)
        let transfer = try await download(url)
        try Task.checkCancellation()
        return try extractPage(transfer.body, contentType: transfer.contentType, url: transfer.url)
    }

    static func browserSearch(_ query: String) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "www.google.com"
        parts.path = "/search"
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    static func uniqueSources(_ addresses: [String]) -> [String] {
        var seen = Set<String>()
        return addresses.filter { address in
            let identity = (try? checkedURL(address)).map(sourceIdentity) ?? address
            return seen.insert(identity).inserted
        }
    }

    static func sourceIdentity(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        if parts.path.isEmpty { parts.path = "/" }
        parts.fragment = nil
        let query = parts.queryItems?.filter { item in
            let name = item.name.lowercased()
            return !name.hasPrefix("utm_") && name != "fbclid" && name != "gclid"
        }
        parts.queryItems = query?.isEmpty == true ? nil : query
        return parts.string ?? url.absoluteString
    }

    static func redirectTarget(_ address: String, from base: URL) throws -> URL {
        guard !address.isEmpty, !address.contains("\\"),
              !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let target = URL(string: address, relativeTo: base)?.absoluteURL else { throw Failure.redirected }
        return try checkedURL(target.absoluteString)
    }

    static func citationCandidates(in page: EvidencePage, for claim: String) -> [EvidenceReference] {
        let topic = referenceTerms(claim).subtracting(genericReferenceTerms)
        guard !topic.isEmpty else { return [] }
        let ranked = page.references.enumerated().compactMap { offset, reference -> (score: Int, offset: Int, reference: EvidenceReference)? in
            let path = reference.url.path(percentEncoded: false)
            let titleTerms = referenceTerms(reference.title)
            let citationTerms = titleTerms.union(referenceTerms(path))
            let isReportFile = reference.url.pathExtension.lowercased() == "pdf"
            let isDOI = reference.url.host() == "doi.org" || reference.url.host() == "dx.doi.org"
            let hasReportTerms = !citationTerms.isDisjoint(with: reportTerms)
            guard isReportFile || isDOI || hasReportTerms else { return nil }

            let directMatches = topic.intersection(citationTerms).count
            let nearbyMatches = topic.intersection(referenceTerms(reference.context)).count
            let isGenericTitle = titleTerms.isSubset(of: genericReferenceTerms)
            guard directMatches > 0 || (isGenericTitle && nearbyMatches >= 2) else { return nil }
            let score = directMatches * 3 + min(nearbyMatches, 4) + (isReportFile || isDOI ? 2 : 0)
            return (score, offset, reference)
        }
        return ranked.sorted { left, right in
            left.score == right.score ? left.offset < right.offset : left.score > right.score
        }.prefix(3).map(\.reference)
    }

    private static let reportTerms: Set<String> = [
        "report", "data", "dataset", "study", "research", "statistic", "survey",
        "audit", "paper", "publication", "analysis", "journal", "bulletin", "table", "documentation"
    ]
    private static let genericReferenceTerms = reportTerms.union([
        "about", "across", "after", "also", "according", "all", "are", "based", "been", "before", "being",
        "could", "did", "does", "during", "each", "from", "had", "has", "have", "here", "into", "just",
        "made", "may", "more", "most", "must", "new", "now", "only", "other", "over", "per", "recent",
        "said", "same", "some", "than", "that", "the", "their", "them", "there", "these", "they",
        "this", "those", "through", "today", "under", "until", "very", "was", "were", "what", "when",
        "where", "which", "while", "with", "would", "year", "and", "for", "percent", "source", "latest",
        "click", "link", "read", "text", "download", "document",
        "published", "original", "official", "full", "annual", "monthly", "highest", "lowest",
        "increase", "decrease", "fell", "rose", "drop"
    ])

    private static func referenceTerms(_ text: String) -> Set<String> {
        let terms = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(terms.compactMap { term in
            guard term.count >= 3, term.contains(where: \.isLetter) else { return nil }
            if term.count > 5, term.hasSuffix("ies") { return String(term.dropLast(3)) + "y" }
            if term.count > 4, term.hasSuffix("s"), !term.hasSuffix("ss") { return String(term.dropLast()) }
            return String(term)
        })
    }

    // URLComponents parses the authority before validation. Only a standard HTTPS origin is allowed.
    static func checkedURL(_ address: String) throws -> URL {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.utf8.count <= 4096,
              !input.contains("\\"),
              !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              var components = URLComponents(string: input),
              components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              var host = components.url?.host(percentEncoded: true)?.lowercased() else { throw Failure.invalidURL }

        if host.last == "." { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.utf8.count <= 253, labels.allSatisfy(validHostLabel),
              let last = labels.last, last.utf8.contains(where: { (97...122).contains($0) }) else {
            throw Failure.invalidURL
        }
        let privateSuffixes = [
            "localhost", "local", "localdomain", "internal", "home.arpa", "home", "lan",
            "corp", "test", "invalid", "example", "onion"
        ]
        guard !privateSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw Failure.privateAddress
        }
        components.scheme = "https"
        components.host = host
        components.port = nil
        components.fragment = nil
        guard let url = components.url else { throw Failure.invalidURL }
        return url
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let octets = withUnsafeBytes(of: ipv4.s_addr) { Array($0) }
            let a = octets[0]
            let b = octets[1]
            let c = octets[2]
            switch (a, b, c) {
            case (0, _, _), (10, _, _), (100, 64...127, _), (127, _, _), (169, 254, _),
                 (172, 16...31, _), (192, 0, 0), (192, 0, 2), (192, 88, 99), (192, 168, _),
                 (198, 18...19, _), (198, 51, 100), (203, 0, 113), (224...255, _, _):
                return false
            default:
                return true
            }
        }

        var ipv6 = in6_addr()
        guard address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 else { return false }
        let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
        guard (0x20...0x3f).contains(bytes[0]) else { return false }
        switch (bytes[0], bytes[1], bytes[2], bytes[3]) {
        case (0x20, 0x01, 0...1, _), (0x20, 0x01, 0x0d, 0xb8), (0x20, 0x02, _, _),
             (0x3f, 0xff, 0...15, _):
            return false
        default:
            return true
        }
    }

    static func extractPage(_ data: Data, contentType: String, url: URL) throws -> EvidencePage {
        guard !data.isEmpty else { throw Failure.noText }
        guard data.count <= maxPageBytes else { throw Failure.tooLarge }

        let fields = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        let mediaType = fields.first?.lowercased() ?? ""
        let charset = fields.dropFirst().first { $0.lowercased().hasPrefix("charset=") }
            .map { String($0.dropFirst("charset=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
        let fallbackTitle = url.host() ?? "Source"

        switch mediaType {
        case "text/html", "application/xhtml+xml":
            guard let html = StaticHTML(data, charset: charset, url: url) else { throw Failure.noText }
            let title = html.title.isEmpty ? fallbackTitle : html.title
            guard !html.text.isEmpty else { throw Failure.noText }
            return EvidencePage(url: url, title: title, text: html.text, publishedDate: html.publishedDate, references: html.references)
        case "application/pdf":
            return try readPDF(data, url: url, fallbackTitle: fallbackTitle)
        case "text/plain":
            let encoding: String.Encoding? = switch charset?.lowercased() {
            case "iso-8859-1", "latin1": .isoLatin1
            case "windows-1252": .windowsCP1252
            case "utf-16": .utf16
            case "utf-16le": .utf16LittleEndian
            case "utf-16be": .utf16BigEndian
            default: nil
            }
            guard let decoded = encoding.flatMap({ String(data: data, encoding: $0) })
                ?? String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .windowsCP1252) else { throw Failure.noText }
            let text = normalizedText(decoded)
            guard !text.isEmpty else { throw Failure.noText }
            return EvidencePage(url: url, title: fallbackTitle, text: text, publishedDate: nil)
        default:
            throw Failure.unsupportedType
        }
    }

    private static func readPDF(_ data: Data, url: URL, fallbackTitle: String) throws -> EvidencePage {
        guard data.starts(with: "%PDF-".utf8), let document = PDFDocument(data: data), !document.isLocked else {
            throw Failure.noText
        }
        let maxCharacters = 120_000
        var sections: [String] = []
        var characters = 0
        for index in 0..<min(document.pageCount, 40) {
            guard let pageText = document.page(at: index)?.string else { continue }
            let excerpt = normalizedText(String(pageText.prefix(maxCharacters - characters)))
            guard !excerpt.isEmpty else { continue }
            sections.append(excerpt)
            characters += excerpt.count + 1
            if characters >= maxCharacters { break }
        }
        guard !sections.isEmpty else { throw Failure.noText }
        let metadataTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            .map { normalizedLine(String($0.prefix(200))) } ?? ""
        let title = metadataTitle.isEmpty ? fallbackTitle : metadataTitle
        return EvidencePage(url: url, title: title, text: sections.joined(separator: "\n"), publishedDate: nil)
    }

    private static func validHostLabel(_ label: Substring) -> Bool {
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
            && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func resolvePublicAddresses(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var records: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &records) == 0, let records else { throw Failure.resolve }
        defer { freeaddrinfo(records) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = records
        while let record = current {
            let info = record.pointee
            current = info.ai_next
            var presentation = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(info.ai_addr, info.ai_addrlen, &presentation, socklen_t(presentation.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { throw Failure.resolve }
            let address = String(decoding: presentation.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard isPublicAddress(address) else { throw Failure.privateAddress }
            if !addresses.contains(address) { addresses.append(address) }
        }
        guard !addresses.isEmpty else { throw Failure.resolve }
        return addresses
    }

    private static func download(_ url: URL) async throws -> PageTransfer {
        let operation = PageOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard operation.register(continuation) else { return }
                DispatchQueue.global(qos: .utility).async {
                    operation.finish(Result { try followRedirects(from: url, operation: operation) })
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(18)) { [weak operation] in
                    operation?.finish(.failure(Failure.timedOut))
                }
            }
        } onCancel: {
            operation.finish(.failure(CancellationError()))
        }
    }

    private static func followRedirects(from start: URL, operation: PageOperation) throws -> PageTransfer {
        var url = start
        var visited: Set<URL> = []
        for _ in 0...2 {
            guard visited.insert(url).inserted else { break }
            switch try fetch(url, operation: operation) {
            case .page(let page): return page
            case .redirect(let location): url = try redirectTarget(location, from: url)
            }
        }
        throw Failure.redirected
    }

    private enum FetchResult {
        case page(PageTransfer), redirect(String)
    }

    private static func fetch(_ url: URL, operation: PageOperation) throws -> FetchResult {
        guard let host = url.host() else { throw Failure.invalidURL }
        let addresses = try resolvePublicAddresses(host)
        let endpoints = addresses.map { $0.contains(":") ? "[\($0)]" : $0 }.joined(separator: ",")

        // Pin the actual connection to prevalidated IPs while letting TLS verify the original host.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.environment = ["LC_ALL": "C"]
        process.arguments = [
            "-q", "--silent", "--globoff", "--noproxy", "*", "--proto", "=https", "--max-redirs", "0",
            "--disallow-username-in-url", "--connect-timeout", "6", "--max-time", "14",
            "--max-filesize", String(maxPageBytes), "--compressed", "--resolve", "*:443:\(endpoints)",
            "--header", "Accept: text/html, application/xhtml+xml, text/plain, application/pdf", "--user-agent", "HoldUP/0.5",
            "--write-out", "\(responseMarker)%{http_code}\n%{content_type}\n%{redirect_url}", "--url", url.absoluteString
        ]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try operation.start(process)
        defer {
            try? pipe.fileHandleForReading.close()
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        var data = Data()
        let limit = maxPageBytes + 4096
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 32 * 1024), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else { throw Failure.tooLarge }
            data.append(chunk)
        }
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: break
        case 28: throw Failure.timedOut
        case 63: throw Failure.tooLarge
        default: throw Failure.unreachable
        }

        guard let metadata = data.range(of: Data(responseMarker.utf8), options: .backwards) else {
            throw Failure.unreachable
        }
        let fields = String(decoding: data[metadata.upperBound...], as: UTF8.self)
            .split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let status = Int(fields[0]) else { throw Failure.unreachable }
        if [301, 302, 303, 307, 308].contains(status) { return .redirect(String(fields[2])) }
        guard status == 200 else { throw Failure.pageStatus(status) }
        guard metadata.lowerBound <= maxPageBytes else { throw Failure.tooLarge }
        return .page(PageTransfer(body: Data(data[..<metadata.lowerBound]), contentType: String(fields[1]), url: url))
    }

    private struct PageTransfer: Sendable {
        let body: Data
        let contentType: String
        let url: URL
    }

    // DNS may still be finishing when the deadline fires. A stale resolution cannot start a request.
    private final class PageOperation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<PageTransfer, any Error>?
        private var finished = false
        private var earlyResult: Result<PageTransfer, any Error>?
        private var process: Process?

        func register(_ continuation: CheckedContinuation<PageTransfer, any Error>) -> Bool {
            let early = lock.withLock {
                if !finished { self.continuation = continuation }
                return earlyResult
            }
            guard let early else { return true }
            continuation.resume(with: early)
            return false
        }

        func start(_ process: Process) throws {
            try lock.withLock {
                guard !finished else { throw CancellationError() }
                do {
                    try process.run()
                } catch {
                    throw Failure.unreachable
                }
                self.process = process
            }
        }

        func finish(_ result: Result<PageTransfer, any Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<PageTransfer, any Error>? in
                guard !finished else { return nil }
                finished = true
                if case .failure = result, let process, process.isRunning { process.terminate() }
                process = nil
                if continuation == nil { earlyResult = result }
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(with: result)
        }
    }

    private struct StaticHTML {
        let title: String
        let text: String
        let publishedDate: String?
        let references: [EvidenceReference]

        private static let omitted = Set([
            "script", "style", "noscript", "template", "iframe", "frame", "object", "embed",
            "svg", "canvas", "video", "audio", "picture", "nav", "footer", "aside", "form", "textarea"
        ])
        private static let block = Set([
            "address", "article", "blockquote", "br", "caption", "dd", "div", "dl", "dt", "figcaption",
            "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "ol", "p", "pre",
            "section", "table", "td", "th", "tr", "ul"
        ])
        private static let citationContext = Set(["p", "li", "dd", "blockquote", "td", "figcaption"])
        private static let omittedRoles = Set(["navigation", "contentinfo", "complementary", "search", "banner"])
        private static let ignoredLabels: Set<String> = [
            "sign up", "subscribe", "advertisement", "privacy policy", "terms of use", "home", "contact"
        ]

        init?(_ data: Data, charset: String?, url: URL) {
            let options = Int32(HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
                                | HTML_PARSE_NONET.rawValue | HTML_PARSE_COMPACT.rawValue)
            let encoding = charset ?? (String(data: data, encoding: .utf8) == nil ? nil : "UTF-8")
            let document = data.withUnsafeBytes { raw in
                let bytes = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
                if let encoding {
                    return encoding.withCString { htmlReadMemory(bytes, Int32(data.count), nil, $0, options) }
                }
                return htmlReadMemory(bytes, Int32(data.count), nil, nil, options)
            }
            guard let document else { return nil }
            defer { xmlFreeDoc(document) }
            guard let root = xmlDocGetRootElement(document) else { return nil }

            let head = Self.element("head", among: root.pointee.children)
            title = head.flatMap { Self.element("title", among: $0.pointee.children) }
                .map { normalizedLine(Self.string(xmlNodeGetContent($0))) } ?? ""
            publishedDate = head.flatMap { Self.date(among: $0.pointee.children) }

            let body = Self.element("body", among: root.pointee.children) ?? root
            let main = Self.element("main", among: body.pointee.children)
            let article = Self.element("article", among: (main ?? body).pointee.children)
            var extracted = ""
            var contentRoot = body
            for node in [article, main, body].compactMap({ $0 }) {
                var content = ""
                Self.append(node.pointee.children, to: &content)
                extracted = normalizedText(content)
                if !extracted.isEmpty {
                    contentRoot = node
                    break
                }
            }
            text = extracted
            references = Self.references(in: contentRoot.pointee.children, baseURL: url)
        }

        private static func references(in root: xmlNodePtr?, baseURL: URL) -> [EvidenceReference] {
            var results: [EvidenceReference] = []
            var seen = Set([sourceIdentity(baseURL)])
            var contexts: [xmlNodePtr: String] = [:]

            func walk(_ siblings: xmlNodePtr?, near context: xmlNodePtr?) {
                var node = siblings
                while let current = node, results.count < 120 {
                    node = current.pointee.next
                    guard current.pointee.type == XML_ELEMENT_NODE, !excluded(current) else { continue }
                    let name = current.pointee.name.map { String(cString: $0) } ?? ""
                    if name == "a" {
                        guard let address = attribute("href", of: current)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !address.hasPrefix("#"), !address.contains("\\"),
                              !address.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                              let absolute = URL(string: address, relativeTo: baseURL)?.absoluteURL,
                              let url = try? checkedURL(absolute.absoluteString),
                              let title = anchorTitle(current), seen.insert(sourceIdentity(url)).inserted else { continue }
                        var paragraph = ""
                        if let context {
                            if let previous = contexts[context] { paragraph = previous }
                            else {
                                paragraph = Self.anchorContext(context)
                                contexts[context] = paragraph
                            }
                        }
                        results.append(EvidenceReference(url: url, title: title, context: paragraph))
                    } else {
                        walk(current.pointee.children, near: citationContext.contains(name) ? current : context)
                    }
                }
            }

            walk(root, near: nil)
            return results
        }

        private static func anchorTitle(_ node: xmlNodePtr) -> String? {
            let relationship = attribute("rel", of: node)?.lowercased().split(whereSeparator: \.isWhitespace) ?? []
            guard !relationship.contains("sponsored") else { return nil }
            var value = ""
            append(node.pointee.children, to: &value)
            let title = normalizedLine(String(value.prefix(200)))
            guard !title.isEmpty, !ignoredLabels.contains(title.lowercased()) else { return nil }
            return title
        }

        private static func anchorContext(_ node: xmlNodePtr) -> String {
            var value = ""
            append(node.pointee.children, to: &value)
            return normalizedLine(String(value.prefix(600)))
        }

        private static func element(_ name: String, among siblings: xmlNodePtr?) -> xmlNodePtr? {
            var node = siblings
            while let current = node {
                if current.pointee.type == XML_ELEMENT_NODE && !excluded(current) {
                    if current.pointee.name.map({ String(cString: $0) }) == name { return current }
                    if let found = element(name, among: current.pointee.children) { return found }
                }
                node = current.pointee.next
            }
            return nil
        }

        private static func append(_ siblings: xmlNodePtr?, to output: inout String) {
            var node = siblings
            while let current = node {
                switch current.pointee.type {
                case XML_TEXT_NODE, XML_CDATA_SECTION_NODE:
                    if let content = current.pointee.content {
                        output += String(cString: content).replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\r", with: " ")
                    }
                case XML_ELEMENT_NODE:
                    if !excluded(current) {
                        let name = current.pointee.name.map { String(cString: $0) } ?? ""
                        if block.contains(name) { output += "\n" }
                        append(current.pointee.children, to: &output)
                        if block.contains(name) { output += "\n" }
                    }
                default:
                    break
                }
                node = current.pointee.next
            }
        }

        private static func excluded(_ node: xmlNodePtr) -> Bool {
            let name = node.pointee.name.map { String(cString: $0) } ?? ""
            if omitted.contains(name) || attribute("hidden", of: node) != nil { return true }
            if let role = attribute("role", of: node)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               omittedRoles.contains(role) { return true }
            if attribute("aria-hidden", of: node)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
                return true
            }
            let declarations = attribute("style", of: node)?.lowercased()
                .filter { !$0.isWhitespace }.split(separator: ";") ?? []
            return declarations.contains {
                let rule = $0.split(separator: "!", maxSplits: 1).first
                return rule == "display:none" || rule == "visibility:hidden"
            }
        }

        private static func date(among siblings: xmlNodePtr?) -> String? {
            var node = siblings
            while let current = node {
                node = current.pointee.next
                guard current.pointee.type == XML_ELEMENT_NODE,
                      current.pointee.name.map({ String(cString: $0) }) == "meta",
                      attribute("property", of: current)?.lowercased() == "article:published_time"
                        || attribute("itemprop", of: current)?.lowercased() == "datepublished",
                      let value = attribute("content", of: current)?.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }

                let day = String(value.prefix(10))
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyy-MM-dd"
                guard let date = formatter.date(from: day), formatter.string(from: date) == day else { continue }
                if value.count == 10 { return day }
                let timestamp = ISO8601DateFormatter()
                if timestamp.date(from: value) != nil { return day }
                timestamp.formatOptions.insert(.withFractionalSeconds)
                if timestamp.date(from: value) != nil { return day }
            }
            return nil
        }

        private static func attribute(_ name: String, of node: xmlNodePtr) -> String? {
            name.withCString { key in
                let property = UnsafeRawPointer(key).assumingMemoryBound(to: xmlChar.self)
                guard let value = xmlGetProp(node, property) else { return nil }
                return string(value)
            }
        }

        private static func string(_ value: UnsafeMutablePointer<xmlChar>?) -> String {
            guard let value else { return "" }
            defer { xmlFree(value) }
            return String(cString: value)
        }
    }

    private static func normalizedLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { normalizedLine(String($0)) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private enum Failure: LocalizedError {
        case invalidURL, privateAddress, resolve, timedOut, unreachable, redirected, pageStatus(Int)
        case tooLarge, unsupportedType, noText

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a public HTTPS URL with a domain name and no sign-in details."
            case .privateAddress: "Hold UP can only read public websites."
            case .resolve: "This website’s address couldn’t be resolved."
            case .timedOut: "The request timed out. Try again or paste the source text."
            case .unreachable: "The page couldn’t be reached securely. Open it in your browser or paste the text."
            case .redirected: "The page redirects. Copy the final HTTPS address from your browser or paste the text."
            case .pageStatus(let status): "The website returned HTTP \(status). Open it in your browser or paste the text."
            case .tooLarge: "This page is larger than 2 MB. Paste the relevant passage instead."
            case .unsupportedType: "The page isn’t public HTML, plain text, or a PDF. Open it in your browser and paste the relevant passage."
            case .noText: "The page didn’t contain readable text. Open it in your browser and paste the relevant passage."
            }
        }
    }
}
