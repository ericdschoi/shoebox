# Shoebox

An iPhone app for the HSA "shoebox" strategy: pay medical expenses yourself, keep the proof, and
reimburse yourself tax-free years later. Shoebox files each receipt, tracks what has and hasn't been
reimbursed, and always shows the amount you could withdraw today.

Everything stays on the phone. There is no account, no server and no analytics.

## What it does

- **File an expense in seconds.** Scan a receipt, pick a photo, import a PDF, or send a file to
  Shoebox from another app's share sheet. On-device text recognition fills in the provider, date of
  service and amount, with one-tap alternatives when the first guess is wrong.
- **One number.** The Summary tab shows what is available to reimburse, backed by paperwork.
- **Paperwork checklist.** Each expense shows whether its receipt and Explanation of Benefits are on
  file, and the Summary lists what is still missing.
- **Withdrawals.** Record money taken from the HSA and Shoebox matches it to your oldest expenses
  first, or to the ones you choose. Anything unmatched is flagged.
- **Audit packet.** Export one PDF per withdrawal: a cover sheet plus every receipt and EOB behind it.
- **Duplicate check.** Filing a bill that matches one already on file asks first.
- **Eligibility rules.** Expenses before the HSA was established, paid from the HSA directly, or
  claimed as a tax deduction are kept for the record but never counted as available.
- **App lock.** Optional Face ID, Touch ID or passcode.

## The archive

The app's data is a folder of ordinary files, visible in the Files app under **On My iPhone → Shoebox**:

```
ledger.json        every expense and withdrawal; the source of truth
expenses.csv       the same expenses as a spreadsheet, rewritten on every change
withdrawals.csv    the same withdrawals as a spreadsheet
README.txt         explains the folder to whoever opens it in 2050
Documents/2026/    2026-11-14_Corner-Pharmacy_24.84_receipt_a1b2c3.pdf ...
Backups/           one ledger snapshot per day that had a change (60 kept)
Removed/           documents removed from an expense; never deleted outright
```

Safeguards built around it:

- Amounts are whole cents and dates are plain calendar days, so nothing drifts.
- Every save is atomic, and a failed save rolls the on-screen state back.
- Each document's SHA-256 is recorded; **Settings → Check documents** re-verifies every file.
- A ledger written by a newer app version is refused rather than overwritten.
- If the ledger is unreadable, a recovery screen offers the daily snapshots.
- **Settings → Backup folder** mirrors the archive into a folder you choose (iCloud Drive, for
  example). The mirror only ever adds files.

## Project layout

```
App/                      SwiftUI app (iOS 26)
  Model/AppModel.swift    app state; every change goes through one commit path
  Services/               scanning, text recognition, PDF reports
  Views/                  screens
  Design/Theme.swift      colours, type, shared components
Packages/ShoeboxCore/     platform-independent logic, with unit tests
  Models, LedgerMath      data model and reimbursement rules
  ArchiveStore            the folder format, backups, integrity, mirroring
  ReceiptParser           turns recognised text into provider / date / amount
project.yml               XcodeGen definition of the Xcode project
```

## Building

```
brew install xcodegen
xcodegen generate
open Shoebox.xcodeproj
```

Select your iPhone and run. The signing team and bundle ID are set in `project.yml`.

Core logic tests run anywhere Swift does:

```
cd Packages/ShoeboxCore && swift test
```

Launching with `-demo` opens a throwaway sample archive and never touches real data. Add
`-tab 0…3`, `-screen expense|add|withdraw|withdrawal`, `-empty` or `-onboarding` to jump to a screen.
The GitHub Actions workflow uses these to capture screenshots on every push. It also launches the
app with `-demo -selftest`, which builds the PDF exports, runs text recognition on a photographed
receipt, verifies checksums and mirrors the archive inside the simulator, then saves a pass/fail
list with the screenshots.

## Not yet tried on a real iPhone

The simulator has no camera, Face ID or iCloud Drive, so these paths compile but have not been run:
the document scanner, the app lock, choosing a backup folder, "Show in Files", and receiving a file
from another app's share sheet.

## Not included yet

- A share extension for sending photos straight from the Photos app (PDFs and image files already
  work through "Open in Shoebox").
- State-level tracking, such as California's separate treatment of HSA contributions and earnings.
- Links to an HSA provider. Withdrawals are entered by hand.

Shoebox keeps records. It does not give tax advice.
