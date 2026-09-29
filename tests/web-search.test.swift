import Foundation
@main struct WebSearchTests {
 static func main() {
  let query = "北京天气 & 明天 #日程"
  let url = WebSearch.browserURL(query)!
  assert(URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.first!.value == query)
  assert(WebSearch.browserURL("  ") == nil)
  let xml = "<rss><channel><item><title>Official &amp; API</title><link>https://example.com/platform</link><description>API console</description></item><item><title>unsafe</title><link>javascript:alert(1)</link></item></channel></rss>"
  let parsed = WebSearch.parse(Data(xml.utf8))
  assert(parsed.count == 1 && parsed[0]["title"] == "Official & API")
  assert(WebSearch.parse(Data("broken".utf8)).isEmpty)
  print("PASS query encoding, empty query, RSS evidence, unsafe scheme, malformed response")
 }
}
