import MessageUI
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

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
        .onAppear { settings.refreshNotificationAuthorization() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { settings.refreshNotificationAuthorization() }
        }
        .alert(settings.text("notifications"), isPresented: $settings.showsNotificationSettingsPrompt) {
            Button(settings.text("cancel"), role: .cancel) {}
            Button(settings.text("openSettings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
        } message: {
            Text(settings.text("notificationDenied"))
        }
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
    @State private var showsMailComposer = false

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
        .sheet(isPresented: $showsMailComposer) {
            MailComposeView(
                isPresented: $showsMailComposer,
                recipient: "jenyhssy@gmail.com",
                subject: subject,
                message: message
            )
            .ignoresSafeArea()
        }
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
        guard MFMailComposeViewController.canSendMail() else {
            showsMailError = true
            return
        }
        showsMailComposer = true
    }
}

private struct MailComposeView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let recipient: String
    let subject: String
    let message: String

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients([recipient])
        controller.setSubject(subject)
        controller.setMessageBody(message, isHTML: false)
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        @Binding private var isPresented: Bool

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true)
            isPresented = false
        }
    }
}
