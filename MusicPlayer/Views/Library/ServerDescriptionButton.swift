import SwiftUI

/// A loaded description for one server item.
struct ServerDescription: Equatable {
    let target: ServerDescriptionTarget
    let text: String
}

/// Small "ABOUT" text button that opens the description in the shared detail sheet.
struct ServerDescriptionButton: View {
    let description: ServerDescription
    let title: String

    @State private var showingSheet = false

    var body: some View {
        Button {
            HapticFeedback.lightImpact()
            showingSheet = true
        } label: {
            Text("ABOUT")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingSheet) {
            SettingOptionDetailSheet(detail: SettingOptionDetail(
                id: "about-\(description.target.cacheKey)",
                title: title.uppercased(),
                description: description.text
            ), expandsToFullScreen: true)
        }
    }
}

extension View {
    /// Loads the description only while this page is on screen (`.task(id:)`); the result stays nil,
    /// hiding the button, when the item is not a server item or the server has no description.
    func loadsServerDescription(_ target: ServerDescriptionTarget?, sources: [ServerSourceLink],
                                into result: Binding<ServerDescription?>) -> some View {
        task(id: target) {
            guard let target, let link = sources.first(where: { $0.id == target.serverID }) else {
                result.wrappedValue = nil
                return
            }
            if result.wrappedValue?.target != target { result.wrappedValue = nil }
            let text = await ServerDescriptionCache.shared.description(for: target, link: link)
            guard !Task.isCancelled else { return }
            result.wrappedValue = text.map { ServerDescription(target: target, text: $0) }
        }
    }
}
