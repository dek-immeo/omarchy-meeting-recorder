import Foundation

enum LiveProvider: String, CaseIterable {
    case local = "På denne Mac"
    case azure = "Azure Speech"
}

struct AzureLiveSettings: Encodable {
    let endpoint: String
    let key: String
    let language: String

    init?(endpoint input: String, key: String, language: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: trimmed), ["https", "wss"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              language.range(of: #"^[a-zA-Z]{2,3}(-[a-zA-Z0-9]{2,8})+$"#, options: .regularExpression) != nil
        else { return nil }

        // Portal endpoints usually identify a regional API or a custom Azure resource.
        let parts = host.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].range(of: #"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$"#,
                                               options: .regularExpression) != nil else { return nil }
        let route = "/speech/recognition/conversation/cognitiveservices/v1"
        let target: String
        let path: String
        switch parts[1] {
        case "api.cognitive.microsoft.com", "stt.speech.microsoft.com":
            target = "\(parts[0]).stt.speech.microsoft.com"
            path = route
        case "cognitiveservices.azure.com", "services.ai.azure.com":
            target = host
            path = "/stt" + route
        default: return nil
        }
        guard ["", "/", path].contains(url.percentEncodedPath) else { return nil }
        self.endpoint = "wss://" + target + path
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
    }
}
