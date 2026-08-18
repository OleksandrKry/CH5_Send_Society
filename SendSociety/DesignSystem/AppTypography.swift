//
//  AppTypography.swift
//  SendSociety
//
//  Created by Orenz on 14/08/26.
//

import SwiftUI

struct AppTypography {
    //MARK: SIZES
    struct Sizes {
        static let paddingSmall: CGFloat = 8
        static let paddingMedium: CGFloat = 16
        static let paddingLarge: CGFloat = 24
        static let cornerRadius: CGFloat = 12
    }
    
    //MARK: TYPOGRAPHY
    struct Typography {
        static let headline = Font.system(size: 24, weight: .bold, design: .default)
        static let body = Font.system(size: 16, weight: .regular, design: .default)
        static let caption = Font.system(size: 12, weight: .light, design: .default)
    }
}
