import Foundation

struct AzureSpeechAddress {
    let liveEndpoint: String
    let resource: String?

    static func resourceName(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) == nil ? nil : value
    }

    init?(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = Self.resourceName(trimmed).map { "https://\($0).cognitiveservices.azure.com" } ?? trimmed
        guard let url = URLComponents(string: address), ["https", "wss"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil else { return nil }

        // Portal endpoints usually identify a regional API or a custom Azure resource.
        let parts = host.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let name = Self.resourceName(String(parts[0])) else { return nil }
        let route = "/speech/recognition/conversation/cognitiveservices/v1"
        let target: String
        let path: String
        switch parts[1] {
        case "api.cognitive.microsoft.com", "stt.speech.microsoft.com":
            resource = nil
            target = "\(name).stt.speech.microsoft.com"
            path = route
        case "cognitiveservices.azure.com", "services.ai.azure.com":
            resource = name
            target = host
            path = "/stt" + route
        default: return nil
        }
        guard ["", "/", path].contains(url.percentEncodedPath) else { return nil }
        liveEndpoint = "wss://" + target + path
    }
}

struct AzureLiveSettings: Encodable {
    let endpoint: String
    let key: String
    let language: String

    init?(endpoint: String, key: String, language: String) {
        guard let address = AzureSpeechAddress(endpoint),
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              language.range(of: #"^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})+$"#, options: .regularExpression) != nil
        else { return nil }
        self.endpoint = address.liveEndpoint
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
    }
}
