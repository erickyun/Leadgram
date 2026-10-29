# Lead 1.4.4 + TGExtra 1.7.9 + iQTele 1.5
A simple Telegram iOS Tweak.
> [!NOTE]
> - To Open Tweak menu : Open settings and scroll down to "Ask a Question" and hold press to pull up the settings.
> - for iQTele Tap the iQ logo at the top right-hand corner

Credits:

[@Lead](https://t.me/Leadgramm) 

[@TGExtra](https://t.me/ultimatePoison)

[@iQTele](https://t.me/iQTweak)


## Multi-tweak builds (feature/privacy-controls-and-multi-tweak)

Go to **Actions → Build IPA → Run workflow** and **select this feature branch**.
Enter a direct URL to a decrypted IPA and choose the correct app.
There are four independent tweak inputs, plus an advanced unsafe-combination override:

- **Lead** (default enabled)
- **TGExtra** (default disabled)
- **iQTele** (default disabled)
- **Privacy Controls** (default enabled)

**Safety guard (2026-10-29):** A crash report from Telegram 13.1.1, iOS 27.0.1,
with Lead + TGExtra + iQTele loaded shows an uncaught Objective-C exception:
`-[__NSArrayM insertObject:atIndex:]: object cannot be nil` on
`org.mtproto.managerQueue`. The failing call chain enters `TGExtra.dylib`
from `Lead.dylib`. The privacy dylib was loaded but does not appear in the
crashing call chain. This strongly suggests a Lead/TGExtra interaction, but
the exact underlying bug and standalone tweak compatibility are **not yet verified**.

For now the workflow **rejects two or more of Lead/TGExtra/iQTele by default**.
Select just one, plus **Privacy Controls** if desired. To deliberately run an
unsafe compatibility experiment, enable `allow_unsafe_multi_tweak` in Actions.
This may reproduce the crash and is **not recommended for daily use**.
The build system still supports multiple packages when the guard is explicitly
overridden. No source code for the third-party bundled tweaks was changed.

**Suggested isolation order (same decrypted base IPA and bundle ID):**
1. Only Privacy Controls (all six privacy toggles OFF) — confirms standalone load.
2. Lead + Privacy Controls — tests the most relevant desired combination.
3. TGExtra + Privacy Controls (without Lead) — tests TGExtra separately.
4. iQTele + Privacy Controls (without Lead/TGExtra).
5. Only after independent testing, cautiously try multi-tweak builds if needed.

If reinstalling over an existing app, preserve the **exact same bundle identifier**
and signing method. The supplied crash log uses `ph.telegra.Telegraphx`;
the workflow's default Telegram bundle ID is `ph.telegra.Telegraph`.
Use the optional **bundle_id_override** input with `ph.telegra.Telegraphx`
to build with the same identifier, provided that identifier is indeed the one
installed on your device. A different identifier creates a separate app rather
than an in-place update. Sign with the same certificate/profile if updating
in place; always back up critical local-only data before replacing an IPA.

### Privacy Controls: six toggles

- **Hide Avatars** — hides known avatar/profile-picture UI components (not
  ordinary message photos and videos).
- **Hide Sender Names** — hides identifiable message sender/author name nodes, including the `nameNode` directly under `ChatMessageBubbleItemNode`.
- **Hide Usernames** — hides identifiable username labels and standalone
  `@handles` in profile/contact/search identity contexts (not message mentions).
- **Hide Names** — hides identifiable display-name/title nodes in peer-related
  screens and chat lists, **including message sender-name headers**.
- **Hide Reactions** — hides dedicated reaction button/list/footer UI nodes,
  including `MessageReactionButtonsNode` and inline `StatusReactionNode` when identified.
- **Hide Comments** — hides channel-post comment/footer buttons and thread/reply entry controls,
  not the text of actual comments inside a discussion.

**Open the menu:** long-press anywhere with **three fingers** for about one
second. Tap each row to switch it on/off; changes are saved locally using
`NSUserDefaults`. **Done** closes the menu. All six toggles start **off**
until you enable them.

**Important limitations:** This is an initial best-effort runtime/heuristic
implementation. Telegram, Nicegram, Swiftgram, Turrit, Vartagram and Nagram
have different internal views, and dynamically rendered Swift/Texture nodes
are not all discoverable by Objective-C. Therefore this feature **does not
guarantee hiding every name, username, sender name, avatar, reaction or comment button in every
view and app version**. Plain message text is deliberately left untouched.
Changing visibility can leave empty spacing because no layout is rewritten.
Some names have no stable identity marker and may remain visible. Test on your
target Telegram IPA; use screen recordings and runtime class inspection to
refine the missed areas. Do not rely on these controls for anonymity, personal
security or hiding information in notifications/screenshots generated outside
the app.

The code is in [PrivacyControls/PrivacyControls.m](PrivacyControls/PrivacyControls.m)
and is built with Theos from [PrivacyControls/Makefile](PrivacyControls/Makefile).
The workflow only builds this dylib when Privacy Controls is enabled.

### Update: stronger detection for Telegram 13.1.1

The first runtime build missed message-header author names and channel comment controls.
This branch now matches the bubble header's name node, the explicit
`ChatMessageCommentFooterContentNode`, and common reaction footer variants.
It also checks attached views via `didMoveToWindow` so views created before
window attachment are not skipped. Avatar detection includes animated avatar
sets and component-style avatars, plus a tightly scoped circular-image fallback
inside contact/chat/search rows. **Ordinary message media remains excluded**.

**Testing:** With your already-working tweak combination, rebuild from this
branch and toggle **Hide Names**, **Hide Reactions**, **Hide Comments**, and
**Hide Avatars** one at a time. If a message element remains visible, report
which chat type (group/channel/private), target element, and screenshot.
The code has not yet been built or tested on an actual iPhone, and the runtime
rules may need app-version-specific refinements.


### Fix: group sender headers and avatars reappearing after navigation

After feedback from the Telegram 13.1.1 build, the privacy code now:

- Detects `TextNode` author labels placed directly under
  `ChatMessageBubbleClippingNode`, without relying on the unavailable
  `attributedText` selector. This specifically targets names above group messages.
- Guards a previously hidden view against being unhidden during Telegram UI recycling
  (hooks `UIView setHidden:` only to re-enforce previously marked views).
- Rechecks views when inserted into the hierarchy and when a Telegram
  navigation controller displays a screen again (`viewDidAppear:`).
  This is meant to keep profile pictures hidden when entering and exiting
  the same group/channel repeatedly.
- Preserves independent Hide Sender Names / Hide Names / Hide Avatars switches,
  and deliberately does not blank the actual message body.

**Not device-verified:** these hooks are best-effort for Telegram 13.1.1.
Use the same stable third-party tweak combination as your last working build.
Test (1) names over messages in groups, (2) channel author/title labels,
(3) avatar visibility after entering/leaving the same group or channel 3+
times, and (4) switch each feature OFF and verify hidden views return.
