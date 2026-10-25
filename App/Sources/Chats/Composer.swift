import MeshDesign
import MeshServices
import MeshStore
import SwiftUI

/// Message input: reply banner, text field with byte counter, attachments menu and send button.
struct Composer: View {
    @Binding var draft: String
    let byteLimit: Int
    let placeholder: String
    @Binding var replyTarget: MessageRecord?
    let isSending: Bool
    let errorText: String?
    let onSend: () -> Void
    let onSendLocation: () -> Void
    /// Whether live location is being shared to this conversation.
    var isSharingLiveLocation = false
    var onStartLiveLocation: ((LiveLocationLength) -> Void)?
    var onStopLiveLocation: (() -> Void)?
    /// Direct messages with chat contacts only.
    var onRequestPosition: (() -> Void)?

    @FocusState private var focused: Bool

    private var bytes: Int { draft.utf8.count }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bytes <= byteLimit && !isSending
    }

    var body: some View {
        VStack(spacing: MCSpacing.xs) {
            if let errorText {
                Text(errorText).font(.footnote).foregroundStyle(MCColor.critical).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let replyTarget {
                HStack {
                    Image(systemName: "arrowshape.turn.up.left").foregroundStyle(MCColor.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text("Replying to \(replyTarget.isOutgoing ? "yourself" : replyTarget.senderName ?? "message")")
                            .font(.caption.weight(.semibold))
                        Text(MessageFormat.displayText(MessageFormat.parseReply(replyTarget.text)?.body ?? replyTarget.text))
                            .font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    Button("Cancel reply", systemImage: "xmark.circle.fill") { self.replyTarget = nil }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, MCSpacing.s)
            }
            HStack(alignment: .bottom, spacing: MCSpacing.s) {
                Menu {
                    Button("Send my location", systemImage: "location.fill", action: onSendLocation)
                    if isSharingLiveLocation, let onStopLiveLocation {
                        Button("Stop live location", systemImage: "location.slash", role: .destructive, action: onStopLiveLocation)
                    } else if let onStartLiveLocation {
                        Menu("Start live location", systemImage: "location.circle") {
                            ForEach(LiveLocationLength.allCases, id: \.self) { length in
                                Button(length.title) { onStartLiveLocation(length) }
                            }
                        }
                    }
                    if let onRequestPosition {
                        Button("Request position", systemImage: "location.magnifyingglass", action: onRequestPosition)
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.title3.weight(.medium))
                        .frame(width: MCSize.control, height: MCSize.control)
                }
                .mcFloatingSurface(in: Circle())
                .accessibilityLabel("Attachments")

                HStack(alignment: .bottom) {
                    TextField(placeholder, text: $draft, axis: .vertical)
                        .lineLimit(1...6)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(submit)
                        // A multi-line field inserts a newline on Return instead of submitting: treat a typed
                        // newline at the end as Send (mesh messages are single-paragraph).
                        .onChange(of: draft) { old, new in
                            guard new.hasSuffix("\n"), new.count == old.count + 1 else { return }
                            draft.removeLast()
                            submit()
                        }
                    if bytes > byteLimit * 3 / 4 {
                        Text("\(byteLimit - bytes)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(bytes > byteLimit ? MCColor.critical : .secondary)
                            .accessibilityLabel(bytes > byteLimit
                                ? "\(bytes - byteLimit) bytes over the limit" : "\(byteLimit - bytes) bytes left")
                    }
                    Button(action: onSend) {
                        Image(systemName: isSending ? "hourglass" : "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(canSend ? MCColor.accent : Color.secondary)
                    }
                    .disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel("Send")
                }
                .padding(.horizontal, MCSpacing.m)
                .padding(.vertical, MCSpacing.s)
                .mcFloatingSurface(in: RoundedRectangle(cornerRadius: MCRadius.control, style: .continuous))
            }
        }
        .padding(.horizontal, MCSpacing.m)
        .padding(.vertical, MCSpacing.s)
        // Choosing Reply on a message goes straight to typing the reply.
        .onChange(of: replyTarget?.id) { _, id in
            if id != nil { focused = true }
        }
    }

    /// Sends from the keyboard and keeps the field focused for the next message, as Messages does.
    private func submit() {
        guard canSend else { return }
        onSend()
        Task { focused = true }
    }
}
