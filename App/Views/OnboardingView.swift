import SwiftUI
import ShoeboxCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var step = 0
    @State private var name = ""
    @State private var knowsDate = true
    @State private var established = Calendar.current.date(from: DateComponents(year: Calendar.current.component(.year, from: Date()), month: 1, day: 1)) ?? Date()
    @State private var accountLabel = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            Color.screenBackground.ignoresSafeArea()
            if step == 0 {
                welcome
                    .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
            } else {
                setup
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.35), value: step)
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .background(LinearGradient(colors: [.heroBottom, .heroTop], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: Color.heroTop.opacity(0.35), radius: 18, y: 10)
                .accessibilityHidden(true)
            Text("Shoebox")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .padding(.top, 22)
            Text("Pay medical bills yourself today.\nPay yourself back, tax-free, years from now.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
                .padding(.horizontal, 24)
            VStack(alignment: .leading, spacing: 22) {
                feature("doc.viewfinder", "File a receipt in seconds",
                        "Scan it and Shoebox reads the provider, date and amount for you.")
                feature("banknote", "Always know your number",
                        "See exactly how much you can withdraw from your HSA, backed by paperwork.")
                feature("folder.badge.gearshape", "Built to outlast the app",
                        "Your records are plain files you own. Nothing is uploaded anywhere.")
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)
            Spacer(minLength: 24)
            Button("Continue") { step = 1 }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
                .accessibilityIdentifier("onboarding-continue")
        }
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color.brand)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Setup

    private var setup: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your first name", text: $name)
                        .textContentType(.givenName)
                        .focused($nameFocused)
                        .submitLabel(.done)
                } header: {
                    Text("Who is the account holder?")
                } footer: {
                    Text("You can add a spouse and dependents later in Settings.")
                }
                Section {
                    Toggle("I know the date", isOn: $knowsDate.animation())
                    if knowsDate {
                        DatePicker("Established", selection: $established, in: ...Date(), displayedComponents: .date)
                    }
                } header: {
                    Text("When was your HSA established?")
                } footer: {
                    Text("Only expenses on or after this day can be reimbursed. Your HSA provider can tell you the date. You can set it later.")
                }
                Section {
                    TextField("For example, the name of your HSA provider", text: $accountLabel)
                } header: {
                    Text("Account name (optional)")
                } footer: {
                    Text("Shown on exported reports. Don't enter an account number.")
                }
            }
            .navigationTitle("Set up")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") { step = 0 }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Get started") { finish() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(.bar)
                    .accessibilityIdentifier("onboarding-finish")
            }
        }
    }

    private func finish() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateSettings { settings in
            if !settings.people.contains(where: { $0.relationship == .accountHolder }) {
                settings.people.insert(Person(name: trimmed.isEmpty ? "Me" : trimmed, relationship: .accountHolder), at: 0)
            }
            settings.establishedOn = knowsDate ? DayDate(date: established) : nil
            settings.accountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        Haptics.success()
        model.hasOnboarded = true
    }
}
