import SwiftUI

struct WallhavenURLInputButton: View {
    let tint: Color
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .detailGlassCircleChrome()
        }
        .buttonStyle(.plain)
        .help(t("通过链接打开壁纸"))
    }
}

struct WallhavenURLInputSheet: View {
    @Binding var urlInput: String
    let errorMessage: String?
    let isLoading: Bool
    let onSubmit: () -> Void
    let onDismiss: () -> Void
    let title: String
    let placeholder: String
    let supportedFormatsHint: String
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(title).font(.title3.weight(.semibold))
                Spacer()
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            TextField(placeholder, text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit { if !isLoading { onSubmit() } }
            Text(supportedFormatsHint)
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button(t("cancel"), action: onDismiss)
                Button(t("wallhaven.link.open"), action: onSubmit)
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 440)
        .liquidGlassSurface(.prominent, in: RoundedRectangle(cornerRadius: 20))
        .onAppear { isFocused = true }
        .onKeyPress(.escape) { onDismiss(); return .handled }
    }
}
