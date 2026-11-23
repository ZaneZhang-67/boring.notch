//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf),
    TabModel(label: "Clipboard", icon: "doc.on.clipboard.fill", view: .clipboard)
]

struct TabSelectionView: View {
    @EnvironmentObject private var vm: BoringViewModel
    @Namespace var animation

    private var visibleTabs: [TabModel] {
        tabs.filter { tab in
            guard tab.view == .clipboard else { return true }
            guard let screenUUID = vm.screenUUID else { return false }
            return NSScreen.screen(withUUID: screenUUID)?.isBuiltInDisplay == true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(visibleTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: vm.currentView == tab.view) {
                        if tab.view == .clipboard {
                            NotificationCenter.default.post(
                                name: .clipboardPanelOpenRequested,
                                object: vm
                            )
                        } else if vm.currentView == .clipboard {
                            NotificationCenter.default.post(
                                name: .clipboardPanelSwitchRequested,
                                object: vm,
                                userInfo: ["targetView": tab.view]
                            )
                        } else {
                            withAnimation(.smooth) {
                                vm.currentView = tab.view
                                if vm.notchState == .open {
                                    vm.open()
                                }
                            }
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == vm.currentView ? .white : .gray)
                    .background {
                        if tab.view == vm.currentView {
                            Capsule()
                                .fill(vm.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(vm.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
