//
//  FeedbackView.swift
//
//  In-app "Send Feedback" UI. Lets a beta tester file a bug/idea without
//  leaving the app; posts to the self-hosted server via TelemetryReporter.
//
//  Presented as a standalone window via FeedbackWindowController (mirrors
//  AboutWindowController), not as a popover sheet — the popover is only 320pt
//  wide and a sheet overflows it.
//

import SwiftUI
import AppKit

struct FeedbackView: View {
    /// Closes the hosting window. Injected by FeedbackWindowController.
    var onClose: () -> Void = {}
    @ObservedObject private var loc = LocalizationManager.shared

    static let messageMaxLength = 1000

    @State private var category: TelemetryReporter.FeedbackCategory = .bug
    @State private var message: String = ""
    @State private var contactEmail: String = ""
    @State private var isSending = false
    @State private var sendResult: SendResult?

    private enum SendResult { case success, failure }

    private var trimmedMessage: String {
        message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(loc.t("feedback_title"))
                .font(.system(size: 15, weight: .semibold))

            Picker("", selection: $category) {
                ForEach(TelemetryReporter.FeedbackCategory.allCases) { cat in
                    Text(cat.label).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .trailing, spacing: 3) {
                PlaceholderTextEditor(text: $message,
                                      placeholder: placeholder,
                                      maxLength: Self.messageMaxLength)
                    .frame(height: 96)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                Text("\(message.count)/\(Self.messageMaxLength)")
                    .font(.system(size: 9))
                    .foregroundColor(message.count >= Self.messageMaxLength ? .orange : .secondary)
            }

            TextField(loc.t("feedback_email_placeholder"), text: $contactEmail)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )

            Text(loc.t("feedback_disclaimer"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let sendResult {
                Label(sendResult == .success ? loc.t("feedback_sent_success") : loc.t("feedback_sent_failure"),
                      systemImage: sendResult == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(sendResult == .success ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(action: send) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(loc.t("feedback_send"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedMessage.isEmpty || isSending)
            }
        }
        // Extra top padding clears the window's traffic-light buttons, which sit
        // over the content in a fullSizeContentView window.
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(width: 320)
    }

    private var placeholder: String {
        switch category {
        case .bug: return loc.t("feedback_placeholder_bug")
        case .idea: return loc.t("feedback_placeholder_idea")
        case .other: return loc.t("feedback_placeholder_other")
        }
    }

    private func send() {
        isSending = true
        sendResult = nil
        Task {
            let ok = await TelemetryReporter.sendFeedback(
                category: category,
                message: trimmedMessage,
                contactEmail: contactEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            await MainActor.run {
                isSending = false
                sendResult = ok ? .success : .failure
                if ok {
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        onClose()
                    }
                }
            }
        }
    }
}

// MARK: - Placeholder-aware text editor

/// An NSTextView-backed multi-line editor whose placeholder is drawn by the
/// same text view that draws the caret — so the placeholder, caret, and typed
/// text share one coordinate system and always line up (unlike a SwiftUI
/// TextEditor with an overlaid Text placeholder, which drift apart).
struct PlaceholderTextEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var maxLength: Int
    var fontSize: CGFloat = 12

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: fontSize)
        textView.placeholderString = placeholder
        textView.placeholderFont = .systemFont(ofSize: fontSize)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textColor = .labelColor
        // Explicit geometry so the placeholder draw origin can match the text origin exactly.
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PlaceholderTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
        // Redraw when the placeholder changes (e.g. switching Bug/Idea/Other),
        // otherwise the text view keeps painting the previous placeholder.
        if textView.placeholderString != placeholder {
            textView.placeholderString = placeholder
            textView.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: PlaceholderTextEditor
        init(_ parent: PlaceholderTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Hard-cap input length (defense against paste-bombing the field).
            if tv.string.count > parent.maxLength {
                tv.string = String(tv.string.prefix(parent.maxLength))
            }
            parent.text = tv.string
            tv.needsDisplay = true
        }
    }
}

/// NSTextView that renders a placeholder at the exact text origin when empty.
final class PlaceholderTextView: NSTextView {
    var placeholderString: String = ""
    var placeholderFont: NSFont = .systemFont(ofSize: 12)

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        let rect = NSRect(x: origin.x, y: origin.y,
                          width: bounds.width - origin.x - textContainerInset.width,
                          height: bounds.height - origin.y)
        placeholderString.draw(in: rect, withAttributes: [
            .font: placeholderFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }
}

// MARK: - Window

/// Hosts FeedbackView in a standalone window. Mirrors AboutWindowController so
/// the feedback form opens like "About" does, rather than as an in-popover sheet.
final class FeedbackWindowController: NSWindowController {
    static let shared = FeedbackWindowController()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.keepVisibleAcrossAppsAndSpaces()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        self.init(window: window)
    }

    /// Shows the feedback window with a fresh form each time.
    func show() {
        guard let window else { return }

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .menu
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        let hostingView = NSHostingView(
            rootView: FeedbackView(onClose: { [weak self] in self?.window?.close() })
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        visualEffect.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor)
        ])

        window.contentView = visualEffect

        // Size the window to the form's natural height (width is fixed at 320).
        let fitting = hostingView.fittingSize
        window.setContentSize(NSSize(width: 320, height: fitting.height > 0 ? fitting.height : 400))
        window.center()

        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
