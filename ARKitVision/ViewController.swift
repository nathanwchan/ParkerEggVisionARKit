/*
See LICENSE folder for this sample’s licensing information.

Abstract:
Main view controller for the ARKitVision sample.
*/

import UIKit
import SpriteKit
import ARKit
import Vision

class ViewController: UIViewController, UIGestureRecognizerDelegate, ARSKViewDelegate, ARSessionDelegate {
    
    @IBOutlet weak var sceneView: ARSKView!
    @IBOutlet weak var iSeeParkerLabel: UILabel!
    
    // The view controller that displays the status and "restart experience" UI.
    private lazy var statusViewController: StatusViewController = {
        return children.lazy.compactMap({ $0 as? StatusViewController }).first!
    }()
    
    // MARK: - View controller lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Configure and present the SpriteKit scene that draws overlay content.
        let overlayScene = SKScene()
        overlayScene.scaleMode = .aspectFill
        sceneView.delegate = self
        sceneView.presentScene(overlayScene)
        sceneView.session.delegate = self
        
        // Hook up status view controller callback.
        statusViewController.restartExperienceHandler = { [unowned self] in
            self.restartSession()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Create a session configuration
        let configuration = ARWorldTrackingConfiguration()
        
        // Run the view's session
        sceneView.session.run(configuration)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Pause the view's session
        sceneView.session.pause()
    }
    
    // MARK: - ARSessionDelegate
    
    // Pass camera frames received from ARKit to Vision (when not already processing one)
    /// - Tag: ConsumeARFrames
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Do not enqueue other buffers for processing while another Vision task is still running.
        // The camera stream has only a finite amount of buffers available; holding too many buffers for analysis would starve the camera.
        guard currentBuffer == nil, case .normal = frame.camera.trackingState else {
            return
        }
        
        // Retain the image buffer for Vision processing.
        self.currentBuffer = frame.capturedImage
        classifyCurrentImage()
    }
    
    // MARK: - Vision classification
    
    // Vision classification request and model
    /// - Tag: ClassificationRequest
    private lazy var classificationRequest: VNCoreMLRequest = {
        do {
            // Instantiate the model from its generated Swift class.
            let model = try VNCoreMLModel(for: ParkerEggImageClassifier2().model)
            let request = VNCoreMLRequest(model: model, completionHandler: { [weak self] request, error in
                self?.processClassifications(for: request, error: error)
            })
            
            // Crop input images to square area at center, matching the way the ML model was trained.
            request.imageCropAndScaleOption = .centerCrop
            
            // Use CPU for Vision processing to ensure that there are adequate GPU resources for rendering.
            request.usesCPUOnly = true
            
            return request
        } catch {
            fatalError("Failed to load Vision ML model: \(error)")
        }
    }()
    
    // The pixel buffer being held for analysis; used to serialize Vision requests.
    private var currentBuffer: CVPixelBuffer?
    
    // Queue for dispatching vision classification requests
    private let visionQueue = DispatchQueue(label: "com.example.apple-samplecode.ARKitVision.serialVisionQueue")
    
    // Run the Vision+ML classifier on the current image buffer.
    /// - Tag: ClassifyCurrentImage
    private func classifyCurrentImage() {
        // Most computer vision tasks are not rotation agnostic so it is important to pass in the orientation of the image with respect to device.
        let orientation = CGImagePropertyOrientation(UIDevice.current.orientation)
        
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: currentBuffer!, orientation: orientation)
        visionQueue.async {
            do {
                // Release the pixel buffer when done, allowing the next buffer to be processed.
                defer { self.currentBuffer = nil }
                try requestHandler.perform([self.classificationRequest])
            } catch {
                print("Error: Vision request failed with error \"\(error)\"")
            }
        }
    }
    
    // Classification results
    private var identifierString = ""
    private var confidence: VNConfidence = 0.0
    private var identifierString2 = ""
    private var confidence2: VNConfidence = 0.0
    
    // Handle completion of the Vision request and choose results to display.
    /// - Tag: ProcessClassifications
    func processClassifications(for request: VNRequest, error: Error?) {
        guard let results = request.results else {
            print("Unable to classify image.\n\(error!.localizedDescription)")
            return
        }
        // The `results` will always be `VNClassificationObservation`s, as specified by the Core ML model in this project.
        var classifications = results as! [VNClassificationObservation]
        classifications.sort(by: { $0.confidence > $1.confidence })
        
        // Show a label for the highest-confidence result (but only above a minimum confidence threshold).
        if let bestResult = classifications.first {
            identifierString = bestResult.identifier
            confidence = bestResult.confidence
            DispatchQueue.main.async {
//                let idString = self.identifierString == "Both" ? "both 🐻 and 🥚" : self.identifierString
                self.iSeeParkerLabel.text = "I 👀 \(self.identifierString)"
                switch self.identifierString {
                case "Parker":
                    self.iSeeParkerLabel.textColor = .red
                case "Egg":
                    self.iSeeParkerLabel.textColor = .blue
                default:
                    self.iSeeParkerLabel.textColor = .green
                }
                
                if self.identifierString == "Nothing" {
                    self.iSeeParkerLabel.isHidden = true
                } else {
                    self.iSeeParkerLabel.isHidden = self.confidence < 0.5
                }
            }
//        if let parkerResult = classifications.filter({ $0.identifier == "Parker" }).first {
//            identifierString = parkerResult.identifier
//            confidence = parkerResult.confidence
//            DispatchQueue.main.async {
//                self.iSeeParkerLabel.isHidden = self.confidence < 0.5
//            }
        } else {
            identifierString = ""
            confidence = 0
        }
        
        if classifications.count >= 2 {
            identifierString2 = classifications[1].identifier
            confidence2 = classifications[1].confidence
        }
    
        DispatchQueue.main.async { [weak self] in
            self?.displayClassifierResults()
        }
    }
    
    // Show the classification results in the UI.
    private func displayClassifierResults() {
        guard !self.identifierString.isEmpty else {
            return // No object was classified.
        }
        let message = String(format: "\(self.identifierString) with %.2f%% confidence \n\(self.identifierString2) with %.2f", self.confidence * 100, self.confidence2 * 100) + "% confidence"
        statusViewController.showMessage(message)
    }
    
    // MARK: - Tap gesture handler & ARSKViewDelegate
    
    // Labels for classified objects by ARAnchor UUID
    private var anchorLabels = [UUID: String]()
    
    // When the user taps, add an anchor associated with the current classification result.
    /// - Tag: PlaceLabelAtLocation
    @IBAction func placeLabelAtLocation(sender: UITapGestureRecognizer) {
        let hitLocationInView = sender.location(in: sceneView)
        let hitTestResults = sceneView.hitTest(hitLocationInView, types: [.featurePoint, .estimatedHorizontalPlane])
        if let result = hitTestResults.first {
            
            // Add a new anchor at the tap location.
            let anchor = ARAnchor(transform: result.worldTransform)
            sceneView.session.add(anchor: anchor)
            
            // Track anchor ID to associate text with the anchor after ARKit creates a corresponding SKNode.
            anchorLabels[anchor.identifier] = identifierString
        }
    }
    
    // When an anchor is added, provide a SpriteKit node for it and set its text to the classification label.
    /// - Tag: UpdateARContent
    func view(_ view: ARSKView, didAdd node: SKNode, for anchor: ARAnchor) {
        guard let labelText = anchorLabels[anchor.identifier] else {
            fatalError("missing expected associated label for anchor")
        }
        let label = TemplateLabelNode(text: labelText)
        node.addChild(label)
    }
    
    // MARK: - AR Session Handling
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        statusViewController.showTrackingQualityInfo(for: camera.trackingState, autoHide: true)
        
        switch camera.trackingState {
        case .notAvailable, .limited:
            statusViewController.escalateFeedback(for: camera.trackingState, inSeconds: 3.0)
        case .normal:
            statusViewController.cancelScheduledMessage(for: .trackingStateEscalation)
            // Unhide content after successful relocalization.
            setOverlaysHidden(false)
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        guard error is ARError else { return }
        
        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]
        
        // Filter out optional error messages.
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")
        DispatchQueue.main.async {
            self.displayErrorMessage(title: "The AR session failed.", message: errorMessage)
        }
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        setOverlaysHidden(true)
    }
    
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        /*
         Allow the session to attempt to resume after an interruption.
         This process may not succeed, so the app must be prepared
         to reset the session if the relocalizing status continues
         for a long time -- see `escalateFeedback` in `StatusViewController`.
         */
        return true
    }

    private func setOverlaysHidden(_ shouldHide: Bool) {
        sceneView.scene!.children.forEach { node in
            if shouldHide {
                // Hide overlay content immediately during relocalization.
                node.alpha = 0
            } else {
                // Fade overlay content in after relocalization succeeds.
                node.run(.fadeIn(withDuration: 0.5))
            }
        }
    }

    private func restartSession() {
        statusViewController.cancelAllScheduledMessages()
        statusViewController.showMessage("RESTARTING SESSION")

        anchorLabels = [UUID: String]()
        
        let configuration = ARWorldTrackingConfiguration()
        sceneView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
    
    // MARK: - Error handling
    
    private func displayErrorMessage(title: String, message: String) {
        // Present an alert informing about the error that has occurred.
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
            alertController.dismiss(animated: true, completion: nil)
            self.restartSession()
        }
        alertController.addAction(restartAction)
        present(alertController, animated: true, completion: nil)
    }
}
