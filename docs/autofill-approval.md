# Experimental AutoFill approval

This branch adds an opt-in prototype for the Apple AutoFill dialog that says
“Enter the computer account password for the user …”. It is disabled by default.
It has **not** completed an end-to-end test against Apple's native AutoFill dialog.

## Behavior

After enabling **General → AutoFill → Approve AutoFill with your face**, close
Settings. Glance watches for a supported, focused, empty Apple AutoFill password
field while the desktop and existing Glance credential session are unlocked.
Enrollment must be readable and liveness checks must be enabled.

Glance uses the same face/liveness scanner as lock-screen unlock. A small
nonactivating panel provides Cancel during scanning and for one second after
verification. Each native window is attempted once; cancellation or failure leaves
the original system authentication flow available. Setup and Face Lab take priority.

The adapter checks the running process's Apple signature and known authentication
bundle identifier, explicit computer-account wording, current user's full or short
name, a unique secure field, global focus, and visible window bounds. It retains
the AX window/field/button and a digest of the prompt text. All are checked again
after asynchronous work and before submission. Unknown or changed targets stop.

Writing uses `AXUIElementSetAttributeValue` on that retained field and `AXPress` on
that retained button. No clipboard or global keystroke fallback is used. Glance does
not read secure-field values; it checks character count only. If direct writes,
character-count inspection, focus, or the expected accessibility structure are
unavailable, the prototype does nothing. A submitted action is not reported as
successful authentication.

## Verification and limits

- The pure policy has 43 passing checks, including wrong owners/users, nonempty
  fields, focus/session changes, multiple secure fields, and unrelated password
  dialogs. English wording comes from an observed screenshot; Chinese fixtures
  are proposed translations, not live system observations.
- Seven production-adapter checks cover retained control identity, request-text
  changes, cancellation before delivery, and rejection of a non-Apple process.
  They use public fixture bytes and never open a window or retrieve a credential.
- The existing 121 enrollment-state checks remain the lock-screen regression
  suite. Camera recognition and real-password delivery require separate runtime
  verification; these offline tests do not establish those outcomes.
- A standalone AppKit secure-field fixture on Desktop 2 accepted a fixed public
  test string and received one button action via Computer Use. The fixture
  independently reported exact-string equality and one submission. This verifies
  that fixture's AX behavior, not this production adapter or Apple AutoFill.
- Raw AX window enumeration for the fixture returned an empty array from the
  command-line probe while Computer Use could see its controls. The cause is not
  established; no permission settings were changed to work around it.
- A standalone `LAContext` probe with a memory-only `.devicePasscode` access
  constraint entered authentication, but the system authentication agent took
  foreground focus despite the probe window being on Desktop 2. The probe was
  cancelled without entering a password. Native AutoFill delivery is therefore
  still unverified. No Passwords vault, authorization database, or PAM rules were
  accessed or modified by these probes.

Keep this as an experimental branch until a real AutoFill request proves discovery,
cancellation, the direct AX write, and the requesting application's completed
AutoFill behavior. Its accessibility shape can differ from ordinary AppKit fields.

## API evidence

Apple documents the Mac-password AutoFill fallback in its
[Safari guide](https://support.apple.com/en-mide/guide/safari/ibrwf71ba236/mac).
[`LAContext.evaluateAccessControl`](https://developer.apple.com/documentation/localauthentication/lacontext/evaluateaccesscontrol(_:operation:localizedreason:reply:))
can evaluate an in-memory access control; the
[`.devicePasscode` constraint](https://developer.apple.com/documentation/security/secaccesscontrolcreateflags/devicepasscode)
provides a narrower probe than a biometric-first policy. A
[macOS implementation example](https://github.com/chainapsis/vizor-wallet/blob/857c047c6bb7de47f41025e7b8f47ab950b73bb4/macos/Runner/MainFlutterWindow.swift#L1035)
uses that public path. These APIs do not register a custom biometric provider for
other applications' LocalAuthentication requests.
