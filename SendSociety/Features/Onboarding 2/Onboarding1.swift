//
//  Onboarding1.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct Onboarding1: View {
    
    var body: some View {
        GeometryReader{ geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            VStack {
                if isLandscape {
                    Image("Introduction1")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 420)
                        .padding(40)
                } else{
                    Image("Introduction1")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 600)
                        .padding(40)
                }
                
                Text("Welcome to GetBeta")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.black)
                Text("GetBeta helps you capture, analyze, and annotate your climber’s bouldering technique and posture, so you can provide clearer feedback and coach more efficiently.")
                    .font(.body)
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 280)
                    .padding(.top, 20)
                
                Spacer()
            }
                
        }.padding(.top,10)
        

        
                
    }
}
        

#Preview {
    Onboarding1()
}
