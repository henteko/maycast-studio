import SwiftUI

/// One-line note shown under the name field on the New Episode / New Show
/// sheets, telling the user where the bundle is created (so there's no file
/// panel) and what its filename will be. `location` is "your library" by
/// default, or a Show name when the Episode is created inside a Show.
struct LibraryLocationHint: View {
    var location: String = "your library"
    let filename: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 10))
                .foregroundStyle(MaycastPalette.fg3)
            Text("Saved in \(location) as")
                .font(MaycastFont.body(11))
                .foregroundStyle(MaycastPalette.fg3)
            Text(filename)
                .font(MaycastFont.mono(11, weight: .semibold))
                .foregroundStyle(MaycastPalette.fg1)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
        }
    }
}
