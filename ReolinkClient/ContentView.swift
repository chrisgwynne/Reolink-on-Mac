import SwiftUI

/// Root view: a camera grid with layout controls, presenting a detail sheet
/// when a tile is opened.
struct ContentView: View {
    @EnvironmentObject private var store: CameraStore

    @State private var layout: GridLayout = .twoByTwo
    @State private var selectedCamera: Camera?
    @State private var showingOnboarding = false
    @State private var showingSettings = false

    var body: some View {
        CameraGridView(layout: $layout, selectedCamera: $selectedCamera)
            .navigationTitle("Reolink")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Picker("Layout", selection: $layout) {
                        ForEach(GridLayout.allCases) { option in
                            Label(option.rawValue, systemImage: option.symbolName)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItemGroup {
                    Button {
                        showingOnboarding = true
                    } label: {
                        Label("Add Camera", systemImage: "plus")
                    }
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Manage", systemImage: "slider.horizontal.3")
                    }
                }
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingView(store: store)
                    .environmentObject(store)
            }
            .sheet(isPresented: $showingSettings) {
                NavigationStack {
                    SettingsView()
                        .environmentObject(store)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                }
            }
            .sheet(item: $selectedCamera) { camera in
                NavigationStack {
                    CameraDetailView(camera: camera, store: store)
                        .environmentObject(store)
                        .frame(minWidth: 760, minHeight: 560)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Close") { selectedCamera = nil }
                            }
                        }
                }
            }
    }
}

#Preview {
    ContentView()
        .environmentObject(CameraStore())
}
