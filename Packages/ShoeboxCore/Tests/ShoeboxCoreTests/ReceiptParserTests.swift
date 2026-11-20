import XCTest
@testable import ShoeboxCore

final class ReceiptParserTests: XCTestCase {
    private let today = DayDate(iso: "2026-11-20")!
    private func day(_ iso: String) -> DayDate { DayDate(iso: iso)! }

    func testPharmacyReceipt() {
        let text = """
        CORNER PHARMACY
        1234 Ventura Blvd
        Sherman Oaks, CA 91403
        (818) 555-0142
        11/14/2026 3:42 PM
        RX 4471982 ATORVASTATIN 20MG   15.00
        IBUPROFEN 200MG 100CT           8.99
        SUBTOTAL                       23.99
        TAX                             0.85
        TOTAL                          24.84
        VISA ************4417          24.84
        CHANGE                          0.00
        THANK YOU
        """
        let guess = ReceiptParser.parse(text: text, today: today)
        XCTAssertEqual(guess.provider, "Corner Pharmacy")
        XCTAssertEqual(guess.date, day("2026-11-14"))
        XCTAssertEqual(guess.amountCents, 2484)
        XCTAssertFalse(guess.looksLikeEOB)
    }

    func testClinicStatementPrefersPatientResponsibilityAndServiceDate() {
        let text = """
        Valley Family Medicine
        Statement Date: 10/30/2026
        Patient: Alex Rivera   DOB: 04/12/1988
        Account #: 0098123
        Date of Service: 10/02/2026
        Office visit, established patient     Charges  $285.00
        Insurance adjustment                           -$110.00
        Insurance paid                                 $135.00
        Patient Responsibility                         $40.00
        Payment due by 11/30/2026
        """
        let guess = ReceiptParser.parse(text: text, today: today)
        XCTAssertEqual(guess.provider, "Valley Family Medicine")
        XCTAssertEqual(guess.date, day("2026-10-02"))
        XCTAssertEqual(guess.amountCents, 4000)
        XCTAssertEqual(guess.amountCandidates.first, 4000)
    }

    func testExplanationOfBenefits() {
        let text = """
        BLUE RIVER HEALTH PLAN
        Explanation of Benefits
        THIS IS NOT A BILL
        Member: Sam Rivera    Claim Number: 2026-88127734
        Provider: Canyon Imaging Center
        Service date        Billed      Allowed     Plan paid    You owe
        05/06/2026          $1,240.00   $610.00     $392.00      $218.00
        Deductible applied: $218.00
        """
        let guess = ReceiptParser.parse(text: text, today: today)
        XCTAssertTrue(guess.looksLikeEOB)
        XCTAssertEqual(guess.date, day("2026-05-06"))
        // Four amounts on one line: the last column is what the patient owes.
        XCTAssertEqual(guess.amountCents, 21800)
    }

    func testLabelAndValueOnSeparateLines() {
        let lines = ["Brightside Dental", "Visit date", "March 4, 2026", "Billed", "$900.00", "Amount due", "$165.00"]
        let guess = ReceiptParser.parse(lines: lines, today: today)
        XCTAssertEqual(guess.date, day("2026-03-04"))
        XCTAssertEqual(guess.amountCents, 16500)
        XCTAssertEqual(guess.amountCandidates, [16500, 90000])
    }

    func testNoKeywordsFallsBackToLargestAmount() {
        let guess = ReceiptParser.parse(lines: ["ClearView Optometry", "Frames 189.00", "Lenses 200.00", "389.00"], today: today)
        XCTAssertEqual(guess.amountCents, 38900)
        XCTAssertEqual(guess.amountCandidates, [38900, 20000, 18900])
    }

    func testDateFormats() {
        func first(_ line: String) -> DayDate? { ReceiptParser.dates(in: line, today: today).first }
        XCTAssertEqual(first("2026-03-04"), day("2026-03-04"))
        XCTAssertEqual(first("3/4/2026"), day("2026-03-04"))
        XCTAssertEqual(first("03-04-26"), day("2026-03-04"))
        XCTAssertEqual(first("03.04.2026"), day("2026-03-04"))
        XCTAssertEqual(first("Mar 4, 2026"), day("2026-03-04"))
        XCTAssertEqual(first("March 4th 2026"), day("2026-03-04"))
        XCTAssertEqual(first("Sept. 9, 2025"), day("2025-09-09"))
        XCTAssertEqual(first("4 March 2026"), day("2026-03-04"))
        XCTAssertEqual(first("12/31/99"), day("1999-12-31"))
        XCTAssertNil(first("13/45/2026"))
        XCTAssertNil(first("02/30/2026"))
        XCTAssertNil(first("12/25/2026"), "A future date is not a date of service")
        XCTAssertNil(first("01/01/1975"))
        XCTAssertNil(first("Ref 1234-56-7890"))
        XCTAssertNil(first("Phone 818-555-0142"))
    }

    func testBirthAndDueDatesAreNotChosen() {
        XCTAssertNil(ReceiptParser.date(in: ["DOB: 04/12/1998"], today: today))
        XCTAssertEqual(ReceiptParser.date(in: ["DOB 04/12/1998", "Due 11/01/2026", "Seen 10/15/2026"], today: today), day("2026-10-15"))
        // "dos" must match as a word, not inside "dose".
        XCTAssertEqual(ReceiptParser.dateScore(for: "Dose 2 of 3 given 10/15/2026"), 0)
        XCTAssertEqual(ReceiptParser.dateScore(for: "DOS: 10/15/2026"), 100)
    }

    func testAmountMatching() {
        XCTAssertEqual(ReceiptParser.moneyValues(in: "Total $1,234.56"), [123456])
        XCTAssertEqual(ReceiptParser.moneyValues(in: "$ 45.00"), [4500])
        XCTAssertEqual(ReceiptParser.moneyValues(in: "Qty 2 @ 12.50 = 25.00"), [1250, 2500])
        XCTAssertEqual(ReceiptParser.moneyValues(in: "Phone 818.555.0142"), [])
        XCTAssertEqual(ReceiptParser.moneyValues(in: "Version 10.4.12"), [])
        XCTAssertEqual(ReceiptParser.moneyValues(in: "Weight 72.5 kg"), [])
        XCTAssertLessThan(ReceiptParser.amountScore(for: "SUBTOTAL 23.99"), 0)
        XCTAssertGreaterThan(ReceiptParser.amountScore(for: "TOTAL 24.84"), 0)
    }

    func testZeroAmountsAreIgnored() {
        let guess = ReceiptParser.parse(lines: ["Clinic", "Amount due $0.00", "You paid $35.00"], today: today)
        XCTAssertEqual(guess.amountCents, 3500)
        XCTAssertEqual(guess.amountCandidates, [3500])
    }

    func testProviderHeuristics() {
        XCTAssertEqual(ReceiptParser.provider(in: ["RECEIPT", "11/14/2026", "UCLA HEALTH WEST VALLEY", "Total 5.00"]), "UCLA Health West Valley")
        XCTAssertEqual(ReceiptParser.provider(in: ["CVS PHARMACY #9912"]), "CVS Pharmacy #9912")
        XCTAssertEqual(ReceiptParser.provider(in: ["Sierra Dermatology of the Valley"]), "Sierra Dermatology of the Valley")
        XCTAssertNil(ReceiptParser.provider(in: ["12345 67890", "Total 5.00", "www.example.com"]))
        XCTAssertEqual(ReceiptParser.tidyName("CHILDREN'S HOSPITAL OF THE VALLEY"), "Children's Hospital of the Valley")
    }

    func testEmptyAndNoisyInput() {
        XCTAssertEqual(ReceiptParser.parse(text: "", today: today), .empty)
        XCTAssertTrue(ReceiptParser.parse(text: "   \n\n  ", today: today).isEmpty)
        let noise = ReceiptParser.parse(lines: ["~~~", "|||", "0000 0000"], today: today)
        XCTAssertNil(noise.amountCents)
        XCTAssertNil(noise.date)
        XCTAssertNil(noise.provider)
    }
}

final class LineAssemblerTests: XCTestCase {
    func testFragmentsOnTheSameRowAreJoinedLeftToRight() {
        let fragments = [
            TextFragment(text: "24.84", x: 0.80, y: 0.502, height: 0.02),
            TextFragment(text: "CORNER PHARMACY", x: 0.30, y: 0.05, height: 0.03),
            TextFragment(text: "TOTAL", x: 0.10, y: 0.50, height: 0.02),
            TextFragment(text: "SUBTOTAL", x: 0.10, y: 0.46, height: 0.02),
            TextFragment(text: "23.99", x: 0.80, y: 0.461, height: 0.02),
            TextFragment(text: "   ", x: 0.5, y: 0.7, height: 0.02)
        ]
        let lines = LineAssembler.lines(from: fragments)
        XCTAssertEqual(lines, ["CORNER PHARMACY", "SUBTOTAL  23.99", "TOTAL  24.84"])
        let guess = ReceiptParser.parse(lines: lines, today: DayDate(iso: "2026-11-20")!)
        XCTAssertEqual(guess.amountCents, 2484)
    }

    func testEmptyInput() {
        XCTAssertEqual(LineAssembler.lines(from: []), [])
    }
}
