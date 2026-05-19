import SwiftUI
import PhotosUI

struct ChatComposer: View {
    @ObservedObject var vm: ChatViewModel
    @StateObject private var voice = VoiceInputManager()
    @State private var showSourcePicker = false
    @State private var showImagePicker = false
    @State private var imageSource: UIImagePickerController.SourceType = .photoLibrary
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Voice transcript preview
            if voice.isRecording {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                                .animation(.easeInOut(duration: 0.6).repeatForever().delay(Double(i) * 0.2), value: voice.isRecording)
                        }
                    }
                    Text(voice.transcript.isEmpty ? L("speak") : voice.transcript)
                        .font(.system(size: 14))
                        .foregroundColor(voice.transcript.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.red.opacity(0.06))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                // Photo button
                Button {
                    showSourcePicker = true
                } label: {
                    Image(systemName: "photo")
                        .font(.system(size: 19, weight: .ultraLight))
                        .foregroundColor(.secondary)
                        .frame(width: 34, height: 34)
                }
                .confirmationDialog(L("add_receipt_photo"), isPresented: $showSourcePicker) {
                    Button(L("take_photo")) {
                        imageSource = .camera
                        showImagePicker = true
                    }
                    Button(L("choose_gallery")) {
                        imageSource = .photoLibrary
                        showImagePicker = true
                    }
                    Button(L("cancel"), role: .cancel) {}
                }

                // Text input
                TextField(L("chat_placeholder"), text: $vm.inputText, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .focused($isFocused)
                    .onSubmit {
                        guard !vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        Task { await vm.sendMessage() }
                    }

                // Voice / Stop / Send
                if vm.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !voice.isRecording {
                    Button {
                        isFocused = false
                        withAnimation { voice.startRecording() }
                    } label: {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                            .frame(width: 36, height: 36)
                    }
                } else if voice.isRecording {
                    Button {
                        voice.stopRecording()
                        if !voice.transcript.isEmpty { vm.inputText = voice.transcript }
                    } label: {
                        ZStack {
                            Circle().fill(Color.red).frame(width: 34, height: 34)
                            Image(systemName: "stop.fill").font(.system(size: 14)).foregroundColor(.white)
                        }
                    }
                } else {
                    Button {
                        isFocused = false
                        Task { await vm.sendMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(Color.accentColor)
                    }
                    .disabled(vm.isLoading)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.2), value: voice.isRecording)
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
        // Image picker sheet
        .sheet(isPresented: $showImagePicker) {
            ImagePickerView(sourceType: imageSource) { image in
                Task { await vm.sendImage(image) }
            }
        }
    }
}

// MARK: — Image Picker
struct ImagePickerView: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        init(onImage: @escaping (UIImage) -> Void) { self.onImage = onImage }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { onImage(img) }
            picker.dismiss(animated: true)
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
