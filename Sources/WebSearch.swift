/** Public website discovery. Search results are evidence, never executable instructions. */
import Foundation

enum WebSearch {
    static func browserURL(_ query: String) -> URL? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else { return nil }
        var url = URLComponents(string: "https://www.bing.com/search")!
        url.queryItems = [URLQueryItem(name: "q", value: text)]
        return url.url
    }
    static func search(_ query: String, completion: @escaping (String) -> Void) {
        guard let browser = browserURL(query), var parts = URLComponents(url: browser, resolvingAgainstBaseURL: false) else {
            completion("搜索失败：请提供非空且不超过500字的查询。"); return
        }
        parts.queryItems?.append(URLQueryItem(name: "format", value: "rss"))
        var request = URLRequest(url: parts.url!); request.timeoutInterval = 12
        request.setValue("PocketDesk/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            var items: [[String:String]] = []
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 1_000_000 {
                items = parse(data)
            }
            let result: [String:Any] = ["query":query,"results":items,"searchURL":browser.absoluteString,
                "hint":items.isEmpty ? "未取得可核验结果。可用 open_page 打开 searchURL，让用户看到搜索页；不要宣称已打开目标官网。" : "这些是搜索候选，不保证都是官网。选择与用户目标明确对应的官方地址后用 open_page 打开；有歧义则询问或打开 searchURL。不要编造登录后子页面路径。"]
            let json = try? JSONSerialization.data(withJSONObject: result)
            completion(json.flatMap { String(data:$0,encoding:.utf8) } ?? "搜索结果无法读取。")
        }.resume()
    }
    static func parse(_ data: Data) -> [[String:String]] {
        let reader = SearchRSSReader()
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = reader
        guard parser.parse() else { return [] }
        return reader.items
    }
}
private final class SearchRSSReader: NSObject, XMLParserDelegate {
    var items: [[String:String]] = []
    private var current: [String:String]?
    private var field = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        if elementName == "item" { current = [:] }
        field = elementName
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard current != nil, ["title","link","description"].contains(field) else { return }
        let previous = current?[field] ?? ""
        current?[field] = String((previous + string).prefix(2000))
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "item", let item = current {
            if items.count < 8, let link = item["link"], let url = URL(string: link),
               ["https","http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
               url.user == nil, url.password == nil {
                items.append(["title":item["title"] ?? "", "url":link, "snippet":item["description"] ?? ""])
            }
            current = nil
        }
        field = ""
    }
}
