import Foundation

struct TavilyService {
    let apiKey: String
    var session: URLSession = .shared

    func search(query: String, topic: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SearchRequest(
            query: query,
            topic: topic == "news" ? "news" : "general"
        ))

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw SearchError.unavailable
        }

        let search = try JSONDecoder().decode(SearchResponse.self, from: data)
        guard !search.results.isEmpty else { throw SearchError.unavailable }
        let results = search.results.prefix(4).map { result in
            SearchResult(
                title: result.title,
                url: result.url,
                content: String(result.content.prefix(700)),
                publishedDate: result.publishedDate
            )
        }
        let output = try JSONEncoder().encode(results)
        return String(decoding: output, as: UTF8.self)
    }
}

private enum SearchError: Error {
    case unavailable
}

private struct SearchRequest: Encodable {
    let query: String
    let topic: String
    let searchDepth = "basic"
    let maxResults = 4
    let includePublishedDate = true
    let includeAnswer = false
    let includeRawContent = false

    enum CodingKeys: String, CodingKey {
        case query, topic
        case searchDepth = "search_depth"
        case maxResults = "max_results"
        case includePublishedDate = "include_published_date"
        case includeAnswer = "include_answer"
        case includeRawContent = "include_raw_content"
    }
}

private struct SearchResponse: Decodable {
    let results: [SearchResult]
}

private struct SearchResult: Codable {
    let title: String
    let url: String
    let content: String
    let publishedDate: String?

    enum CodingKeys: String, CodingKey {
        case title, url, content
        case publishedDate = "published_date"
    }
}
