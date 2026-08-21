//
//  Onboarding2.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct Onboarding2: View {
    var body: some View {
        VStack {
            
            Image("Introduction2")
                .resizable()
                .scaledToFit()
                .frame(width: 600)
                .padding(40)

            Text("See every move more clearly.")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Analyze climbing technique in HD with frame-by-frame playback, 3D simulation, and drawing tools. Use skeleton tracking to visualize body and joint movement, making movement patterns easier to see, understand, and explain.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 280)
                .padding(.top, 20)
                        
            Spacer()
                    
            }.padding(.top,10)

        
                
    }
}

#Preview {
    Onboarding2()
}
