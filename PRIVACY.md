# MenubarCalendar Privacy Policy

Last updated: 4 October 2026

MenubarCalendar is a macOS menu-bar app that shows your next calendar event and
opens meeting links. It runs entirely on your Mac. There is no MenubarCalendar
server, account, analytics or tracking.

## What the app accesses

**Google Calendar** (only if you connect a Google account). The app asks Google for:

- `calendar.calendarlist.readonly`: the list of your calendars, with their names
  and colours.
- `calendar.events`: the events on those calendars, from the start of today to
  seven days ahead. The app also uses this permission to change one thing: when
  you choose **Decline** on an event, it sets your own response to "declined",
  and Google notifies the organizer.

**macOS Calendar** (only if you choose that data source). Through Apple's
EventKit, the app reads the calendars and events configured on your Mac. When
you use **Edit** or **Decline**, it saves the change there.

**Google Chrome profile settings.** The app reads Chrome's local `Local State`
and `Preferences` files to find out which Chrome profile each of your accounts
is signed into. That lets a meeting open in the right profile.

## Where your data goes

- Calendar data is fetched directly from Google, or read from macOS, and is kept
  only in the app's memory while it runs. It is never sent anywhere else.
- Google sign-in tokens are stored in your macOS Keychain, one entry per account.
- Your settings (data source, selected calendars, Chrome profile choices,
  keyboard shortcut) are stored in the app's local preferences on your Mac.
- A local debug log (`/private/tmp/mbc_diag.log`) may record account
  addresses and error messages. macOS clears it on restart.
- The only network requests the app makes go to Google (`accounts.google.com`,
  `oauth2.googleapis.com`, `www.googleapis.com`).
- No data is sold, shared with third parties, or used for advertising.

MenubarCalendar's use of information received from Google APIs adheres to the
[Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
including the Limited Use requirements.

## Removing your data

- **Disconnect an account:** Settings → Konta Google → **Usuń**. This deletes
  the account's tokens from the Keychain.
- **Revoke Google access:** go to your Google Account → Security →
  [Third-party apps & services](https://myaccount.google.com/connections), then
  remove MenubarCalendar.
- **Remove everything:** quit the app and delete it. Delete its Keychain entries
  (service `com.rc.MenubarCalendar.google`) and its preferences
  (`defaults delete com.rc.MenubarCalendar`).

## Contact

Questions or concerns:
[open an issue](https://github.com/radekcabaj/MenubarCalendar/issues).
