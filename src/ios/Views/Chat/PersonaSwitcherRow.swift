import SwiftUI

// MARK: - PersonaAvatarView
//
// 把 Persona.avatar（data:image/png;base64,…）渲染成圆形头像；
// 没设头像时用系统 person 图标。跟 App 其他地方一样不用 emoji。

struct PersonaAvatarView: View {
    let dataURI: String?
    var size: CGFloat = 28

    private var uiImage: UIImage? {
        guard let uri = dataURI, !uri.isEmpty,
              let comma = uri.firstIndex(of: ",") else { return nil }
        let b64 = String(uri[uri.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Group {
            if let img = uiImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - PersonaSwitcherRow
//
// 侧边栏顶部的人设切换行：点一下弹出人设列表。
// v1 只做最小可用：显示当前人设头像+名字。

struct PersonaSwitcherRow: View {
    @ObservedObject var store: PersonaStore
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                PersonaAvatarView(dataURI: store.current.avatar, size: 30)
                Text(store.current.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}
