//
//  ViewController.swift
//  cam_rx
//
//  Created by Vicente  Arroyos on 5/30/21.
//

import UIKit

class ViewController: UIViewController, FrameExtractorDelegate {
    var frameExtractor: FrameExtractor!
        
    @IBOutlet weak var imageView: UIImageView!
    
        override func viewDidLoad() {
            super.viewDidLoad()
            frameExtractor = FrameExtractor()
            frameExtractor.delegate = self
        }

    func captured(image: UIImage) {
        imageView.image = image
    }
    

}






