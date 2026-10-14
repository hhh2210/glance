// Offline fixtures compile the production policy, without AX, camera or passwords.
// Chinese wording below is proposed, not a claim of live macOS localization support.
import Foundation

@main
@MainActor
enum AutoFillPolicySelfTest {
    static var checks = 0
    nonisolated static let english = [
        "AutoFill for “test@example.com”",
        "Enter the computer account password for the user “tester”. Authentication for AutoFill can be turned off in the Touch ID pane of System Settings."
    ]
    nonisolated static let simplified = ["自动填充“test@example.com”", "请输入用户“tester”的电脑账户密码。"]
    nonisolated static let traditional = ["自動填寫「test@example.com」", "請輸入使用者「tester」的電腦帳號密碼。"]

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        checks += 1
        guard condition() else { fatalError("Line \(line): \(message)") }
    }

    static func evidence(
        texts: [String] = english,
        buttons: [String] = ["AutoFill", "Cancel"],
        fields: Int = 1,
        empty: Bool = true,
        editable: Bool = true,
        focused: Bool = true,
        appleSigned: Bool = true,
        onScreen: Bool = true,
        unlocked: Bool = true,
        belongs: Bool = true
    ) -> AutoFillPromptEvidence {
        AutoFillPromptEvidence(
            staticTexts: texts, buttonTitles: buttons, secureFieldCount: fields,
            isFieldEmpty: empty, isFieldEditable: editable, isFieldFocused: focused,
            isAppleSignedOwner: appleSigned, isOnScreen: onScreen,
            sessionIsUnlocked: unlocked, belongsToCurrentUser: belongs
        )
    }

    static func main() {
        expect(AutoFillPromptPolicy.accepts(evidence()), "observed English wording")
        expect(AutoFillPromptPolicy.accepts(evidence(texts: simplified, buttons: ["自动填充", "取消"])),
               "proposed simplified Chinese wording")
        expect(AutoFillPromptPolicy.accepts(evidence(texts: traditional, buttons: ["自動填寫", "取消"])),
               "proposed traditional Chinese wording")
        expect(AutoFillPromptPolicy.accepts(evidence(texts: [
            "Enter the computer account password for the user \"tester\"."
        ])), "explicit action and computer-account body suffice without a separate title")

        expect(!AutoFillPromptPolicy.accepts(evidence(appleSigned: false)), "lookalike app cannot qualify")
        expect(!AutoFillPromptPolicy.accepts(evidence(empty: false)), "never replace existing field contents")
        expect(!AutoFillPromptPolicy.accepts(evidence(editable: false)), "read-only field")
        expect(!AutoFillPromptPolicy.accepts(evidence(focused: false)), "unfocused field")
        expect(!AutoFillPromptPolicy.accepts(evidence(onScreen: false)), "hidden dialog")
        expect(!AutoFillPromptPolicy.accepts(evidence(unlocked: false)), "locked or unknown session")
        expect(!AutoFillPromptPolicy.accepts(evidence(belongs: false)), "different computer account")
        for count in [0, 2, 3] {
            expect(!AutoFillPromptPolicy.accepts(evidence(fields: count)), "exactly one secure field is required")
        }
        expect(!AutoFillPromptPolicy.accepts(evidence(buttons: ["AutoFill"])), "cancel action is required")
        expect(!AutoFillPromptPolicy.accepts(evidence(buttons: ["OK", "Cancel"])), "generic confirmation is not AutoFill")
        expect(!AutoFillPromptPolicy.accepts(evidence(buttons: ["Enable AutoFill", "Cancel"])), "settings action is not AutoFill")

        for body in [
            "Enter your password to use AutoFill.",
            "Enter the website password for the user “tester”.",
            "Enter the Mac password.",
            "Enter the computer account password for the user tester.",
            "Do not enter the computer account password for the user “tester”.",
            "请输入密码以继续自动填充。",
            "請輸入密碼以繼續自動填寫。"
        ] {
            expect(!AutoFillPromptPolicy.accepts(evidence(texts: ["AutoFill", body])), "ambiguous or unsupported wording")
        }
        for otherContext in [
            "Enter your login keychain password.",
            "Enter an administrator password to make changes.",
            "Unlock Passwords to continue.",
            "请输入钥匙串密码。", "請輸入管理員密碼。", "解锁密码库。"
        ] {
            expect(!AutoFillPromptPolicy.accepts(evidence(texts: english + [otherContext])),
                   "other authentication contexts remain excluded")
        }

        expect(AutoFillPromptPolicy.mentionsCurrentUser(in: english, aliases: ["tester-new", "tester"]),
               "display-name alias is a complete match")
        expect(AutoFillPromptPolicy.mentionsCurrentUser(in: english, aliases: ["TESTER"]), "account matching ignores case")
        expect(AutoFillPromptPolicy.mentionsCurrentUser(in: simplified, aliases: ["tester"]), "simplified account extraction")
        expect(AutoFillPromptPolicy.mentionsCurrentUser(in: traditional, aliases: ["tester"]), "traditional account extraction")
        expect(!AutoFillPromptPolicy.mentionsCurrentUser(in: english, aliases: []), "no known account aliases")
        expect(!AutoFillPromptPolicy.mentionsCurrentUser(in: english, aliases: ["", "test"]), "no substring match")
        expect(!AutoFillPromptPolicy.mentionsCurrentUser(in: english, aliases: ["test@example.com"]),
               "website identity is not the computer account")

        let differentUser = ["AutoFill for “tester@example.com”", "Enter the computer account password for the user “tester-other”."]
        let belongs = AutoFillPromptPolicy.mentionsCurrentUser(in: differentUser, aliases: ["tester"])
        expect(!belongs && !AutoFillPromptPolicy.accepts(evidence(texts: differentUser, belongs: belongs)),
               "username prefix in both title and account cannot authorize")
        let differentFullName = ["Enter the computer account password for the user “Tester Other”."]
        expect(!AutoFillPromptPolicy.mentionsCurrentUser(in: differentFullName, aliases: ["Tester"]),
               "first word of a full name is not a complete alias")
        expect(!AutoFillPromptPolicy.mentionsCurrentUser(in: differentUser + ["Current user: tester"], aliases: ["tester"]),
               "unrelated text cannot supply the account match")
        let conflictingUsers = english + ["Enter the computer account password for the user “someone-else”."]
        expect(!AutoFillPromptPolicy.mentionsCurrentUser(in: conflictingUsers, aliases: ["tester", "someone-else"]),
               "two different account names are ambiguous even when both are aliases")
        expect(!AutoFillPromptPolicy.accepts(evidence(texts: conflictingUsers)), "conflicting account bodies cannot qualify")
        expect(AutoFillPromptPolicy.mentionsCurrentUser(in: english + english, aliases: ["tester"]),
               "duplicated AX labels for the same account are unambiguous")

        print("AutoFill prompt policy self-test: \(checks) checks passed (synthetic metadata; no live dialog verification).")
    }
}
