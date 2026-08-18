//
//  Tutorial3.swift
//  SendSociety
//
//  Created by Jana Broto on 11/08/26.
//

import SwiftUI

struct Tutorial3: View {
    var body: some View {
        VStack {
            
            Image("Tutorial1")
                .resizable()
                .scaledToFit()
                .frame(width: 600)
                .padding(40)

            Text("Keep Every Climb Organized.")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Save your analyzed videos and organize them into folders for each climber. Easily revisit previous sessions, compare progress, and find the right video when you need it.")
                .font(.body)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 280)
                .padding(.top, 10)
                        
            Button(action: {}){
                Text("Get Started")
                    .font(.title)
                    .fontWeight(.bold)
                    .padding(.vertical,30)
                    .padding(.horizontal, 80)
                    .background(AppColor.ButtonColor)
                    .foregroundColor(.white)
                    .cornerRadius(50)
            }.padding(.bottom,20) .padding(.top,20)
            
            Spacer()
            
        }.padding(.top,10)

        
                
    }
}

#Preview {
    Tutorial3()
}
