import Foundation

@main struct FinalPolishTests {
    static func main() throws {
        let config = try FinalPolishConfiguration(endpoint: "https://example.invalid/v1/chat/completions", model: "configured-model")
        let request = try FinalPolishService.request(configuration: config, apiKey: "test-key", original: "不是十五，是五十。", draft: "Not fifteen, fifty.", sourceLanguage: "zh-Hans", targetLanguage: "en")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let messages = body["messages"] as! [[String: String]]
        precondition(messages.count == 2 && messages[0]["role"] == "system")
        let content = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
        precondition(content["original_text"] == "不是十五，是五十。" && content["translated_draft"] == "Not fifteen, fifty.")
        precondition(content["source_language"] == "zh-Hans" && content["target_language"] == "en")
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        for endpoint in ["http://example.invalid/v1/chat/completions", "https://user:pass@example.invalid/v1/chat/completions", "https://example.invalid/v1/chat/completions?key=x", "https://example.invalid/v1"] {
            precondition((try? FinalPolishConfiguration(endpoint: endpoint, model: "m")) == nil)
        }
        let local = try FinalPolishConfiguration(endpoint: "http://localhost:1234/v1/chat/completions", model: "local-model")
        let localRequest = try FinalPolishService.request(configuration: local, apiKey: "", original: "原文", draft: "draft", sourceLanguage: "zh", targetLanguage: "en")
        precondition(localRequest.value(forHTTPHeaderField: "Authorization") == nil)
        let ok = Data(#"{"choices":[{"message":{"content":"Corrected text."},"finish_reason":"stop"}]}"#.utf8)
        let decoded = try FinalPolishService.decode(ok, status: 200)
        precondition(decoded == "Corrected text.")
        for value in [#"{"choices":[]}"#, #"{"choices":[{"message":{"content":" "}}]}"#, #"{"choices":[{"message":{"content":"cut off"},"finish_reason":"length"}]}"#, #"{"choices":[{"message":{"content":null,"refusal":"no"}}]}"#] {
            precondition((try? FinalPolishService.decode(Data(value.utf8), status: 200)) == nil)
        }
        precondition((try? FinalPolishService.decode(ok, status: 401)) == nil)
        print("PASS: polish request fields, endpoint validation, local auth, response rejection; no network requests")
    }
}
