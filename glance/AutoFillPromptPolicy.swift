import Foundation

/// Only non-secret prompt metadata belongs here. The AX adapter establishes
/// process identity, field state, session state and account ownership.
nonisolated struct AutoFillPromptEvidence {
    let staticTexts: [String]
    let buttonTitles: [String]
    let secureFieldCount: Int
    let isFieldEmpty: Bool
    let isFieldEditable: Bool
    let isFieldFocused: Bool
    let isAppleSignedOwner: Bool
    let isOnScreen: Bool
    let sessionIsUnlocked: Bool
    let belongsToCurrentUser: Bool
}

/// Recognizes a deliberately narrow subset of computer-account AutoFill prompts.
/// Matching these words alone never establishes that a window is authentic.
nonisolated enum AutoFillPromptPolicy {
    private static let autoFillButtons: Set<String> = ["autofill", "自动填充", "自動填寫"]
    private static let cancelButtons: Set<String> = ["cancel", "取消"]
    private static let excludedPhrases = [
        "keychain", "key chain", "钥匙串", "鑰匙圈", "钥匙圈",
        "password vault", "passwords vault", "unlock passwords", "password manager",
        "密码库", "密碼庫", "密码管理器", "密碼管理員",
        "administrator password", "administrator's password", "administrator’s password",
        "admin password", "administrator name", "管理员密码", "管理員密碼",
        "管理员名称", "管理員名稱"
    ]

    private static let quotedUser = #"(?:“([^”]+)”|"([^"]+)"|‘([^’]+)’|'([^']+)'|「([^」]+)」|『([^』]+)』)"#
    private static let accountPromptPatterns = [
        // Wording observed in the user's English system-prompt screenshot.
        #"^enter the computer account password for the user\s+"# + quotedUser,
        // Proposed localization fixtures, not observed live on macOS. Unknown
        // translations remain unsupported rather than matching generic 密码.
        #"^(?:请)?输入用户\s*"# + quotedUser + #"\s*的电脑账户密码"#,
        #"^(?:請)?輸入使用者\s*"# + quotedUser + #"\s*的電腦帳號密碼"#
    ]

    static func accepts(_ evidence: AutoFillPromptEvidence) -> Bool {
        guard evidence.secureFieldCount == 1,
              evidence.isFieldEmpty, evidence.isFieldEditable, evidence.isFieldFocused,
              evidence.isAppleSignedOwner, evidence.isOnScreen,
              evidence.sessionIsUnlocked, evidence.belongsToCurrentUser else { return false }

        let buttons = Set(evidence.buttonTitles.map(normalized))
        // The observed prompt has an explicit AutoFill action. A generic OK or
        // Unlock button is insufficient even if the body mentions AutoFill.
        guard !buttons.isDisjoint(with: autoFillButtons),
              !buttons.isDisjoint(with: cancelButtons) else { return false }
        let text = evidence.staticTexts.map(normalized).joined(separator: "\n")
        guard !excludedPhrases.contains(where: text.contains) else { return false }
        return accountUsers(in: evidence.staticTexts).count == 1
    }

    /// Matches the complete quoted account name in the supported password body,
    /// never an email/title, a prefix (tester-other), or another sentence.
    static func mentionsCurrentUser(in texts: [String], aliases: [String]) -> Bool {
        let users = accountUsers(in: texts)
        let aliases = Set(aliases.map(normalized).filter { !$0.isEmpty })
        guard users.count == 1, let user = users.first else { return false }
        return aliases.contains(user)
    }

    private static func accountUsers(in texts: [String]) -> Set<String> {
        let text = texts.map(normalized).joined(separator: "\n")
        var users: Set<String> = []
        for pattern in accountPromptPatterns {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { continue }
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                for group in 1..<match.numberOfRanges {
                    guard let range = Range(match.range(at: group), in: text) else { continue }
                    let user = normalized(String(text[range]))
                    if !user.isEmpty { users.insert(user) }
                }
            }
        }
        return users
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
