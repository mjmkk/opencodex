//
//  ContentView.swift
//  CodexWorkerApp
//
//  Created by mjmk on 2/15/26.
//

import SwiftUI
import CodexWorker

struct WorkerRootView: View {
    var body: some View {
        CodexWorkerRoot.makeRootView()
    }
}

#Preview {
    WorkerRootView()
}
