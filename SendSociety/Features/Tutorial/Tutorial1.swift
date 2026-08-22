//
//  Tutorial1.swift
//  SendSociety
//
//  Created by Jana Broto on 13/08/26.
//

import SwiftUI


struct Tutorial1: View {

    @State private var showTutorial = true
    
    var body: some View {
        ZStack {
            //normal screen
        
            if showTutorial {
                
                Color.black.opacity(0.7)
                    .ignoresSafeArea()            }
            
            VStack{
                Spacer()
                Image("Tutorial1")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 300)
                    .padding(40)
            
                Text("Scan The Wall!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white)
                
                Text("Frame the entire route from the bottom to the top of the wall, and make sure no climber is in view. Hold your device steady until you see a notification that the scan is complete.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 280)
                    .padding(.top, 10)
                    .foregroundStyle(Color.white)
                
                Button(action: {}){

                    Text("Got it!")
                        .font(.system(size: 24))
                        .fontWeight(.bold)
                        .padding(.vertical,20)
                        .padding(.horizontal, 120)
                        .background(Color(red: 141/255, green: 220/255, blue: 220/255))
                        .foregroundColor(.white)
                        .cornerRadius(50)
                }.padding(.bottom,20) .padding(.top,20)
                
            }.padding(.bottom,20)
            
        }
       
    }
}

#Preview {
    Tutorial1()
}
