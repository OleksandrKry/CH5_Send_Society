//
//  AppColor.swift
//  SendSociety
//
//  Created by Orenz on 14/08/26.
//

import SwiftUI

    //MARK: HEX COLOR
    struct AppColor {
        static let Accent = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#3896E2") : UIColor(hex: "#3896E2") })
        static let AnnotateBlue = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#1264A3") : UIColor(hex: "#1264A3") })
        static let AnnotateGreen = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#16803C") : UIColor(hex: "#16803C") })
        static let AnnotateRed = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#D92D20") : UIColor(hex: "#D92D20") })
        static let AnnotateYellow = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#C98A00") : UIColor(hex: "#C98A00") })
        
        static let PrimaryBlue = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#4B698D") : UIColor(hex: "#4B698D") })
        static let PrimaryDark = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#14141A") : UIColor(hex: "#14141A") })
        static let PrimaryLight = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#F0F1F3") : UIColor(hex: "#F0F1F3") })
        static let PrimaryLightBackground = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#F0F1F3", alpha: 0.5) : UIColor(hex: "#F0F1F3", alpha: 0.5) }
        static let PrimaryLightLessOpacity = UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#F0F1F3", alpha: 0.75) : UIColor(hex: "#F0F1F3", alpha: 0.75) }
        
        static let SecondaryBlue = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#8DDCDC") : UIColor(hex: "#8DDCDC") })
        static let SecondaryDark = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#2A2A32") : UIColor(hex: "#2A2A32") })
        static let TertiaryDark = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#40404A") : UIColor(hex: "#40404A") })
        
        static let ButtonColor = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: "#4B698D") : UIColor(hex: "#4B698D") })
        
    
//        static let sameColor = Color(UIColor(hex: "#007AFF")) // Same for both modes
    }
