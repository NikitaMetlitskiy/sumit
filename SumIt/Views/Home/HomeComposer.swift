import SwiftUI
import PhotosUI

/// New composer for the Figma redesign:
/// • single white pill with a "type any expense..." TextField
/// • leading audio-waveform icon → starts voice recognition
/// • trailing "Scan" button → opens camera
/// • trailing download/inbox icon → photo library
/// Send button replaces the rightmost icon when the user has typed something.
struct HomeComposer: View {
    @ObservedObject var vm: ChatViewModel
    @StateObject private var voice = VoiceInputManager()
    @State private var showImagePicker = false
    @State private var imageSource: UIImagePickerController.SourceType = .photoLibrary
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            // Voice transcript preview, slides in while recording
            if voice.isRecording {
                voiceBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                composerPill
                scanButton
                galleryButton
            }
            .padding(.horizontal, DS.Space.l)

            Text(L("home_composer_footer"))
                .font(.caption2)
                .foregroundColor(DS.Color.textMuted)
                .padding(.top, 2)
        }
        .animation(.easeInOut(duration: 0.18), value: voice.isRecording)
        .alert(L("no_mic_access"), isPresented: $voice.permissionDenied) {
            Button(L("open_settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button(L("cancel"), role: .cancel) {}
        } message: {
            Text(L("allow_mic_settings"))
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView(sourceType: imageSource) { image in
                Task { await vm.sendImage(image) }
            }
        }
    }

    // MARK: — Pill

    private var composerPill: some View {
        HStack(spacing: 10) {
            // Mic/waveform icon
            Button {
                if voice.isRecording {
                    voice.stopRecording()
                    if !voice.transcript.isEmpty { vm.inputText = voice.transcript }
                } else {
                    isFocused = false
                    withAnimation { voice.startRecording() }
                }
            } label: {
                Image(systemName: voice.isRecording ? "stop.circle.fill" : "waveform")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundColor(voice.isRecording ? .red : DS.Color.warmMid)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)

            TextField(L("home_composer_placeholder"), text: $vm.inputText, axis: .vertical)
                .lineLimit(1...4)
                .focused($isFocused)
                .onSubmit(send)
                .submitLabel(.send)

            // Send button appears when text is present
            if !vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button(action: send) {
                    ZStack {
                        Circle().fill(Color.black).frame(width: 32, height: 32)
                        Image(systemName: "arrow.up").font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(vm.isLoading)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: DS.Size.composerHeight)
        .background(
            Capsule(style: .continuous).fill(DS.Color.bg)
        )
        .overlay(
            Capsule(style: .continuous).stroke(DS.Color.strokeSoft, lineWidth: 0.5)
        )
        .dsComposerShadow()
        .animation(.easeInOut(duration: 0.15), value: vm.inputText.isEmpty)
    }

    // MARK: — Scan & gallery side buttons

    private var scanButton: some View {
        Button {
            imageSource = .camera
            showImagePicker = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 14, weight: .regular))
                Text(L("scan")).font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .frame(minHeight: DS.Size.composerHeight)
            .background(
                Capsule(style: .continuous).fill(DS.Color.bg)
            )
            .overlay(
                Capsule(style: .continuous).stroke(DS.Color.strokeSoft, lineWidth: 0.5)
            )
            .dsComposerShadow()
        }
        .buttonStyle(.plain)
    }

    private var galleryButton: some View {
        Button {
            imageSource = .photoLibrary
            showImagePicker = true
        } label: {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 16))
                .foregroundColor(.primary)
                .frame(width: 36, height: DS.Size.composerHeight)
        }
        .buttonStyle(.plain)
    }

    private var voiceBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                        .animation(.easeInOut(duration: 0.6)
                            .repeatForever()
                            .delay(Double(i) * 0.2), value: voice.isRecording)
                }
            }
            Text(voice.transcript.isEmpty ? L("speak") : voice.transcript)
                .font(.system(size: 14))
                .foregroundColor(voice.transcript.isEmpty ? .secondary : .primary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.06))
    }

    private func send() {
        let trimmed = vm.inputText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isFocused = false
        Task { await vm.sendMessage() }
    }
}
