// Services/AmazonPAAPIService.swift
// Amazon Product Advertising API v5 — AWSSigV4 signed, PA-API v5.
//
// Amazon 2026 Compliance Rules enforced here:
//  ✓ No WebViews — deep-link to Amazon Shopping app via amzn://dp/{ASIN}
//  ✓ Real-time pricing only — every AmazonPartResult carries a `fetchedAt` timestamp
//  ✓ No price tracking — we fetch on-demand, never cache prices > 1 hour
//  ✓ Affiliate disclosure required in UI (see Config.affiliateDisclaimer)
import Foundation
import CryptoKit

// MARK: – Response types

struct AmazonPartResult: Identifiable, Sendable {
    let id: String               // ASIN
    let title: String
    let displayPrice: String     // "$18.50" — display exactly as returned
    let priceAmount: Double
    let affiliateWebURL: URL     // https://amazon.com/dp/{ASIN}?tag=fixie-20
    let shoppingAppDeepLink: URL // amzn://dp/{ASIN} — opens Amazon Shopping app (no WebView)
    let fetchedAt: Date          // "Price as of [time]" label requirement
}

// MARK: – Errors

enum AmazonPAAPIError: LocalizedError {
    case notConfigured
    case networkError(Error)
    case noResults
    case apiError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:        return "Amazon PA-API keys are not configured."
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .noResults:           return "No Amazon results found for this part."
        case .apiError(let c, let m): return "Amazon API error \(c): \(m)"
        case .parseError(let m):   return "Parse error: \(m)"
        }
    }
}

// MARK: – Service

final class AmazonPAAPIService: Sendable {

    static let shared = AmazonPAAPIService()
    private init() {}

    private let urlSession = URLSession.shared
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    // MARK: – Search by part name / number

    /// Returns up to `maxResults` matching Amazon products with live pricing.
    func searchParts(query: String, searchIndex: String = "ToolsAndHomeImprovement", maxResults: Int = 5) async throws -> [AmazonPartResult] {
        guard Config.amazonAccessKey != "YOUR_AMAZON_ACCESS_KEY" else {
            throw AmazonPAAPIError.notConfigured
        }

        let body: [String: Any] = [
            "PartnerTag":   Config.amazonPartnerTag,
            "PartnerType":  "Associates",
            "Keywords":     query + " OEM genuine",
            "SearchIndex":  searchIndex,
            "ItemCount":    maxResults,
            "Resources": [
                "ItemInfo.Title",
                "Offers.Listings.Price",
                "Offers.Listings.DeliveryInfo.IsPrimeEligible",
                "Images.Primary.Small",
            ]
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        let request  = try buildSignedRequest(path: "/paapi5/searchitems",
                                              target: "com.amazon.paapi5.v1.ProductAdvertisingAPIv1.SearchItems",
                                              body: bodyData)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AmazonPAAPIError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw AmazonPAAPIError.apiError(http.statusCode, msg)
        }

        let raw = try decoder.decode(PAAPISearchResponse.self, from: data)
        guard let items = raw.searchResult?.items, !items.isEmpty else {
            throw AmazonPAAPIError.noResults
        }

        let now = Date()
        return items.compactMap { item -> AmazonPartResult? in
            let asin         = item.asin
            let title        = item.itemInfo?.title?.displayValue ?? asin
            let displayPrice = item.offers?.listings?.first?.price?.displayAmount ?? "—"
            let amount       = item.offers?.listings?.first?.price?.amount ?? 0

            guard let webURL = URL(string: "https://www.amazon.com/dp/\(asin)?tag=\(Config.amazonPartnerTag)"),
                  let appURL = URL(string: "amzn://dp/\(asin)") else { return nil }

            return AmazonPartResult(
                id:                  asin,
                title:               title,
                displayPrice:        displayPrice,
                priceAmount:         amount,
                affiliateWebURL:     webURL,
                shoppingAppDeepLink: appURL,
                fetchedAt:           now
            )
        }
    }

    // MARK: – AWSSigV4 signing

    private func buildSignedRequest(path: String, target: String, body: Data) throws -> URLRequest {
        let now          = Date()
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]

        let amzDate  = isoDateTime(from: now)   // "20260319T120000Z"
        let dateOnly = isoDate(from: now)       // "20260319"

        let host = Config.amazonHost
        var request = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody   = body

        // Required headers
        let headers: [(String, String)] = [
            ("content-encoding", "amz-1.0"),
            ("content-type",     "application/json; charset=utf-8"),
            ("host",             host),
            ("x-amz-date",       amzDate),
            ("x-amz-target",     target),
        ]
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

        // Canonical headers (sorted)
        let sortedHeaders   = headers.sorted { $0.0 < $1.0 }
        let canonicalHeaders = sortedHeaders.map { "\($0.0):\($0.1)" }.joined(separator: "\n") + "\n"
        let signedHeaders    = sortedHeaders.map(\.0).joined(separator: ";")

        // Canonical request
        let bodyHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonicalRequest = [
            "POST",
            path,
            "",
            canonicalHeaders,
            signedHeaders,
            bodyHash,
        ].joined(separator: "\n")

        // String to sign
        let credentialScope = "\(dateOnly)/\(Config.amazonRegion)/\(Config.amazonService)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            credentialScope,
            SHA256.hash(data: Data(canonicalRequest.utf8))
                .map { String(format: "%02x", $0) }.joined(),
        ].joined(separator: "\n")

        // Signing key derivation
        let signingKey = deriveSigningKey(secretKey: Config.amazonSecretKey,
                                          date: dateOnly,
                                          region: Config.amazonRegion,
                                          service: Config.amazonService)

        // Signature
        let signatureBytes = HMAC<SHA256>.authenticationCode(
            for: Data(stringToSign.utf8),
            using: SymmetricKey(data: signingKey)
        )
        let signature = Data(signatureBytes).map { String(format: "%02x", $0) }.joined()

        let authHeader = "AWS4-HMAC-SHA256 Credential=\(Config.amazonAccessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    private func deriveSigningKey(secretKey: String, date: String, region: String, service: String) -> Data {
        func hmac(key: Data, data: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8),
                                                  using: SymmetricKey(data: key)))
        }
        let kSecret  = Data(("AWS4" + secretKey).utf8)
        let kDate    = hmac(key: kSecret,  data: date)
        let kRegion  = hmac(key: kDate,    data: region)
        let kService = hmac(key: kRegion,  data: service)
        return  hmac(key: kService, data: "aws4_request")
    }

    // MARK: – Date helpers

    private func isoDateTime(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    private func isoDate(from date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

// MARK: – PA-API v5 Decodable mirror types (internal)

private struct PAAPISearchResponse: Decodable {
    struct SearchResult: Decodable {
        struct Item: Decodable {
            let asin: String
            let itemInfo: ItemInfo?
            let offers: Offers?

            struct ItemInfo: Decodable {
                struct TitleInfo: Decodable { let displayValue: String }
                let title: TitleInfo?
                enum CodingKeys: String, CodingKey { case title = "Title" }
            }
            struct Offers: Decodable {
                struct Listing: Decodable {
                    struct Price: Decodable {
                        let displayAmount: String
                        let amount: Double
                        enum CodingKeys: String, CodingKey {
                            case displayAmount = "DisplayAmount"
                            case amount        = "Amount"
                        }
                    }
                    let price: Price?
                    enum CodingKeys: String, CodingKey { case price = "Price" }
                }
                let listings: [Listing]?
                enum CodingKeys: String, CodingKey { case listings = "Listings" }
            }
            enum CodingKeys: String, CodingKey {
                case asin     = "ASIN"
                case itemInfo = "ItemInfo"
                case offers   = "Offers"
            }
        }
        let items: [Item]?
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }
    let searchResult: SearchResult?
    enum CodingKeys: String, CodingKey { case searchResult = "SearchResult" }
}
