# UI and HTML display refinement

Design prepared before implementation, 14 September 2026.

## Direction

Keep the existing HarmonyOS interface: system typography and colors, a large
Inbox title, blue unread bars, native navigation, circular toolbar controls and
an unboxed mail composer. Improve alignment, hierarchy and small-screen fit.
Use the existing Swift mail core and saved-account flow.

The companion [layout preview](ui-layout.html) shows the intended inbox, reader
and composer using fictional mail. It is a design reference, not an app capture.

## Layout

| Area | Layout to implement |
| --- | --- |
| Inbox | Keep the title and two actions. Reserve room for the unread filter; truncate a long account name. Align sender, subject, preview and divider at 20 vp. Use tighter vertical row spacing on short screens. Preserve the 3 vp unread bar at the screen edge. |
| Reader | One centered column, at most 760 vp, containing headers, attachment rows and HTML in the same outer scroll. Use 20 vp side gutters, reduced to 16 vp on narrow/short screens. |
| Reader header | Subject first, 24 sp (22 compact), then sender and date, then a labeled To summary. A native disclosure reveals complete From, To and Cc values. Long addresses wrap in details. Keep full subject text available. |
| Attachments | Keep filenames, sizes, Open and Save. Align the block with the reader header and keep a 44 vp Save target. |
| HTML | Match the reader gutter; keep sender colors and type choices. Improve default line spacing, quotes and preformatted text. Scale images within the available width. Avoid forcing all tables into equal-width columns. Keep CID images automatic and remote images behind Load pictures. |
| Composer | Keep Cancel, More and Send in their existing positions. Center fields/body in a column at most 760 vp. Use 20 vp side gutters, 16 on narrow screens, compact address labels, and a native Cc/Bcc disclosure with a 44 vp minimum tap target. |
| Tablet | Preserve native split navigation. Apply the same reading/composition measure within the detail pane rather than stretching HTML and editor text across the entire screen. |

Search stays hidden until scrolling back down or pulling to refresh; nonempty
search stays visible. The reader keeps one Reply menu. No plain-text toggle is
added. Compose keeps its separate outgoing-server sheet and existing draft/send
behavior. English and Simplified Chinese labels must remain complete.

## Implementation sequence

1. Inspect the current implementation and synthetic screenshots; record the
   layout and build its visual preview before changing the app.
2. Apply the inbox, reader and composer layout, preserving navigation and state.
3. Extract and improve the HTML document presentation with focused synthetic
   regression coverage for wide content and remote-picture consent.
4. Compile production and isolated fixture HAPs while the emulator is stopped.
5. Run prepared, bounded emulator checks with synthetic/public fixture messages
   at Pura X cover/main and MatePad portrait/landscape sizes. Inspect screenshots,
   fix material layout defects and verify shutdown after every session.
6. Package the update and record validation and any limits. Existing device
   installation authorization permits upgrade-only installation, preserving
   accounts and without launching the production app.

## Acceptance checks

- No clipped native controls or overflowing account/address labels at 327 vp.
- Inbox and composer retain their established style and action counts.
- Header and body share the same reading column and scroll together.
- HTML fixtures cover a wide newsletter, a small signature table, readable
  default text, multilingual text, CID pictures and remote-picture opt-in.
- No automated real-account access, production screenshots or real sends.
- Swift protocol code, account storage and OAuth flows are unchanged.

## Results

Implemented on 14 September 2026 after preparing the layout above and the
interactive preview. Inbox alignment, compact spacing, reader header/details,
the shared reading column and composer fields now follow that design.

HTML uses readable defaults while retaining authored styling. Explicit wide
tables shrink within the reader without expanding small signature tables;
images, quotes, preformatted text and long URLs fit the available width.
Remote-picture consent resets on message identity changes, including when two
messages contain identical HTML. ArkWeb refresh waits for the updated view
properties, and its documented no-cache mode prevents a prior document or image
from masking a consent transition. The encrypted seven-day message cache is
unchanged.

- `scripts/test`: 74 host tests passed, including nine HTML regressions.
- Focused layout checks passed at Pura X cover/main and MatePad
  portrait/landscape sizes, with three synthetic/public HTML fixtures per size.
  Screenshots were inspected for wrapping, inline images, attachment rows,
  toolbar bounds and centered columns. The final cover check also verified the
  completed HTML refresh/cache changes. One extra cover attempt failed during
  emulator credential setup; its bounded retry passed.
- The complete synthetic mail UI flow passed: language settings, inbox actions,
  unified scrolling, draft restoration, SMTP settings, Send/Reply All/Forward,
  and consent reset in one persistent renderer. The fixture recorded three
  deliveries, three explicitly allowed image requests and zero forbidden
  resource requests.
- Production x86 and signed ARM builds passed. ARM source/library parity was
  verified. The Pura X upgrade succeeded without uninstalling or launching the
  production app. MatePad was not connected, so installation there remains
  pending. Physical-device UI and real accounts were not tested.
- Every bounded emulator session shut down; the final status was stopped and
  its native process had exited.

See the [validation record](../port/mail-corpus/ui-refresh-validation.json),
[main-screen reader](screenshots/ui-refresh-main-reader.png),
[cover HTML](screenshots/ui-refresh-cover-html.png),
[cover composer](screenshots/ui-refresh-cover-compose.png),
[tablet reader](screenshots/ui-refresh-tablet-reader.png) and
[tablet composer](screenshots/ui-refresh-tablet-compose.png). These captures
contain only synthetic or public fixture mail.

## Preview parity follow-up (0.1.4)

The user requested that the installed interface match the existing preview,
while keeping the tablet split view. The preview remains the design reference.
The inbox now places its large title and two circular actions on the same row.
Light colors, row type sizes, gutters, count badges, reader cards and attachment
heights match the reference. The composer uses the reference's compact labels,
persistent Subject row, body measure and capsule controls. Native automatic
split navigation remains enabled.

Dark HTML uses ArkWeb automatic theme adaptation, including authored white
tables. Theme changes restyle the mounted document, retaining quote expansion
and picture permission. Image colors are not inverted by application CSS.

Validation and installation for this follow-up are recorded in
[release-0.1.4.md](release-0.1.4.md).
