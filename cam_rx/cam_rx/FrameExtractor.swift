//
//  FrameExtractor.swift
//  cam_rx
//
//
//

import AVFoundation
import UIKit
import Accelerate
import Numerics

extension Real {
  // The real and imaginary parts of e^{-2πik/n}
  static func dftWeight(k: Int, n: Int) -> (r: Self, i: Self) {
    precondition(0 <= k && k < n, "k is out of range")
    guard let N = Self(exactly: n) else {
      preconditionFailure("n cannot be represented exactly.")
    }
    let theta = -2 * .pi * (Self(k) / N)
    return (r: .cos(theta), i: .sin(theta))
  }
}

extension Complex {
  // e^{-2πik/n}
  static func dftWeight(k: Int, n: Int) -> Complex<Double> {
    precondition(0 <= k , "k is out of range") // && k < n
    guard let N = Double(exactly: n) else {
      preconditionFailure("n cannot be represented exactly.")
    }
    return Complex<Double>(length: 1, phase: -2 * .pi * (Double(k) / N))
  }
}

protocol FrameExtractorDelegate: AnyObject {
    func captured(image: UIImage)
}

class FrameExtractor:NSObject, AVCaptureVideoDataOutputSampleBufferDelegate{
//    var prevImg: UIImage?
//    var prevImgVals: [Double]?
//    var currentImg: UIImage?
//    var currentImgVals: [Double]?
//    var frameWindow:[UIImage]?
    var BitErrorRate: Double = 0.0 // 1 - (total number of bits received correctly)/(total number of transmitted bits)
    var DataRate: Double = 0.0 // total number of bits received correctly per second
    var center:[CGFloat] = [10,10]
    var noStartSig = true
    var region0Samps:[CGFloat] = []
    var region1Samps:[CGFloat] = []
    var region2Samps:[CGFloat] = []
    var region3Samps:[CGFloat] = []
    var candidateBits0:[Int] = []
    var candidateBits1:[Int] = []
    var candidateBits2:[Int] = []
    var candidateBits3:[Int] = []
    var message:String = ""
    var recLocals = [0,0]
    var gSampLocals:[[CGFloat]]?
    var comp0_url:URL?
    var comp0_fileHandle:FileHandle?
    var comp1_url:URL?
    var comp1_fileHandle:FileHandle?
    var comp2_url:URL?
    var comp2_fileHandle:FileHandle?
    var comp3_url:URL?
    var comp3_fileHandle:FileHandle?
    

    weak var delegate: FrameExtractorDelegate?

    // AVCaptureSession. The session coordinates the flow of data from the input to the output.
    private let captureSession = AVCaptureSession()

    // Some of the things we are going to do with the session must take place asynchronously. Because we don’t want to block the main thread, we need to create a serial queue that will handle the work related to the session
    // suspend or resume it when need be
    private let sessionQueue = DispatchQueue(label: "session queue")

    // Permission to film?
    private var permissionGranted = false

    private let position = AVCaptureDevice.Position.back
    private let quality = AVCaptureSession.Preset.medium
    private let frameRate = 120
    private let context = CIContext()

    override init() {
        super.init()
        checkPermissions()
//        do {
//            // get timestamp in epoch time
//            let ts = NSDate().timeIntervalSince1970
//            let file0 = "comp0_file_\(ts).txt"
//            let file1 = "comp1_file_\(ts).txt"
//            let file2 = "comp2_file_\(ts).txt"
//            let file3 = "comp3_file_\(ts).txt"
//            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
//                comp0_url = dir.appendingPathComponent(file0)
//            }
//            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
//                comp1_url = dir.appendingPathComponent(file1)
//            }
//            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
//                comp2_url = dir.appendingPathComponent(file2)
//            }
//            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
//                comp3_url = dir.appendingPathComponent(file3)
//            }
//
//            // write first line of file
//            try "ts,0,10,20,30,40,50\n".write(to: comp0_url!, atomically: true, encoding: String.Encoding.utf8)
//
//            comp0_fileHandle = try FileHandle(forWritingTo: comp0_url!)
//            comp0_fileHandle!.seekToEndOfFile()
//
//            // write first line of file
//            try "ts,0,10,20,30,40,50\n".write(to: comp1_url!, atomically: true, encoding: String.Encoding.utf8)
//
//            comp1_fileHandle = try FileHandle(forWritingTo: comp1_url!)
//            comp1_fileHandle!.seekToEndOfFile()
//
//            // write first line of file
//            try "ts,0,10,20,30,40,50\n".write(to: comp2_url!, atomically: true, encoding: String.Encoding.utf8)
//
//            comp2_fileHandle = try FileHandle(forWritingTo: comp2_url!)
//            comp2_fileHandle!.seekToEndOfFile()
//
//            // write first line of file
//            try "ts,0,10,20,30,40,50\n".write(to: comp3_url!, atomically: true, encoding: String.Encoding.utf8)
//
//            comp3_fileHandle = try FileHandle(forWritingTo: comp3_url!)
//            comp3_fileHandle!.seekToEndOfFile()
//        } catch {
//            print("Error writing to file \(error)")
//        }

        //Add the async configuration on the session queue
        sessionQueue.async { [unowned self] in
            self.configureSession()
            // Two last things before running the project, first we need to start the capture session and don’t forget that the capture session must be started on the dedicated serial queue we created before, as starting the session is a blocking call and we don’t want to block the UI.
            // Remember that we have two queues in play here, one is the session queue, the other one is the queue each frame is sent to. They are different.
            self.captureSession.startRunning()
        }

    }
    private func checkPermissions() {
        // In order to access the camera, the app is required to ask permission from the user. Inside AVFoundation, we can find a class named AVCaptureDevice that holds the properties pertaining to the underlying hardware. This class also remembers if the user previously authorized the use of the capture device through the authorizationStatus() function. This function returns a constant of an enum named AVAuthorizationStatus which can hold several values.
        switch AVCaptureDevice.authorizationStatus(for: AVMediaType.video) {
        case .authorized:
            // the user explicitly grant permission for media capture
            permissionGranted = true

        case .notDetermined:
            // the user has not yet granted or denied permission
            requestPermission()
        default:
            // the user has denied permission
            permissionGranted = false

        }
    }

    private func requestPermission() {
        sessionQueue.suspend()
        AVCaptureDevice.requestAccess(for: AVMediaType.video) {[unowned self] granted in self.permissionGranted = granted
            self.sessionQueue.resume()

        }// method named requestAccess that prompts the user for permission and takes as an argument a completion handler that is called once the user chose to grant or deny permission.
        // Here, we need to watch out for retain cycles as we are referring to self in the completion handler: declare self as unowned inside the block. In this code particularly, there’s no actual need to add unowned self because even though the closure retains self, self doesn’t retain the closure anywhere and once we get out of the closure, it would release it’s retain on self. But because we might in the future add things and retain the closure, it can be a good thing not to forget.
        // We might also wonder why unowned and not weak? It is always recommended to use weak when it is not implicit that self outlives the closure. Here, it seems like we can be pretty sure that the closure will not outlive self, so we don’t need to declare it weak (and drag along a self that would now be optional). Feel free to read some articles about weak and unowned on the web, there are some quality explanations out there.
        // If ever we end up in the .notDetermined case, because the call to requestAccess is asynchronous (on an arbitrary dispatch    queue), we need to suspend the session queue and resume it once we get a result from the user.

    }

    private func configureSession() {
        guard permissionGranted else { return }
        captureSession.sessionPreset = quality
        guard let captureDevice = selectCaptureDevice() else { return }
        //set fram rate
//        configureCameraForHighestFrameRate(device: captureDevice)
        configureCameraForFrameRate(device: captureDevice, frameRate: 120, bestFormat: 31)

        // AVCaptureDeviceInput. This is a class that manipulates in a concrete way the data captured by the camera. The thing to watch out for is that creating an AVCaptureDeviceInput with an AVCaptureDevice can fail if the device can’t be opened: it might no longer be available, or it might already be in use for example. Because it can fail, we wrap it in a guard and a try?. Feel free to handle the errors as you wish.
        guard let captureDeviceInput = try? AVCaptureDeviceInput(device: captureDevice) else { return }
        // Check if the capture device input can be added to the session, and add it
        guard captureSession.canAddInput(captureDeviceInput) else { return }
        captureSession.addInput(captureDeviceInput)

        // AVCaptureVideoDataOutput is the class we’re going to use: it processes uncompressed frames from the video being captured
        // AVCaptureVideoDataOutput works is by having a delegate object it can send each frame to. Our FrameExtractor class can perfectly be this delegate and receive those frames.
        let videoOutput = AVCaptureVideoDataOutput()

        // specify that the delegate of the video output is FrameExtractor itself.
        //This protocol has two optional methods, one being called every time a frame is available, the other one being called every time a frame is discarded. When setting the delegate, we need to specify a serial queue that will handle the capture of the frames. The two previous methods are called on this serial queue, and every frame processing must be done on this queue.
        // Sometimes, frame processing can require a lot of computing power and the next frame can be captured while the current frame has not been completely processed yet. If this happens, the next captured frame has to be dropped!
        // If we were to send every frame available to another queue and process them all, we could end up in a situation where frames pile on and the pile always increases. The frames come faster than we can treat them and we would have to handle ourselves the memory management that this would trigger
        videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sample buffer"))

        // adding our video output to the session
        guard captureSession.canAddOutput(videoOutput) else { return }
        captureSession.addOutput(videoOutput)

        guard let connection = videoOutput.connection(with: AVFoundation.AVMediaType.video) else { return }
        guard connection.isVideoOrientationSupported else { return }
        guard connection.isVideoMirroringSupported else { return }
        connection.videoOrientation = .portrait
    }
    
    private func selectCaptureDevice() -> AVCaptureDevice? {
        if let device = AVCaptureDevice.default(.builtInTelephotoCamera, for: AVMediaType.video, position: .back) {
            return device
        }else if let device = AVCaptureDevice.default(.builtInDualCamera, for: AVMediaType.video, position: .back) {
            return device
        }else if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: .back) {
            return device
        } else {
            fatalError("Missing expected back camera device.")
        }
    }

    private func imageFromSampleBuffer(sampleBuffer: CMSampleBuffer) -> UIImage? {
        // Transform the sample buffer to a CVImageBuffer
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        // Create a CIImage from the image buffer
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        // Create a CIContext and create a CGImage from this context
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        // We can finally create and return the underlying UIImage from the CGImage.
         
        // do processing here
        
        var imgDisp = UIImage(cgImage: cgImage)
        
//        noRead(image: uiImage)
        
        let localMessage = read(image: imgDisp)
        imgDisp = drawRectangleOnImage(image: imgDisp)
        if (localMessage != nil) {
            self.message = localMessage!
        }
        imgDisp = addTextToImage(text: message as NSString, inImage: imgDisp, atPoint: CGPoint(x: 0, y: 0))
        
        
        // TODO: Buffer Frames into a frame window (six frames)
        // TODO: Take frames from Frame window and compare to last frame to get an array of change values for each grid
            // TODO: defin the center of the frame
            // TODO: define the location of the sampled values to compare
        // TODO: Pass through BFSK demodulatr (FFT) to project translucensy changes into frequency domain
        // TODO: Filter values belos 15Hz
        // TODO: ID components with higher power
        // TODD: Map Highest power component to corresponding bit
        // TODO: Output bit into candidate pool
        // TODO: With (six candidates) bit it the most used bit
        // TODO: Overlay image with marked points
        // TODO: After reciving n bits then doecode bits to word
        // TODO: overlay image with text
        //
        return imgDisp
    }

    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // create a function that takes as an argument a sample buffer and returns, if all goes well, a UIImage
//        print("Got a frame!")
        guard let uiImage = imageFromSampleBuffer(sampleBuffer: sampleBuffer) else { return }
        DispatchQueue.main.async { [unowned self] in
            self.delegate?.captured(image: uiImage)
        }
    }
    
    func startCapture() {
        self.captureSession.startRunning()
    }
    func stopCapture() {
        self.captureSession.stopRunning()
    }
    func suspendSessioQueue() {
        self.captureSession.stopRunning()
    }
    func resumeSessioQueue() {
        self.captureSession.stopRunning()
    }
//// MARK: STUFF FOR IMAGE PROCESSING
//    func noRead(image:UIImage) -> -> String?{
//        // TODO: Detect a Stop
//        if noStartSig {
//            // TODO: Detect a Start
//            if region0Samps.count < 6 {
//                fillSampleBuffer(img: image)
//                print(region0Samps)
//            }
//            else {
//                if candidateBits0.count < 6 {
//                    fillCandidateBuffer()
//                }
//                else {
//                    let endodedMessage = [mode(array: candidateBits0), mode(array: candidateBits1), mode(array: candidateBits2), mode(array: candidateBits3)] // [1,1,1,1]
//                    let decodedMessage = decodeMessage(bits: endodedMessage)
//                    candidateBits0.removeAll()
//                    candidateBits1.removeAll()
//                    candidateBits2.removeAll()
//                    candidateBits3.removeAll()
//                    return decodedMessage
//                    if endodedMessage == [1,1,1,1] {
//                        noStartSig = false
//                    }
//                }
//            }
//        }
//    }

    func read(image:UIImage) -> String? {
        // create the data file we want to write to
        // initialize file with header line
        if self.region0Samps.count < 5 {
            fillSampleBuffer(img: image)
//            print(self.region0Samps)
        } else {
            fillSampleBuffer(img: image)
//            print(region0Samps)
            if self.candidateBits0.count < 5 {
                fillCandidateBuffer()
//                print(self.candidateBits0)
            } else {
                fillCandidateBuffer()
//                print(self.candidateBits0)
//                print(self.candidateBits1)
//                print(self.candidateBits2)
//                print(self.candidateBits3)
                let b0 = mode(array: self.candidateBits0)
                let b1 = mode(array: self.candidateBits1)
                let b2 = mode(array: self.candidateBits2)
                let b3 = mode(array: self.candidateBits3)
                let endodedMessage = [b0, b1, b2, b3] // [1,1,1,1]
                print("endodedMessage: \(endodedMessage)")
                if noStartSig{
                    if endodedMessage == [1,1,1,1] {
                        self.noStartSig = false
                    }
                    self.candidateBits0.removeAll()
                    self.candidateBits1.removeAll()
                    self.candidateBits2.removeAll()
                    self.candidateBits3.removeAll()
//                    let decodedMessage = decodeMessage(bits: endodedMessage)
//                    return decodedMessage
                } else {
                    self.candidateBits0.removeAll()
                    self.candidateBits1.removeAll()
                    self.candidateBits2.removeAll()
                    self.candidateBits3.removeAll()
                    let decodedMessage = decodeMessage(bits:endodedMessage)
                    return decodedMessage
                }
                
            }
        }
        return nil
    }

    func fillSampleBuffer (img: UIImage) {
        center =  findCenter(img: img)
        let sampLoc = findSampleLocations(x: center[0], y: center[1], move: 70)
        let samples = getImgSamples(img: img, locals: sampLoc)
        self.region0Samps.append(samples[0])
        self.region1Samps.append(samples[1])
        self.region2Samps.append(samples[2])
        self.region3Samps.append(samples[3])
    }

    func fillCandidateBuffer() {
    //        frameExtractor.suspendSessioQueue()
        let mags0 = BFSK(regionDiffs: self.region0Samps)
        let mags1 = BFSK(regionDiffs: self.region1Samps)
        let mags2 = BFSK(regionDiffs: self.region2Samps)
        let mags3 = BFSK(regionDiffs: self.region3Samps)
        let mags0Filered = filter(comps: mags0)
        let mags1Filered = filter(comps: mags1)
        let mags2Filered = filter(comps: mags2)
        let mags3Filered = filter(comps: mags3)
//        print("Comps0: \(mags0Filered)")
//        print("Comps1: \(mags1Filered)")
//        print("Comps2: \(mags2Filered)")
//        print("Comps3: \(mags3Filered)")
//        print()
        
//        var timestamp = NSDate().timeIntervalSince1970
//        var text = "\(timestamp), \(mags0Filered[0]), \(mags0Filered[1]), \(mags0Filered[2]), \(mags0Filered[3]), \(mags0Filered[4]), \(mags0Filered[5])\n"
//        self.comp0_fileHandle!.write(text.data(using: .utf8)!)
//
////        timestamp = NSDate().timeIntervalSince1970
//        text = "\(timestamp), \(mags1Filered[0]), \(mags1Filered[1]), \(mags1Filered[2]), \(mags1Filered[3]), \(mags1Filered[4]), \(mags1Filered[5])\n"
//        self.comp1_fileHandle!.write(text.data(using: .utf8)!)
//
////        timestamp = NSDate().timeIntervalSince1970
//        text = "\(timestamp), \(mags2Filered[0]), \(mags2Filered[1]), \(mags2Filered[2]), \(mags2Filered[3]), \(mags2Filered[4]), \(mags2Filered[5])\n"
//        self.comp2_fileHandle!.write(text.data(using: .utf8)!)
//
////        timestamp = NSDate().timeIntervalSince1970
//        text = "\(timestamp), \(mags3Filered[0]), \(mags3Filered[1]), \(mags3Filered[2]), \(mags3Filered[3]), \(mags3Filered[4]), \(mags3Filered[5])\n"
//        self.comp3_fileHandle!.write(text.data(using: .utf8)!)
        
        self.candidateBits0.append(id_Map_Comp(filteredComps: mags0Filered))
        self.candidateBits1.append(id_Map_Comp(filteredComps: mags1Filered))
        self.candidateBits2.append(id_Map_Comp(filteredComps: mags2Filered))
        self.candidateBits3.append(id_Map_Comp(filteredComps: mags3Filered))
        self.region0Samps.removeFirst()
        self.region1Samps.removeFirst()
        self.region2Samps.removeFirst()
        self.region3Samps.removeFirst()
    //        frameExtractor.resumeSessioQueue()
    }

    func findCenter(img:UIImage) -> [CGFloat]{
        // take image, find center, return center coordinates
        let heightInPoints = img.size.height
        let heightInPixels = heightInPoints * img.scale
        let widthInPoints = img.size.width
        let widthInPixels = widthInPoints * img.scale
    //        let centerWidthInPoints = round(widthInPoints/2)
        let centerWidthInPixels = round(widthInPixels / 2)
    //        let centerHeightInPoints = round(heightInPoints/2)
        let centerHeightInPixels = round(heightInPixels / 2)
        
        if (centerWidthInPixels != self.center[0] || centerHeightInPixels != self.center[1]) {
//            print("center updated")
            self.center = [centerWidthInPixels, centerHeightInPixels]
        }
        return[centerWidthInPixels, centerHeightInPixels]
    }

    func findSampleLocations(x: CGFloat, y: CGFloat, move: CGFloat) -> [[CGFloat]]{
        // take image center
        // calculate the locations wher to get the sample from
        // base on the center
        // return sample location coordinates [x0,y0,x1,y1,..,xn,yn]
        if gSampLocals != [[x + move, y + move], [x - move, y + move], [x - move, y - move], [x + move, y - move]] {
//            print("gSampLocals updated")
            self.gSampLocals = [[x + move, y + move], [x - move, y + move], [x - move, y - move], [x + move, y - move]]
        }
        return [[x + move, y + move], [x - move, y + move], [x - move, y - move], [x + move, y - move]] // make 2d
    }

    func getImgSamples(img: UIImage, locals: [[CGFloat]]) -> [CGFloat] {
        // take an image get its gray scale
        // sample image at sample location coordinates
        // return image instensity values
        var col0Hue:CGFloat = 0
        var col0Saturation:CGFloat = 0
        var col0Brightness:CGFloat = 0
        var col0Alph:CGFloat = 0
        img.getLightnes(x:Int(locals[0][0]), y:Int(locals[0][1]))?.getHue(&col0Hue, saturation: &col0Saturation, brightness: &col0Brightness, alpha: &col0Alph)

        var col1Hue:CGFloat = 0
        var col1Saturation:CGFloat = 0
        var col1Brightness:CGFloat = 0
        var col1Alph:CGFloat = 0
        img.getLightnes(x:Int(locals[1][0]), y:Int(locals[1][1]))?.getHue(&col1Hue, saturation: &col1Saturation, brightness: &col1Brightness, alpha: &col1Alph)

        var col2Hue:CGFloat = 0
        var col2Saturation:CGFloat = 0
        var col2Brightness:CGFloat = 0
        var col2Alph:CGFloat = 0
        img.getLightnes(x:Int(locals[2][0]), y:Int(locals[2][0]))?.getHue(&col2Hue, saturation: &col2Saturation, brightness: &col2Brightness, alpha: &col2Alph)

        var col3Hue:CGFloat = 0
        var col3Saturation:CGFloat = 0
        var col3Brightness:CGFloat = 0
        var col3Alph:CGFloat = 0
        img.getLightnes(x:Int(locals[3][0]), y:Int(locals[1][0]))?.getHue(&col3Hue, saturation: &col3Saturation, brightness: &col3Brightness, alpha: &col3Alph)
        return [col0Brightness, col1Brightness, col2Brightness, col3Brightness]
    }

    func BFSK (regionDiffs:[CGFloat])  -> [Double] {
        // takes in an array of deltas for a region
        // return frequency components
        // with a resolution of 1hz we need n = 60 becasue our Fs (frequency sampling rate) = 60
        //convert CGFloat to Double
        let doubleArray = regionDiffs.map {
            Double($0)
        }
//        print(NSLog("Address of doubleArray =  %p",doubleArray))
        let mags = myfft(sig: doubleArray /*,n: 120*/)
//        print(NSLog("Address of mags =  %p",mags))
        return mags
    }

    func filter(comps: [Double]) -> [Double] {
        // remove bucket that corresponding to 15Hz and lower
        // bucket resolution is 1
        var filteredComps = comps
        for _ in 0...1 {
            filteredComps.removeFirst()
            filteredComps.removeLast()
        }
        return filteredComps
    }

    func id_Map_Comp(filteredComps: [Double]) -> Int{
        // take in filtered frequancy components
        // identify high power component
        // map high power components to bit values
        // return bit
        var bit:Int?
        let thresholdData = 0.05
        let threshold0 = 0.3
        if filteredComps[0] > thresholdData || filteredComps[1] > thresholdData {
            if filteredComps[0] > threshold0 || filteredComps[0] > filteredComps[1]-0.15 {
                bit = 0
            } else {
                bit = 1
            }
        } else {
            bit = 2
        }
        return bit!
    }

    func setUpForNextFrame() {

    }

    //    func getfinalbit(bits: [Int]) -> Int {
    //        let modeBit = bits.mode()
    //        return modeBit
    //    }

    func decodeMessage(bits: [Int]) -> String {
        // translate n decoded bit to message
        // return the message
        var message:String = "Reading Message..."

//        if bits == [0, 0, 0, 0] {
//            message = "KOD by J. Cole"
//        } else if bits == [0, 0, 0, 1] {
//            message = "KOD"
//        } else if bits == [0, 0, 1, 0] {
//            message = "1.Photograph"
//        } else if bits == [0, 0, 1, 1] {
//            message = "2.The Cut Off"
//        } else if bits == [0, 1, 0, 0] {
//            message = "3.ATM"
//        } else if bits == [0, 1, 0, 1] {
//            message = "4.Motiv8"
//        } else if bits == [0, 1, 1, 0] {
//            message = "5.Kevin's Heart"
//        } else if bits == [0, 1, 1, 1] {
//            message = "6.BRACKETS"
//        } else if bits == [1, 0, 0, 0] {
//            message = "7.Once an Addict (Interlude)"
//        } else if bits == [1, 0, 0, 1] {
//            message = "8.FRIENDS"
//        } else if bits == [1, 0, 1, 0] {
//            message = "9.Window Pain (Outro)"
//        } else if bits == [1, 0, 1, 1] {
//            message = "10.1985 (Intro to 'The Fall Off')"
//        } else if bits == [1, 1, 0, 0] {
//            message = "42 min 33sec"
//        } else if bits == [1, 1, 0, 1] {
//            message = "Greatest Album Of All Time"
//        } else if bits == [1, 1, 1, 0] {
//
//        } else {
//            message = "Reading Message..."
//        }
//        return message
        
        
        if bits == [0, 0, 0, 0] {
            message = "Puppy"
        } else if bits == [0, 0, 0, 1] {
            message = "woof"
        } else if bits == [0, 0, 1, 0] {
            message = "Photograph"
        } else if bits == [0, 0, 1, 1] {
            message = "White"
        } else if bits == [0, 1, 0, 0] {
            message = "brown"
        } else if bits == [0, 1, 0, 1] {
            message = "Donate"
        } else if bits == [0, 1, 1, 0] {
            message = "Adpot"
        } else if bits == [0, 1, 1, 1] {
            message = "I will remember you"
        } else {
            message = "Reading Message..."
        }
        return message
    }


    // TODO : fix me does not overlay image
    //https://www.ioscreator.com/tutorials/draw-shapes-core-graphics-ios-tutorial
    func drawRectangleOnImage(image: UIImage) -> UIImage {
        let imageSize = image.size
        let scale: CGFloat = 0
        UIGraphicsBeginImageContextWithOptions(imageSize, false, scale)

        image.draw(at: CGPoint.zero)
//        print(imageSize.width)
        //x= 0 is 66 of the screen
        // rect are drawn from the their uper left corner (viewed from portrait orientation)
        let rectangle0 = CGRect(x: self.center[0] - 5, y: self.center[1] - 5, width: 10, height: 10)
        let rectangle1 = CGRect(x: self.gSampLocals![0][0] - 5, y: self.gSampLocals![0][1] - 5, width: 10, height: 10)
        let rectangle2 = CGRect(x: self.gSampLocals![1][0] - 5, y: self.gSampLocals![1][1] - 5, width: 10, height: 10)
        let rectangle3 = CGRect(x: self.gSampLocals![2][0] - 5, y: self.gSampLocals![2][1] - 5, width: 10, height: 10)
        let rectangle4 = CGRect(x: self.gSampLocals![3][0] - 5, y: self.gSampLocals![3][1] - 5, width: 10, height: 10)

        UIColor.black.setFill()
        UIRectFill(rectangle0)
        UIColor.blue.setFill()
        UIRectFill(rectangle1)
        UIColor.yellow.setFill()
        UIRectFill(rectangle2)
        UIColor.red.setFill()
        UIRectFill(rectangle3)
        UIColor.green.setFill()
        UIRectFill(rectangle4)

        let newImage = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        return newImage
    }
    
    // https://gist.github.com/superpeteblaze/14885c5e2c8a5ccfbddb
    func addTextToImage(text: NSString, inImage: UIImage, atPoint:CGPoint) -> UIImage{
        // Setup the font specific variables
        let textColor = UIColor.white
        let textFont = UIFont(name: "Arial", size: 20)
           
       //Setups up the font attributes that will be later used to dictate how the text should be drawn
       let textFontAttributes = [
        NSAttributedString.Key.font: textFont,
        NSAttributedString.Key.foregroundColor: textColor,
       ]
       
       // Create bitmap based graphics context
       UIGraphicsBeginImageContextWithOptions(inImage.size, false, 0.0)

       
       //Put the image into a rectangle as large as the original image.
        inImage.draw(in: CGRect(x: 0, y: 0, width: inImage.size.width, height: inImage.size.height))
       
       // Our drawing bounds
        let drawingBounds = CGRect(x: 0.0, y: 0.0, width: inImage.size.width, height: inImage.size.height)
       
        let textSize = text.size(withAttributes: [NSAttributedString.Key.font:textFont as Any])
        let textRect = CGRect(x: drawingBounds.size.width/2 - textSize.width/2, y: drawingBounds.size.height/2 - textSize.height/2,
                              width: textSize.width, height: textSize.height)
       
        text.draw(in: textRect, withAttributes: textFontAttributes as [NSAttributedString.Key : Any])
       
       // Get the image from the graphics context
        guard let newImag = UIGraphicsGetImageFromCurrentImageContext() else { return inImage}
       UIGraphicsEndImageContext()
       
       return newImag

    }


    // not sure if needed
    func clearOverlayText() {
        // take image with test
        // return image with text removed
    }
    
    
    func myfft(sig:[Double]) -> [Double] {
        let N = sig.count
        var x = [Complex<Double>(0.0), Complex<Double>(1.0), Complex<Double>(2.0), Complex<Double>(3.0), Complex<Double>(4.0), Complex<Double>(5.0)]
        for i in 0...N-1 {
            x[i] = Complex<Double>(sig[i])
        }
        let mult = [[0, 0, 0, 0, 0, 0],
                    [0, 1, 2, 3, 4, 5],
                    [0, 2, 4, 6, 8, 10],
                    [0, 3, 6, 9, 12, 15],
                    [0, 4, 8, 12, 16, 20],
                    [0, 5, 10, 15, 20, 25]]
        var e = [
            [Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0),Complex<Double>(0.0)],
            [Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0)],
            [Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0)],
            [Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0)],
            [Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0)],
            [Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0)],
            [Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0), Complex<Double>(0.0)]
        ]
        for i in 0...N-1 {
            for j in 0...N-1 {
               e[i][j] = Complex<Double>.dftWeight(k: mult[i][j], n: N)
            }
        }
        var mags = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        var temp_sum = Complex<Double>(0.0)
        for i in 0...N-1 {
            temp_sum = Complex<Double>(0.0)
            for j in 0...N-1 {
                temp_sum = temp_sum + e[i][j] * x[j]
            }
            mags[i] = temp_sum.magnitude
        }
//        print("mags: ", mags)
        return mags
    }
    
    func mode(array: [Int]) -> Int {
        var bit_counter = [0,0,0]
        for i in array {
            if i == 0 {
                bit_counter[0] += 1
            } else if i == 1 {
                bit_counter[1] += 1
            } else {
                bit_counter[2] += 1
            }
        }
        return bit_counter.lastIndex(of: bit_counter.max()!)!
    }

// MARK: OG
//    func myfft(sig: [Double], n: Int) -> [Double] {
//    //        print(sig)
//        let LOG_N = vDSP_Length(log2(Float(n)))
//        let setup = vDSP_create_fftsetupD(LOG_N,2)!
//        var tempSplitComplexReal = [Double](repeating: 0.0, count: sig.count)
//        var tempSplitComplexImag = [Double](repeating: 0.0, count: sig.count)
//        for i in 0..<sig.count {
//            tempSplitComplexReal[i] = sig[i]
//        }
//        var tempSplitComplex = DSPDoubleSplitComplex(realp: &tempSplitComplexReal, imagp: &tempSplitComplexImag)
//        vDSP_fft_zipD(setup, &tempSplitComplex, 1, LOG_N, FFTDirection(FFT_FORWARD))
//        var fftMagnitudes = [Double](repeating: 0.0, count: n/2)
//        vDSP_zvmagsD(&tempSplitComplex, 1, &fftMagnitudes, 1, vDSP_Length(n/2))
//        print(NSLog("Address of setup =  %p",setup))
//        vDSP_destroy_fftsetupD(setup)
//
//        return fftMagnitudes
//    }
// MARK: OG Fixed warning
//    func myfft(sig: [Double], n: Int) -> [Double] {
//    //        print(sig)
//        let LOG_N = vDSP_Length(log2(Double(n)))
//        let setup = vDSP_create_fftsetupD(LOG_N,2)!
//        var tempSplitComplexReal = [Double](repeating: 0.0, count: sig.count)
//        var tempSplitComplexImag = [Double](repeating: 0.0, count: sig.count)
//        for i in 0..<sig.count {
//            tempSplitComplexReal[i] = sig[i]
//        }
//        var fftMagnitudes = [Double](repeating: 0.0, count: n/2)
//        tempSplitComplexReal.withUnsafeMutableBufferPointer {realBP in
//            tempSplitComplexImag.withUnsafeMutableBufferPointer {imaginaryBP in
//                var tempSplitComplex = DSPDoubleSplitComplex(realp: realBP.baseAddress!, imagp: imaginaryBP.baseAddress!)
//                vDSP_fft_zipD(setup, &tempSplitComplex, 1, LOG_N, FFTDirection(FFT_FORWARD))
//                vDSP_zvmagsD(&tempSplitComplex, 1, &fftMagnitudes, 1, vDSP_Length(n/2))
//                print(NSLog("Address of setup =  %p",setup))
//                vDSP_destroy_fftsetupD(setup)
//
//            }
//        }
//
//        return fftMagnitudes
//    }
    
// https://gist.github.com/jeremycochoy/45346cbfe507ee9cb96a08c049dfd34f
    
//    func myfft(sig: [Float], n: Int) -> [Float] {
//        //
//        // MIT LICENSE: Copy past as much as you want :)
//        //
//
//        // --- INITIALIZATION
//        // The length of the input
//        let length = vDSP_Length(sig.count)
//
//        // The power of two of two times the length of the input.
//        // Do not forget this factor 2.
//
////        let log2n = vDSP_Length(ceil(log2(Float(length * 2))))
//        let log2n = vDSP_Length(ceil(log2(Float(n))))
//        // Create the instance of the FFT class which allow computing FFT of complex vector with length
//        // up to `length`.
//        let fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
//
//
//        // --- Input / Output arrays
//        var forwardInputReal = [Float](sig) // Copy the signal here
//        var forwardInputImag = [Float](repeating: 0, count: Int(length))
//        var forwardOutputReal = [Float](repeating: 0, count: Int(length))
//        var forwardOutputImag = [Float](repeating: 0, count: Int(length))
//        var magnitudes = [Float](repeating: 0, count: Int(length))
//
//        /// --- Compute FFT
//        forwardInputReal.withUnsafeMutableBufferPointer { forwardInputRealPtr in
//          forwardInputImag.withUnsafeMutableBufferPointer { forwardInputImagPtr in
//            forwardOutputReal.withUnsafeMutableBufferPointer { forwardOutputRealPtr in
//              forwardOutputImag.withUnsafeMutableBufferPointer { forwardOutputImagPtr in
//                // Input
//                let forwardInput = DSPSplitComplex(realp: forwardInputRealPtr.baseAddress!, imagp: forwardInputImagPtr.baseAddress!)
//                // Output
//                var forwardOutput = DSPSplitComplex(realp: forwardOutputRealPtr.baseAddress!, imagp: forwardOutputImagPtr.baseAddress!)
//
//                fftSetup.forward(input: forwardInput, output: &forwardOutput)
//                vDSP.absolute(forwardOutput, result: &magnitudes)
//              }
//            }
//          }
//        }
//        return magnitudes
//    }
    
//    func myfft(sig: [Double], n: Int) -> [Int] {
//    //        print(sig)
//        let log2n = vDSP_Length(log2(Float(n)))
//
//        guard let fftSetUp = vDSP.FFT(log2n: log2n,
//                                      radix: .radix2,
//                                      ofType: DSPSplitComplex.self) else {
//                                        fatalError("Can't create FFT Setup.")
//        }
//        let halfN = Int(n / 2)
//
//        var forwardInputReal = [Float](repeating: 0,
//                                       count: halfN)
//        var forwardInputImag = [Float](repeating: 0,
//                                       count: halfN)
//        var forwardOutputReal = [Float](repeating: 0,
//                                        count: halfN)
//        var forwardOutputImag = [Float](repeating: 0,
//                                        count: halfN)
//
//        forwardInputReal.withUnsafeMutableBufferPointer { forwardInputRealPtr in
//            forwardInputImag.withUnsafeMutableBufferPointer { forwardInputImagPtr in
//                forwardOutputReal.withUnsafeMutableBufferPointer { forwardOutputRealPtr in
//                    forwardOutputImag.withUnsafeMutableBufferPointer { forwardOutputImagPtr in
//
//                        // 1: Create a `DSPSplitComplex` to contain the signal.
//                        var forwardInput = DSPSplitComplex(realp: forwardInputRealPtr.baseAddress!,
//                                                           imagp: forwardInputImagPtr.baseAddress!)
//
//                        // 2: Convert the real values in `signal` to complex numbers.
//                        sig.withUnsafeBytes {
//                            vDSP.convert(interleavedComplexVector: [DSPComplex]($0.bindMemory(to: DSPComplex.self)),
//                                         toSplitComplexVector: &forwardInput)
//                        }
//
//                        // 3: Create a `DSPSplitComplex` to receive the FFT result.
//                        var forwardOutput = DSPSplitComplex(realp: forwardOutputRealPtr.baseAddress!,
//                                                            imagp: forwardOutputImagPtr.baseAddress!)
//
//                        // 4: Perform the forward FFT.
//                        fftSetUp.forward(input: forwardInput,
//                                         output: &forwardOutput)
//                    }
//                }
//            }
//        }
//        print(forwardOutputImag)
//        let componentFrequencies = forwardOutputImag.enumerated().filter {
//            $0.element < -1
//        }.map {
//            return $0.offset
//        }
//
//        // Prints "[1, 5, 25, 30, 75, 100, 300, 500, 512, 1023]"
//        print(componentFrequencies)
//
//        return componentFrequencies
//    }
    
    // MARK: OG Fixed warning
//        func myfft(sig: [Float], n: Int) -> [Float] {
//        //        print(sig)
//            let LOG_N = vDSP_Length(log2(Double(n)))
//            let setup = vDSP_create_fftsetup(LOG_N,2)
//
//            let complexValuesCount = sig.count
//            var tempSplitComplexReal = [Float]()
//            var tempSplitComplexImag = [Float]()
//
//            sig.withUnsafeBytes { signalPtr in
//                tempSplitComplexReal = [Float](unsafeUninitializedCapacity: complexValuesCount) { realBuffer, realInitializedCount in
//                    tempSplitComplexImag = [Float](unsafeUninitializedCapacity: complexValuesCount) { imagBuffer, imagInitializedCount in
//                        var splitComplex = DSPSplitComplex(realp: realBuffer.baseAddress!,imagp: imagBuffer.baseAddress!)
//
//                        vDSP_ctoz([DSPComplex](signalPtr.bindMemory(to: DSPComplex.self)), 2,&splitComplex, 1, vDSP_Length(complexValuesCount))
//
//                        imagInitializedCount = complexValuesCount
//                    }
//                    realInitializedCount = complexValuesCount
//                }
//            }
//
//
//
//
//            for i in 0..<sig.count {
//                tempSplitComplexReal[i] = sig[i]
//            }
//            var fftMagnitudes = [Double](repeating: 0.0, count: n/2)
//            tempSplitComplexReal.withUnsafeMutableBufferPointer {realBP in
//                tempSplitComplexImag.withUnsafeMutableBufferPointer {imaginaryBP in
//                    var tempSplitComplex = DSPDoubleSplitComplex(realp: realBP.baseAddress!, imagp: imaginaryBP.baseAddress!)
//                    vDSP_fft_zip(setup, &tempSplitComplex, 1, LOG_N, FFTDirection(FFT_FORWARD))
//                    vDSP_zvmags(&tempSplitComplex, 1, &fftMagnitudes, 1, vDSP_Length(n/2))
//                    print(NSLog("Address of setup =  %p",setup))
//                    vDSP_destroy_fftsetupD(setup)
//
//                }
//            }
//
//            return fftMagnitudes
//        }
    
// MARK: APPLE DOC https://developer.apple.com/documentation/accelerate/performing_fourier_transforms_on_multiple_signals
//    func myfft(sig: [Float], n: Int) -> [Float] {
//  //    //        print(sig)
//        let realValuesCount = 6
//
//        let complexValuesCount = sig.count / 2
//
//        var complexReals = [Float]()
//        var complexImaginaries = [Float]()
//
//        sig.withUnsafeBytes { signalPtr in
//            complexReals = [Float](unsafeUninitializedCapacity: complexValuesCount) {
//                realBuffer, realInitializedCount in
//                complexImaginaries = [Float](unsafeUninitializedCapacity: complexValuesCount) {
//                    imagBuffer, imagInitializedCount in
//                    var splitComplex = DSPSplitComplex(realp: realBuffer.baseAddress!,
//                                                       imagp: imagBuffer.baseAddress!)
//
//                    vDSP_ctoz([DSPComplex](signalPtr.bindMemory(to: DSPComplex.self)), 2,
//                              &splitComplex, 1,
//                              vDSP_Length(complexValuesCount))
//
//                    imagInitializedCount = complexValuesCount
//                }
//                realInitializedCount = complexValuesCount
//            }
//        }
//
//        let signalCount = 1
//
//        complexReals.withUnsafeMutableBufferPointer { realPtr in
//            complexImaginaries.withUnsafeMutableBufferPointer { imagPtr in
//                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!,
//                                                   imagp: imagPtr.baseAddress!)
//
//                let log2n = vDSP_Length(log2(Float(realValuesCount)))
//                if let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) {
//
//                    vDSP_fftm_zrip(fft,
//                                   &splitComplex, 1,
//                                   vDSP_Stride(realValuesCount / 2),
//                                   log2n,
//                                   vDSP_Length(signalCount),
//                                   FFTDirection(kFFTDirection_Forward))
//
//                    vDSP_destroy_fftsetup(fft)
//                }
//            }
//        }
//
//
//        let magnitudes = [Float](unsafeUninitializedCapacity: complexValuesCount) {
//            buffer, initializedCount in
//            complexReals.withUnsafeMutableBufferPointer { realPtr in
//                complexImaginaries.withUnsafeMutableBufferPointer { imagPtr in
//
//                    let splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!,
//                                                       imagp: imagPtr.baseAddress!)
//
//                    vDSP.squareMagnitudes(splitComplex,
//                                          result: &buffer)
//                }
//            }
//
//            initializedCount = complexValuesCount
//        }
//
//        for i in 0 ..< signalCount {
//            let start = i * (realValuesCount / 2)
//            let end = start + (realValuesCount / 2) - 1
//
//            let signalMagnitudes = magnitudes[start ..< end]
//
//            let components = signalMagnitudes.enumerated().filter {
//                $0.element > sqrt(.ulpOfOne)
//            }
//
//            // Prints
//            //  [(offset: 1, element: 65536.0), (offset: 5, element: 2621.4412)]
//            //  [(offset: 5, element: 65536.016), (offset: 7, element: 5898.24)]
//            //  [(offset: 3, element: 65536.0), (offset: 9, element: 23592.96)]
//            //  [(offset: 2, element: 1474.56), (offset: 7, element: 65536.0)]
//            print(components)
//        }
//        print(magnitudes)
//        return magnitudes
//      }
}

// MARK:FORMAR USED
//31:  <AVCaptureDeviceFormat: 0x2808fcbc0 'vide'/'420f' 1920x1080, { 5-120 fps}, fov:38.784, supports vis, max zoom:135.00 (upscales @2.00), AF System:2, ISO:15.0-480.0, SS:0.000012-0.200000, supports wide color>
func configureCameraForFrameRate(device: AVCaptureDevice, frameRate: Int, bestFormat: Int) {

        do {
            try device.lockForConfiguration()

            // Set the device's active format.
            device.activeFormat = device.formats[bestFormat]

            // Set the device's min/max frame duration.
            device.activeVideoMinFrameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate))
            device.activeVideoMaxFrameDuration = CMTimeMake(value: 1, timescale: Int32(frameRate))

            device.unlockForConfiguration()
//            print("success")
        } catch {
            print("Handle error.")
        }
}

//MARK: EXTENSION FOR IMAGE
// https://stackoverflow.com/questions/50623967/swift-4-get-rgb-values-of-pixel-in-uiimage
//https://math.stackexchange.com/questions/1019175/how-correctly-define-the-pixel-intensity-of-an-image

extension UIImage {

    func getLightnes (x: Int, y: Int) -> UIColor? {

        if x < 0 || x > Int(size.width) || y < 0 || y > Int(size.height) {
            return nil
        }

        let provider = self.cgImage!.dataProvider
        let providerData = provider!.data
        let data = CFDataGetBytePtr(providerData)

        let numberOfComponents = 4
        let pixelData = ((Int(size.width) * y) + x) * numberOfComponents

        let r = CGFloat(data![pixelData]) / 255.0
        let g = CGFloat(data![pixelData + 1]) / 255.0
        let b = CGFloat(data![pixelData + 2]) / 255.0
        let a = CGFloat(data![pixelData + 3]) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

//func configureCameraForHighestFrameRate(device: AVCaptureDevice) {
//
//    var bestFormat: AVCaptureDevice.Format?
//    var bestFrameRateRange: AVFrameRateRange?
//    var i = 0
//    for format in device.formats {
//        for range in format.videoSupportedFrameRateRanges {
//            if(range.maxFrameRate == 120.0){
//                print("\(i):  \(format)")
//                print(range)
//                print(range.maxFrameRate)
//                print(bestFrameRateRange?.maxFrameRate as Any)
//                print("\n")
//            }
//            i+=1
//            print(i)
//            if range.maxFrameRate > bestFrameRateRange?.maxFrameRate ?? 0 {
//                bestFormat = format
//                bestFrameRateRange = range
//            }
//        }
//    }
//
//    if let bestFormat = bestFormat,
//       let bestFrameRateRange = bestFrameRateRange {
//        do {
//            try device.lockForConfiguration()
//
//            // Set the device's active format.
//            print(bestFormat)
//            device.activeFormat = bestFormat
//
//            // Set the device's min/max frame duration.
//            let duration = bestFrameRateRange.minFrameDuration
//            print(duration)
//            device.activeVideoMinFrameDuration = duration
//            device.activeVideoMaxFrameDuration = duration
//
//            device.unlockForConfiguration()
//        } catch {
//            // Handle error.
//        }
//    }
//}

