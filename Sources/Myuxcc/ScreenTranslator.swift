import Foundation
import NaturalLanguage
import Translation

/// On-device translation of recognised text with Apple's Translation framework.
enum ScreenTranslator {
    enum Target: Int, CaseIterable {
        case auto, chinese, english

        var title: String { ["自动（中英互译）", "译成简体中文", "译成英文"][rawValue] }
    }

    enum Failure: LocalizedError {
        case sameLanguage(String)
        case notInstalled(String)
        case unsupported(String)
        case needsNewerSystem

        var errorDescription: String? {
            switch self {
            case .sameLanguage(let name): return "原文已经是\(name)"
            case .notInstalled(let pair): return "没有下载\(pair)的翻译语言包，请到「系统设置 › 通用 › 语言与地区 › 翻译语言」下载后再试"
            case .unsupported(let pair): return "系统翻译不支持\(pair)"
            case .needsNewerSystem: return "截图翻译需要 macOS 26 或更新版本"
            }
        }
    }

    /// Remembered between results.
    static var target: Target {
        get { Target(rawValue: UserDefaults.standard.integer(forKey: "translateTarget")) ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "translateTarget") }
    }

    static let chinese = Locale.Language(identifier: "zh-Hans")
    static let english = Locale.Language(identifier: "en")

    /// The dominant language of `text`, English when it can't tell. Screenshots mix Chinese with
    /// product names and numbers, which the statistical recogniser takes for Italian and the like, so
    /// text counts as Chinese once Han characters make up a fair share of it (one carries about as
    /// much as a four-letter word), unless it has kana or hangul.
    static func detect(_ text: String) -> Locale.Language {
        var han = 0, latin = 0, kanaOrHangul = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: han += 1
            case 0x3040...0x30FF, 0xAC00...0xD7AF: kanaOrHangul = true
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if han > 0, !kanaOrHangul, han * 4 >= latin {
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
            recognizer.processString(text)
            return recognizer.dominantLanguage == .traditionalChinese ? Locale.Language(identifier: "zh-Hant") : chinese
        }
        let recognizer = NLLanguageRecognizer()
        // Short UI strings are easily mistaken for other languages; most screenshots are English.
        recognizer.languageHints = [.english: 0.6, .simplifiedChinese: 0.2]
        recognizer.processString(text)
        return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) } ?? english
    }

    /// Source and target for `text`; `auto` turns Chinese into English and anything else into Chinese.
    static func languages(for text: String, target: Target) throws -> (source: Locale.Language, target: Locale.Language) {
        let source = detect(text)
        let isChinese = source.languageCode == .chinese
        let to: Locale.Language
        switch target {
        case .auto: to = isChinese ? english : chinese
        case .chinese: to = chinese
        case .english: to = english
        }
        if source.languageCode == to.languageCode { throw Failure.sameLanguage(name(of: to)) }
        return (source, to)
    }

    static func name(of language: Locale.Language) -> String {
        if language.languageCode == .chinese { return language.script == .hanTraditional ? "繁体中文" : "简体中文" }
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: code) ?? code
    }

    /// Each line translated on its own, columns split by tabs too, so the layout comes back unchanged.
    /// Blank lines stay blank.
    @MainActor
    static func translate(_ text: String, from source: Locale.Language, to target: Locale.Language) async throws -> String {
        var cells = text.components(separatedBy: "\n").map { $0.components(separatedBy: "\t") }
        let flat = try await translate(segments: cells.flatMap { $0 }, from: source, to: target)
        var k = 0
        for i in cells.indices {
            for j in cells[i].indices { cells[i][j] = flat[k]; k += 1 }
        }
        return cells.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    /// Every segment translated on its own, in one batch; blank ones come back unchanged.
    @MainActor
    static func translate(segments: [String], from source: Locale.Language, to target: Locale.Language) async throws -> [String] {
        guard #available(macOS 26, *) else { throw Failure.needsNewerSystem }
        let pair = "\(name(of: source))到\(name(of: target))"
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: break
        case .supported: throw Failure.notInstalled(pair)
        default: throw Failure.unsupported(pair)
        }
        let key = source.minimalIdentifier + ">" + target.minimalIdentifier
        let session: TranslationSession
        if let cached = sessions[key] as? TranslationSession {
            session = cached
        } else {
            session = TranslationSession(installedSource: source, target: target)
            sessions[key] = session
        }
        var out = segments
        let requests = segments.enumerated().compactMap { i, segment in
            segment.trimmingCharacters(in: .whitespaces).isEmpty ? nil : TranslationSession.Request(sourceText: segment, clientIdentifier: "\(i)")
        }
        guard !requests.isEmpty else { return out }
        for response in try await session.translations(from: requests) {
            if let i = response.clientIdentifier.flatMap(Int.init) { out[i] = response.targetText }
        }
        return out
    }

    /// One session per language pair; the first translation in a session takes ~0.5 s, later ones ~25 ms.
    @MainActor private static var sessions: [String: Any] = [:]
}
