import Foundation

struct BetaDiagnostics {
    enum Model {
        case builtIn(String)
        case ollama(String)

        var description: String {
            let name: String
            let backend: String
            let pattern: String
            switch self {
            case .builtIn(let value):
                name = value
                backend = "Built-in"
                pattern = #"^[A-Za-z0-9][A-Za-z0-9_. -]{0,63}$"#
            case .ollama(let value):
                name = value
                backend = "Ollama"
                pattern = #"^(?:[A-Za-z0-9][A-Za-z0-9_.-]*/){0,2}[A-Za-z0-9][A-Za-z0-9_.-]*(?::[A-Za-z0-9][A-Za-z0-9_.-]*)?$"#
            }
            if name.isEmpty { return "\(backend) · No model selected" }
            guard name.utf8.count <= 128,
                  name.range(of: pattern, options: .regularExpression) == name.startIndex..<name.endIndex else {
                return "\(backend) · Model name unavailable"
            }
            let modelName = name.split(separator: "/").last.map(String.init) ?? name
            return "\(backend) · \(modelName)"
        }
    }

    struct Issue {
        enum Area: String {
            case setup = "Model setup"
            case check = "Claim check"
            case sources = "Source review"
            case shortcut = "Keyboard shortcut"
        }

        let area: Area
        let detail: String

        init(area: Area, message: String? = nil) {
            self.area = area
            detail = message.flatMap { Self.recognizedDetails[$0] } ?? "\(area.rawValue) failed."
        }

        static func sourceIssue(for message: String?) -> Self? {
            guard let message, recognizedDetails[message] != nil else { return nil }
            return Self(area: .sources, message: message)
        }

        // Report only these fixed descriptions. System errors and source-specific values can contain private data.
        private static let recognizedDetails: [String: String] = [
            "Install Ollama for macOS to use its local models.": "Ollama is missing.",
            "Hold UP could not verify this Ollama installation. Install the official Ollama app and try again.": "The Ollama installation could not be verified.",
            "Hold UP could not read Ollama’s installed models. Check the model folder and try again.": "The installed Ollama models could not be read.",
            "The private Ollama session could not start. Try again or switch to the built-in model.": "The local Ollama session could not start.",
            "The private Ollama session is unavailable. Reconnect Ollama and try again.": "The local Ollama session was unavailable.",
            "Hold UP could not confirm that Ollama cloud is disabled. Update the official Ollama app and reconnect.": "The local-only Ollama setting could not be verified.",
            "No compatible local text models were found. Finish installing a local text model in Ollama, then refresh this list.": "No compatible local Ollama model was found.",
            "Hold UP could not verify the model’s local text generation capabilities. Refresh the model list or choose another local model.": "The model’s local text capabilities could not be verified.",
            "Ollama could not load this model. Try a smaller local model or free up memory.": "The selected model could not load.",
            "Ollama did not complete the review. Try again or choose a different local model.": "Ollama did not complete the review.",
            "The built-in model could not be opened. Check its installation in Settings.": "The built-in model could not load.",
            "The text and rules exceed the built-in model’s context limit. Shorten the selection or context and try again.": "The built-in model’s context limit was exceeded.",
            "The built-in model could not finish a structured response. Try a shorter selection.": "The built-in model returned an incomplete result.",
            "The model returned an unusable result. Try a shorter selection or a different model.": "The model returned an unusable result.",
            "The model server didn’t return a complete download. Try again.": "The model download was incomplete.",
            "The downloaded file didn’t match the expected model. Try downloading it again.": "The model file failed verification.",
            "Enter a public HTTPS URL with a domain name and no sign-in details.": "The source address was not a public HTTPS URL.",
            "Hold UP can only read public websites.": "The source was restricted to a private address.",
            "This website’s address couldn’t be resolved.": "The website address could not be resolved.",
            "The request timed out. Try again or paste the source text.": "The request timed out.",
            "The page couldn’t be reached securely. Open it in your browser or paste the text.": "The page could not be reached securely.",
            "The page redirects. Copy the final HTTPS address from your browser or paste the text.": "The source redirected to an unsupported address.",
            "The page is larger than 2 MB. Paste the relevant passage instead.": "The source exceeded the download limit.",
            "The page isn’t public HTML, plain text, or a PDF. Open it in your browser and paste the relevant passage.": "The source file type was unsupported.",
            "The page didn’t contain readable text. Open it in your browser and paste the relevant passage.": "The page did not contain readable text."
        ]
    }

    let version: String
    let osVersion: OperatingSystemVersion
    let model: Model
    let issue: Issue?

    var text: String {
        let versionPattern = #"^[0-9]+(?:[.][0-9]+){1,3}$"#
        let appVersion = version.range(of: versionPattern, options: .regularExpression) == version.startIndex..<version.endIndex
            ? version : "Version unavailable"
        let system = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let failure = issue.map { "\($0.area.rawValue) · \($0.detail)" } ?? "None recorded"
        return """
        Hold UP \(appVersion)
        macOS \(system)
        Model · \(model.description)
        Last failure · \(failure)
        """
    }

    var report: String {
        """
        What happened?

        What did you expect?

        Diagnostics
        \(text)
        """
    }
}
