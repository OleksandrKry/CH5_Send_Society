//
//  Tutorial3.swift
//  SendSociety
//
//  Created by Jana Broto on 13/08/26.
//

import SwiftUI


struct Tutorial3: View {

    @State private var showTutorial = true
    
    var body: some View {
        ZStack {
            //normal screen
        
            if showTutorial {
                
                Color.black.opacity(0.7)
                    .ignoresSafeArea()            }
            
            VStack{
                Spacer()
                Text("Start annotation")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundStyle(Color.white)
                
                Text("Once the scan is complete, the climber can enter the frame and get ready. Start recording before they begin climbing, and keep recording until the climb is finished. You can continue recording more attempts until you’re done with the route.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 280)
                    .padding(.top, 20)
                    .foregroundStyle(Color.white)
                
                Button(action: {}){

                    Text("Got it!")
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.vertical,20)
                        .padding(.horizontal, 140)
                        .background(Color(red: 141/255, green: 220/255, blue: 220/255))
                        .foregroundColor(.white)
                        .cornerRadius(50)
                }.padding(.bottom,20) .padding(.top,20)
                
            }.padding(.bottom,20)
            
        }
       
    }
}

#Preview {
    Tutorial3()
}
