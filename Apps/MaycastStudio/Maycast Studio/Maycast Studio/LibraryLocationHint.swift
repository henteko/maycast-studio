import SwiftUI

/// One-line note shown under the name field on the New Episode / New Show
/// sheets, telling the user the bundle is created in their Maycast library
/// (so there's no file panel) and what its filename will be.
struct LibraryLocationHint: View {
    let filename: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 10))
                .foregroundStyle(MaycastPalette.fg3)
            Text("Saved in your library as")
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
