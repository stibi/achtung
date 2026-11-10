# 0018: Notifications survive restarts, and skip the alert on screen

- Status: accepted
- Date: 2026-11-10

## Context

ADR 0013 kept the notification baseline and ledger in memory: "Nothing is saved". Every
launch, the first refresh set the baseline to the newest event it saw. So whatever fired
or was resent while Achtung wasn't running (an update with `install.sh`, a crash, the Mac
logging in) never notified. Those were exactly the alerts the user hadn't seen.

A banner also showed while the user was already looking at that alert: a resend of the
alert open in the window played a sound and posted a banner about what was on screen.

## Decision

- **The baseline and the ledger are saved per server**, after every refresh, in the
  app's defaults (`notificationState <server URL>`, JSON of
  `AlertNotificationState.Saved`), together with the severities picked and when it was
  saved. On launch, or on switching to a server, Achtung continues from that server's
  saved state instead of the newest event. What came while it was closed notifies once,
  more than three as the usual summary. What was announced before doesn't repeat. The
  read, silenced, severity and ignored-name filters apply as before.
- **A saved state older than a day is let go.** The first refresh then only sets the
  baseline, as on a first launch, so a relaunch after a week off doesn't flood. (A Mac
  that slept for a week with Achtung running still announces on waking what came since,
  as before: at most one summary.) The age is
  that of the save (the last refresh), not of the baseline. On a quiet server the baseline
  can be days old while Achtung ran all along, and that state is still right.
- **Off and paused still move the baseline**, and the move is saved, so turning
  notifications back on after a restart announces nothing from while they were off. A
  severity picked while Achtung was closed starts from now, as it would have running.
- **The alert on screen gets no banner.** When Achtung is the active app, its main window
  is key, and that window shows an alert's detail in a channel, a new event of that alert
  counts as announced without a banner or sound. It doesn't notify later either. A list
  (a channel's, Live, or search results) still notifies: the row may be out of sight. Only
  the ones that remain count towards a summary. The decision is a parameter of
  `AlertNotificationState.refreshed` in AchtungDomain, with tests. The app only says
  which alert is on screen.
- The ledger still forgets events older than a week, and nothing older than that
  notifies, however old the baseline: otherwise an event the ledger forgot would notify
  again on every refresh.

## Consequences

- Restarting Achtung no longer loses notifications, as long as it comes back within a
  day.
- Development builds share the installed app's defaults, so they share its saved state
  for a server too: an event either of them announced doesn't notify again from the
  other. `demo.sh` removes the demo server's saved state, as its clock starts afresh each
  run.
- Saved states of servers Achtung has left stay in the defaults; each is small.
- The defaults hold a little more per server: one date per occurrence announced in the
  last week.
