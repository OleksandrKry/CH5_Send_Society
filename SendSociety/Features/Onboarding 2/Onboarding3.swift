//
//  Onboarding3.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct Onboarding3: View {
    let onFinish: () -> Void
    
    var body: some View {
        GeometryReader{ geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            VStack {
                if isLandscape {
                    Image("Introduction3")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 420)
                        .padding(40)
                } else{
                    Image("Introduction3")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 600)
                        .padding(40)
                }
                
                Text("Keep Every Climb Organized.")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(.black)
                Text("Save your analyzed videos and organize them into folders for each climber. Easily revisit previous sessions, compare progress, and find the right video when you need it.")
                    .font(.body)
                    .foregroundStyle(.black)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 280)
                    .padding(.top, 10)
                
                
                Button(action: {
                    onFinish()
                }){
                    
                    Text("Get Started")
                        .font(.system(size: 24))
                        .fontWeight(.bold)
                        .padding(.vertical,20)
                        .padding(.horizontal, 120)
                        .background(Color(red: 75/255, green: 105/255, blue: 141/255))
                        .foregroundColor(.white)
                        .cornerRadius(50)
                    
                }.padding(.bottom,20) .padding(.top,20)
                
                Spacer()
            }
            
        }.padding(.top,20)

        
                
    }
}

#Preview {
//    Onboarding3(onFinish: <#T##() -> Void#>)
}
