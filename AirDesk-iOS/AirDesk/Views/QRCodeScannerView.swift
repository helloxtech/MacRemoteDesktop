import AVFoundation
import SwiftUI

struct QRCodeScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    let onCode: (String) -> Void

    var body: some View {
        NavigationView {
            ZStack {
                QRCodeScannerView(
                    onCode: { code in
                        dismiss()
                        onCode(code)
                    },
                    onError: { message in
                        errorMessage = message
                    }
                )
                .ignoresSafeArea(edges: .bottom)

                scannerFrame

                if let errorMessage {
                    VStack {
                        Spacer()
                        Text(errorMessage)
                            .font(.callout.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(.black.opacity(0.72))
                            .cornerRadius(14)
                            .padding()
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Scan Mac QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var scannerFrame: some View {
        RoundedRectangle(cornerRadius: 18)
            .stroke(Color.white, lineWidth: 3)
            .frame(width: 250, height: 250)
            .shadow(color: .black.opacity(0.35), radius: 12)
    }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

private final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "airdesk.qr.session")
    private let metadataQueue = DispatchQueue(label: "airdesk.qr.metadata")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasCompletedScan = false

    private let onCode: (String) -> Void
    private let onError: (String) -> Void

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkCameraPermission()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.configureSession() : self?.onError("Camera access is required to scan the AirDesk QR code.")
                }
            }
        case .denied, .restricted:
            onError("Allow camera access in Settings to scan the AirDesk QR code.")
        @unknown default:
            onError("Camera access is unavailable on this device.")
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(for: .video) else {
            session.commitConfiguration()
            onError("No camera is available on this device.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                onError("AirDesk could not use the camera input.")
                return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            onError("AirDesk could not open the camera.")
            return
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            onError("AirDesk could not read QR codes from the camera.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: metadataQueue)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
        startSession()
    }

    private func startSession() {
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    private func stopSession() {
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasCompletedScan,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let code = metadataObject.stringValue else {
            return
        }

        hasCompletedScan = true
        stopSession()
        DispatchQueue.main.async { [onCode] in
            onCode(code)
        }
    }
}
