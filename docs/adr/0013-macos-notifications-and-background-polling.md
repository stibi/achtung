# 0013: macOS notifications, polled in the background

- Status: accepted
- Date: 2026-11-10

## Context

Achtung only showed what fired while its window was open: the inbox refreshed every 30
seconds from a loop in the window's view, and closing the last window quit the app. A
critical alert that fired while the window was closed, or buried behind other windows,
went unnoticed until the user looked. The user wants a macOS notification for critical
alerts, with the actions the app offers (mark read, silence) right on it.

There is no server push yet (ADR 0001), so whatever notifies has to poll.

## Decision

- **The client notifies, from its own polling.** No server change: the server knows
  nothing about this Mac's read state, which decides what is new to the user, and it has
  no way to reach a Mac. An app-level `AppModel` owns the server connection
  (`InboxModel`) and refreshes it every 30 seconds whether or not a window is open; the
  window reads the model and only says which list it shows. Opening a list and coming
  back to the app still refresh at once.
- **Closing the last window doesn't quit.** Achtung stays in the menu bar (a
  `MenuBarExtra`): a bell with the count of unread, unsilenced, not ignored firing
  critical alerts, the newest five of them, Mark Critical Alerts as Read, Pause
  Notifications (an hour, or until 8:00 tomorrow), Settings and Quit. Quit is now the way
  to stop polling. The main window is a single `Window`: a notification or the menu
  brings it back, also from the Dock, instead of opening another, since the one inbox
  model has one list on screen to keep fresh.
- **What notifies** is a pure function in AchtungDomain (`AlertNotificationState`,
  `NotificationLedger.notifying`): an occurrence whose last event is a firing, a reopen or
  a resend (ADR 0009), of a severity picked in Settings (critical by default, warning
  optional), not resolved, not silenced, not read on this Mac, and not named on the
  server's ignored list (ADR 0011). Inhibition isn't known to the client, so an inhibited
  alert that reaches Achtung notifies like any other.
- **No flood on launch, and each event once.** The first refresh after launch, or after
  switching servers, only sets a baseline: the newest event it sees, in server time. Later
  events notify once each: a ledger in memory keeps, per occurrence, the event it
  announced, forgetting events older than a week. Nothing is saved: after a restart the
  new baseline keeps everything announced before quiet (superseded by ADR 0018, which
  saves the baseline and the ledger per server). While notifications are off or
  paused, the baseline moves to the newest event; a severity picked since the last refresh
  has what it would announce recorded quietly instead, so turning something on announces
  nothing old. Both live in `AlertNotificationState` in AchtungDomain, with tests.
- **Up to three at once notify one by one**, title the alertname, subtitle
  "instance · #channel", body the summary, grouped per channel. More become one summary
  ("5 critical alerts on onprem") naming the first three.
- **Actions under "Options":** Mark as Read, and Silence 1h, 4h, 1d, 1w, built from
  `SilenceDuration` and going through the same `InboxModel.silence` as the in-app button
  (ADR 0008); a failed silence or mark, or an action for a server Achtung has since left,
  posts a short notification with the reason. A summary has only Mark All as Read:
  silencing many alerts from one banner is too easy to do by accident. Clicking opens the
  alert in its channel, or a summary's channel or Live. A notification is identified by
  its occurrence, so a resend replaces it, and reading the alert anywhere in the app
  removes it.
- **Permission** is asked the first time notifications are on, which macOS remembers.
  Settings says when macOS denies it and links to System Settings.

## Consequences

- Achtung polls the server every 30 seconds for as long as it runs, also with no window:
  a few small requests, and a little CPU per refresh, idle in between (no timers
  redrawing).
- Notifications depend on the Mac being awake and Achtung running. They aren't a pager;
  the pager stays with Alertmanager's own receivers.
- Development builds share the installed app's bundle identifier, so they share its
  notification permission, and clicking a development build's notification can also
  launch the installed app.
