//
//  Onboarding2.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct Onboarding2: View {
    var body: some View {
        GeometryReader{ geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            VStack {
                if isLandscape {
                    Image("Introduction2")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 420)
                        .padding(40)
                } else{
                    Image("Introduction2")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 600)
                        .padding(40)
                }
                
                Text("See every move more clearly.")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.black)
                Text("Analyze climbing technique in HD with frame-by-frame playback, 3D simulation, and drawing tools. Use skeleton tracking to visualize body and joint movement, making movement patterns easier to see, understand, and explain.")
                    .font(.body)
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 280)
                    .padding(.top, 20)
                
                Spacer()
                
            }.padding(.top,10)
        }
        
                
    }
}

#Preview {
    Onboarding2()
}

