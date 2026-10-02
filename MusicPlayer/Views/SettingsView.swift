import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(settings.text("language")) {
                    Picker(settings.text("language"), selection: $settings.language) {
                        ForEach(AppSettings.Language.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section(settings.text("notifications")) {
                    Toggle(settings.text("notifications"), isOn: $settings.notificationsEnabled)
                }

                Section(settings.text("about")) {
                    LabeledContent(settings.text("version"), value: version)
                    NavigationLink(settings.text("policy")) {
                        PolicyView()
                    }
                    Link(destination: URL(string: "mailto:support@example.com")!) {
                        Label(settings.text("support"), systemImage: "envelope")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DarkBackground())
            .navigationTitle(settings.text("settings"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(settings.text("done")) { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct PolicyView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            Text(settings.text("privacyBody"))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(20)
        }
        .background(DarkBackground())
        .navigationTitle(settings.text("policy"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
