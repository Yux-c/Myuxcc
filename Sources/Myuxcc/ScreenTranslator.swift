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
            // 使用 autoreleasepool 及时释放 NLLanguageRecognizer 底层自动释放对象并显式重置
            return autoreleasepool {
                let recognizer = NLLanguageRecognizer()
                defer { recognizer.reset() }
                recognizer.languageConstraints = [.simplifiedChinese, .traditionalChinese]
                recognizer.processString(text)
                return recognizer.dominantLanguage == .traditionalChinese ? Locale.Language(identifier: "zh-Hant") : chinese
            }
        }
        // 使用 autoreleasepool 及时释放 NLLanguageRecognizer 底层自动释放对象并显式重置
        return autoreleasepool {
            let recognizer = NLLanguageRecognizer()
            defer { recognizer.reset() }
            // Short UI strings are easily mistaken for other languages; most screenshots are English.
            recognizer.languageHints = [.english: 0.6, .simplifiedChinese: 0.2]
            recognizer.processString(text)
            return recognizer.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) } ?? english
        }
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
        // 触发系统内存告警监听初始化，确保系统内存紧张时主动清空翻译会话缓存
        _ = memoryPressureSource

        let key = source.minimalIdentifier + ">" + target.minimalIdentifier
        let session: TranslationSession
        let usedCachedSession: Bool
        // 优先检查会话缓存，命中且未达复用次数上限时直接复用，跳过跨进程 LanguageAvailability XPC 查询
        if var entry = sessions[key],
           entry.useCount < maxSessionUses,
           let cached = entry.session as? TranslationSession {
            entry.useCount += 1
            entry.lastUsed = Date()
            sessions[key] = entry
            session = cached
            usedCachedSession = true
        } else {
            // 超过复用上限或缓存未命中时移除旧会话，重新查询语言包可用性并创建新会话
            sessions.removeValue(forKey: key)
            let pair = "\(name(of: source))到\(name(of: target))"
            switch await LanguageAvailability().status(from: source, to: target) {
            case .installed: break
            case .supported: throw Failure.notInstalled(pair)
            default: throw Failure.unsupported(pair)
            }
            // 限制缓存的总会话数上限，超出时淘汰最久未使用的语言对会话
            while sessions.count >= maxCachedSessions,
                  let oldestKey = sessions.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
                sessions.removeValue(forKey: oldestKey)
            }
            session = TranslationSession(installedSource: source, target: target)
            sessions[key] = CachedSession(session: session, useCount: 1, lastUsed: Date())
            usedCachedSession = false
        }
        // 每次调用翻译后重置会话缓存的空闲清理计时器，闲置后自动释放 TranslationSession 缓存
        scheduleSessionCleanup()
        var out = segments
        let requests = segments.enumerated().compactMap { i, segment in
            segment.trimmingCharacters(in: .whitespaces).isEmpty ? nil : TranslationSession.Request(sourceText: segment, clientIdentifier: "\(i)")
        }
        guard !requests.isEmpty else { return out }
        do {
            for response in try await session.translations(from: requests) {
                if let i = response.clientIdentifier.flatMap(Int.init) { out[i] = response.targetText }
            }
        } catch {
            // 复用缓存会话报错时立即失效该条目，保证下次调用能重新校验并重建会话
            if usedCachedSession { sessions.removeValue(forKey: key) }
            throw error
        }
        return out
    }

    /// 缓存中的翻译会话条目，记录会话实例、累计复用次数与最近使用时间
    private struct CachedSession {
        let session: Any
        var useCount: Int
        var lastUsed: Date
    }

    /// One session per language pair; the first translation in a session takes ~0.5 s, later ones ~25 ms.
    @MainActor private static var sessions: [String: CachedSession] = [:]
    /// 单个 TranslationSession 的最大连续复用次数，避免长期高频复用导致内部状态持续膨胀
    private static let maxSessionUses = 16
    /// 同时缓存的语言对会话容量上限
    private static let maxCachedSessions = 4
    /// 翻译会话空闲清理任务，避免长时间不使用翻译功能时仍常驻持有系统翻译会话上下文
    @MainActor private static var sessionCleanupWorkItem: DispatchWorkItem?
    /// 翻译会话缓存的最大空闲保留时长（120 秒）
    private static let sessionIdleTimeout: TimeInterval = 120
    /// 系统内存压力监听源，在 warning / critical 告警时立即释放所有缓存的 TranslationSession
    @MainActor private static let memoryPressureSource: DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                clearSessions()
            }
        }
        source.resume()
        return source
    }()

    /// 清空全部缓存的翻译会话并取消挂起的空闲回收任务
    @MainActor static func clearSessions() {
        sessionCleanupWorkItem?.cancel()
        sessionCleanupWorkItem = nil
        sessions.removeAll()
    }

    /// 重置翻译会话空闲回收计时器，超时后清空 sessions 字典
    @MainActor private static func scheduleSessionCleanup() {
        sessionCleanupWorkItem?.cancel()
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                clearSessions()
            }
        }
        sessionCleanupWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + sessionIdleTimeout, execute: item)
    }
}
