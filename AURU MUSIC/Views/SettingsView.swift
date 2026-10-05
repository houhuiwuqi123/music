import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.8"
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
                        LegalDocumentView(titleKey: "policy", bodyKey: "privacyBody")
                    }
                    NavigationLink(settings.text("termsOfService")) {
                        LegalDocumentView(titleKey: "termsOfService", bodyKey: "termsBody")
                    }
                    NavigationLink(settings.text("emailFeedback")) {
                        FeedbackView()
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

private struct LegalDocumentView: View {
    let titleKey: String
    let bodyKey: String
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ScrollView {
            Text(settings.text(bodyKey))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(20)
        }
        .background(DarkBackground())
        .navigationTitle(settings.text(titleKey))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FeedbackView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var subject = ""
    @State private var message = ""
    @State private var showsMailError = false

    var body: some View {
        Form {
            Section(settings.text("feedbackSubject")) {
                TextField(settings.text("feedbackSubject"), text: $subject)
            }
            Section(settings.text("feedbackContent")) {
                TextEditor(text: $message)
                    .frame(minHeight: 180)
            }
            Button(action: openMail) {
                Label(settings.text("sendEmail"), systemImage: "envelope.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
        .scrollContentBackground(.hidden)
        .background(DarkBackground())
        .navigationTitle(settings.text("emailFeedback"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if subject.isEmpty { subject = settings.text("feedbackSubject") }
        }
        .alert(settings.text("emailFeedback"), isPresented: $showsMailError) {
            Button(settings.text("ok"), role: .cancel) {}
        } message: {
            Text(settings.text("mailUnavailable"))
        }
    }

    private func openMail() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: message)
        ]
        guard let url = components.url, UIApplication.shared.canOpenURL(url) else {
            showsMailError = true
            return
        }
        UIApplication.shared.open(url)
    }
}
