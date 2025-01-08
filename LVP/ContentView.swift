import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = RTCViewModel()

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0, green: 0.3, blue: 0),
                    Color.black
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                if viewModel.roomId.isEmpty {
                    // Initial screen: Create or Join
                    TextField("Enter Room ID", text: $viewModel.inputRoomId)  // Updated binding
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .padding(.horizontal)
                        .disabled(!viewModel.roomId.isEmpty) // Disable if a room has been created

                    Button("Create Room") {
                        viewModel.createRoom()
                    }
                    .padding()
                    .disabled(!viewModel.roomId.isEmpty) // Disable if a room has been created
                    
                    Button("Join Room") {
                        viewModel.joinRoom()
                    }
                    .padding()
                } else {
                    // In-call screen
                    Text("Room ID: \(viewModel.roomId)")
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Button(action: {
                        viewModel.handleConnectionAction()
                    }) {
                        Text(viewModel.connectionStatus == .disconnected ? "Join Room" : "Leave Room")
                            .foregroundColor(.white)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(viewModel.connectionStatus == .disconnected ? Color.green : Color.red)
                            .cornerRadius(10)
                    }
                    .padding(.horizontal)
                    
                    Text(viewModel.connectionStatus.description)
                        .foregroundColor(.white)
                        .padding()

                    if !viewModel.remotePeerIds.isEmpty {
                        Text("Connected Peers: \(viewModel.remotePeerIds.joined(separator: ", "))")
                            .foregroundColor(.white)
                            .padding()
                    }
                }
            }
            .padding()
            .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
        .onAppear {
            viewModel.initialize()
        }
    }
}

#Preview {
    ContentView()
}
