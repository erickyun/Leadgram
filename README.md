# Lead 1.4.4 + TGExtra 1.7.9 + iQTele 1.4
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
There are four independent GitHub Actions **boolean** inputs:

- **Lead** (default enabled)
- **TGExtra** (default disabled)
- **iQTele** (default disabled)
- **Privacy Controls** (default enabled)

You can select more than one. All selected .deb packages plus PrivacyControls
(if enabled) are injected by cyan into the **same IPA**. Multiple independently
developed tweaks may conflict; start by testing each one separately before
enabling all three. No source code for the proprietary bundled tweaks is changed.

### Privacy Controls: five toggles

- **Hide Avatars** — hides known avatar/profile-picture UI components (not
  ordinary message photos and videos).
- **Hide Sender Names** — hides identifiable message sender/author name nodes.
- **Hide Usernames** — hides identifiable username labels and standalone
  `@handles` in profile/contact/search identity contexts (not message mentions).
- **Hide Names** — hides identifiable display-name/title nodes in peer-related
  screens and chat lists.
- **Hide Reactions** — hides dedicated reaction button/list/footer UI nodes.

**Open the menu:** long-press anywhere with **three fingers** for about one
second. Tap each row to switch it on/off; changes are saved locally using
`NSUserDefaults`. **Done** closes the menu. All five toggles start **off**
until you enable them.

**Important limitations:** This is an initial best-effort runtime/heuristic
implementation. Telegram, Nicegram, Swiftgram, Turrit, Vartagram and Nagram
have different internal views, and dynamically rendered Swift/Texture nodes
are not all discoverable by Objective-C. Therefore this feature **does not
guarantee hiding every name, username, sender name, avatar or reaction in every
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
