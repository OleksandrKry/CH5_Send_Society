//
//  ClimberList.swift
//  SendSociety
//
//  Created by Jana Broto on 18/08/26.
//

import SwiftUI

struct Climber: Identifiable, Hashable {
    var id: UUID = UUID()
    var firstName: String
    var lastName: String
    
    var initials: String {
        String("\(firstName.prefix(1))\(lastName.prefix(1))")
    }
    var sectionTitle: String {
        String(firstName.prefix(1))
    }
}

var lenny = Climber(firstName: "Lenny", lastName: "Kravitz")

var theo = Climber(firstName: "Theo", lastName: "Teblung")

var alan = Climber(firstName: "Alan", lastName: "Frederick")

var alex = Climber(firstName: "Alex", lastName: "Kry")

var climbers = [lenny, theo, alan, alex]
    .sorted{$0.firstName < $1.firstName}

struct ClimberList: View {
    var body: some View {
        NavigationStack {
            
//            Text("Climbers")
//                    .font(.largeTitle)
//                    .fontWeight(.bold)
//                    .frame(maxWidth: .infinity, alignment: .leading)
//                    .padding(.horizontal)


            List{
                        ForEach(climbers) { climber in
                            HStack{
                                ZStack{
                                    Circle()
                                        .frame(width: 42)
                                        .foregroundStyle(Color(red: 75/255, green: 105/255, blue: 141/255))
                                    Text (climber.initials) .foregroundStyle(.white)
                                }
                                NavigationLink{
                                    ClimberVideos()
                                } label: {
                                    Text (climber.firstName + " " + climber.lastName)
                                }
                                }
                            }
                        }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .listSectionIndexVisibility(.visible)
                .navigationTitle("Climbers")
                .navigationBarTitleDisplayMode(.large)
                .searchable(text: .constant(""))
                .safeAreaInset(edge: .bottom) {
                    HStack{
                        Spacer()
                        
                        Button(action: {
                            print("Record tapped")
                        }) {
                            ZStack {
                            // The red circle background
                                Circle()
                                .fill(.red)
                                .frame(width: 64, height: 64)
                                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 4)
                                            
                            // The white video camera icon on top
                                Image(systemName: "video.fill")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundColor(.white)
                            }
                            .padding(.trailing,40)
                        }
                        .padding(.bottom, 15) // Keeps it safely above the iPad home indicator
                    }
                }
            
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            print("")
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
//
//                    ToolbarSpacer(.fixed, placement: .bottomBar)
//                    
//                    ToolbarItem(placement: .bottomBar) {
//                        Button {
//                            print("")
//                        } label: {
//                            Image(systemName: "plus")
//                        }
//                    }
//                    
                }
        }.padding(.horizontal,10)
        }
    }


#Preview {
    ClimberList()
}
