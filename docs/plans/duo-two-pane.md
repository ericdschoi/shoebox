# Two-pane layout on iPhone Duo

Agreed 2026-11-20. Terms are defined in `GLOSSARY.md`.

Decisions: design for two panes inside the app when open; Split View falls back to the closed layout; keep iOS 26 as the minimum; half-folded is left to the system; closed layout does not change.

## 1. Build with the iOS 27.1 SDK
- [ ] CI builds on the Xcode 27 image
- [ ] Closed layout on an ordinary iPhone looks the same as before
- [ ] CI captures the app on the iPhone Duo simulator (closed; simctl cannot unfold it)

## 2. Expenses and Withdrawals in two panes
- [ ] Open: list on the left, selected item on the right
- [ ] Open with nothing selected: the first item is shown
- [ ] Unfolding keeps the item you were on; folding keeps you on it with a back button
- [ ] Deleting the selected item moves to another item, never a blank or "not found" pane
- [ ] Receipts are shown large in the right pane; tapping still opens the full viewer

## 3. Summary in two columns, tabs in a sidebar
- [ ] Open: Summary cards in two columns
- [ ] Open: tabs in a sidebar, with a Settings switch back to the tab bar
