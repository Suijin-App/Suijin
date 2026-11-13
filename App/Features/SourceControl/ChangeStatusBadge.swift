import SwiftUI

/// A file's change letter (A, M, D, U…) in a small filled rounded square of the change's color, so it reads as one
/// tag and stays legible on a selected row. A custom view: the system has no status-badge control.
struct ChangeStatusBadge: View {
    let letter: String
    let color: Color

    static let side: CGFloat = 16

    var body: some View {
        Text(verbatim: letter)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .frame(width: Self.side, height: Self.side)
            .background(color, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            // Centred on the first line of the row's text: put the badge's middle about half a cap height above
            // that line's baseline, in an `HStack(alignment: .firstTextBaseline)`.
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4.5 }
    }
}
