# Contributing to D-Mail

D-Mail is an experimental HarmonyOS port using Thunderbird's original Swift
mail core. Reuse that core where practical and keep platform adaptations explicit
in `port/`, with upstream hashes and license headers intact.

Run the host suite described in [README.md](README.md) before submitting changes.
For native changes, build with the emulator stopped, prepare a focused synthetic
fixture, then use `scripts/with-test-emulator` for a bounded run. Record what was
tested and distinguish host, emulator and physical-device evidence.

Use synthetic addresses and local fixtures in issues, tests and screenshots.
Do not include real mail, account identifiers, access/refresh tokens, passwords,
OAuth callback URLs, signing material or raw provider responses. Local tools and
credentials belong under ignored `.tools/`.

Changes must preserve saved accounts, downloaded bodies, pending operations and
notification preferences. Never automatically repeat an uncertain SMTP send or
Sent-folder APPEND. Keep account identity separate from server login, and guard
asynchronous writes against account switches and newer revisions.

Describe the problem, resulting behavior, relevant validation and known limits in
pull requests. UI changes should include screenshots from synthetic fixtures.
Historical notes under `docs/` are dated evidence; the README and newest release
record describe the current baseline.
