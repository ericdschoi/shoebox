# Two-pane layout on iPhone Duo

Agreed 2026-11-20. Terms are defined in `GLOSSARY.md`.

Decisions: design for two panes inside the app when open; Split View falls back to the closed layout; keep iOS 26 as the minimum; half-folded is left to the system; closed layout does not change.

## 1. Build with the iOS 27.1 SDK
- [x] CI builds on the Xcode 27 image
- [x] Closed layout on an ordinary iPhone looks the same as before (CI screenshots, iPhone 18 Pro simulator)
- [ ] CI captures the app on the iPhone Duo simulator. Blocked: the Duo simulator will not boot on GitHub's hosted runner (simctl error 22), and simctl cannot unfold it anyway

## 2. Expenses and Withdrawals in two panes
- [ ] Open: list on the left, selected item on the right
- [ ] Open with nothing selected: the first item is shown
- [ ] Unfolding keeps the item you were on; folding keeps you on it with a back button
- [ ] Deleting the selected item moves to another item, never a blank or "not found" pane
- [ ] Receipts are shown large in the right pane; tapping still opens the full viewer

## 3. Summary in two columns, tabs in a sidebar
- [ ] Open: Summary cards in two columns
- [ ] Open: tabs in a sidebar, with a Settings switch back to the tab bar

## Not yet verified
Nothing in sections 2 onward has been seen on an open iPhone Duo. Check each item on the phone, or in the iPhone Duo simulator in Xcode 27.1 on the Mac mini (Device Hub, Open button).
