import SwiftUI
import UIKit

enum OCTheme {
    static let bg = Color(red: 0.075, green: 0.063, blue: 0.063)
    static let bg2 = Color(red: 0.10, green: 0.09, blue: 0.09)
    static let bg3 = Color(red: 0.14, green: 0.12, blue: 0.12)
    static let line = Color(red: 0.18, green: 0.16, blue: 0.16)
    static let text = Color(red: 0.95, green: 0.93, blue: 0.93)
    static let muted = Color(red: 0.60, green: 0.58, blue: 0.58)
    static let accent = Color(red: 0.98, green: 0.70, blue: 0.51)
    static let blue = Color(red: 0.42, green: 0.63, blue: 0.96)
    static let green = Color(red: 0.50, green: 0.85, blue: 0.56)
    static let red = Color(red: 0.88, green: 0.42, blue: 0.45)
    static let yellow = Color(red: 0.96, green: 0.66, blue: 0.26)
    static let code = Color(red: 0.055, green: 0.05, blue: 0.05)
}

struct GlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 22
    var tint: Color? = nil

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(OCTheme.line.opacity(0.8), lineWidth: 0.5)
                )
        }
    }
}

extension View {
    func glassSurface(cornerRadius: CGFloat = 22) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius))
    }

    func ocCard(cornerRadius: CGFloat = 18) -> some View {
        background(OCTheme.bg2, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(OCTheme.line, lineWidth: 0.7)
            )
    }
}

struct OpenCodeMark: View {
    var size: CGFloat = 42

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(OCTheme.text)
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .fill(OCTheme.bg)
                .frame(width: size * 0.50, height: size * 0.70)
        }
        .frame(width: size * 0.80, height: size)
    }
}

struct MarkdownChunk: Identifiable {
    let id = UUID()
    let code: Bool
    let lang: String
    let text: String
}

func markdownChunks(_ input: String) -> [MarkdownChunk] {
    var chunks: [MarkdownChunk] = []
    var rest = input
    while let start = rest.range(of: "```") {
        let before = String(rest[..<start.lowerBound])
        if !before.isEmpty { chunks.append(MarkdownChunk(code: false, lang: "", text: before)) }
        rest = String(rest[start.upperBound...])
        guard let end = rest.range(of: "```") else {
            chunks.append(MarkdownChunk(code: true, lang: "", text: rest))
            rest = ""
            break
        }
        let block = String(rest[..<end.lowerBound])
        rest = String(rest[end.upperBound...])
        var lang = ""
        var code = block
        if let newline = block.firstIndex(of: "\n") {
            lang = String(block[..<newline]).trimmingCharacters(in: .whitespaces)
            code = String(block[block.index(after: newline)...])
        }
        chunks.append(MarkdownChunk(code: true, lang: lang, text: code))
    }
    if !rest.isEmpty { chunks.append(MarkdownChunk(code: false, lang: "", text: rest)) }
    return chunks
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(markdownChunks(text)) { chunk in
                if chunk.code {
                    CodeBlockView(code: chunk.text, language: chunk.lang)
                } else {
                    let parsed = (try? AttributedString(
                        markdown: chunk.text,
                        options: .init(interpretedSyntax: .full)
                    )) ?? AttributedString(chunk.text)
                    Text(parsed)
                        .font(.system(size: 15))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct CodeBlockView: View {
    let code: String
    let language: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(OCTheme.muted)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(copied ? OCTheme.green : OCTheme.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OCTheme.bg3.opacity(0.55))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(OCTheme.text)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(OCTheme.code)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(OCTheme.line, lineWidth: 0.7)
        )
    }
}

struct ToolCardView: View {
    let part: NativePart
    @State private var expanded = false

    private var icon: String {
        switch part.toolName {
        case "bash": return "terminal"
        case "read", "list": return "doc.text.magnifyingglass"
        case "write", "edit", "delete", "move", "mkdir": return "pencil.and.scribble"
        case "grep", "glob": return "magnifyingglass"
        case "webfetch": return "globe"
        case "todowrite": return "checklist"
        default: return "wrench.and.screwdriver"
        }
    }

    private var title: String {
        switch part.toolName {
        case "bash": return "Команда"
        case "read": return "Чтение"
        case "write": return "Запись"
        case "edit": return "Правка"
        case "list": return "Список"
        case "grep": return "Поиск"
        case "glob": return "Файлы"
        case "webfetch": return "Загрузка"
        case "todowrite": return "Задачи"
        case "delete": return "Удаление"
        case "move": return "Перемещение"
        case "mkdir": return "Папка"
        default: return part.toolName
        }
    }

    private var statusColor: Color {
        if part.status == "error" { return OCTheme.red }
        if part.status == "running" || part.status == "pending" { return OCTheme.yellow }
        return OCTheme.green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(OCTheme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(OCTheme.text)
                        if !part.inputSummary.isEmpty {
                            Text(part.inputSummary)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(OCTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if part.status == "running" || part.status == "pending" {
                        ProgressView().controlSize(.mini).tint(OCTheme.accent)
                    } else {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(OCTheme.muted)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !part.inputSummary.isEmpty {
                        Text(part.inputSummary)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(OCTheme.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !part.output.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(part.output)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(OCTheme.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 280)
                    }
                    if !part.diff.isEmpty {
                        Text(part.diff)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OCTheme.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !part.error.isEmpty {
                        Text(part.error)
                            .font(.system(size: 12))
                            .foregroundStyle(OCTheme.red)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(OCTheme.bg2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(part.status == "error" ? OCTheme.red.opacity(0.5) : OCTheme.line, lineWidth: 0.7)
        )
    }
}

struct MessageView: View {
    let message: NativeMessage

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 42)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.parts) { part in
                        if part.kind == .text {
                            Text(part.text)
                                .font(.system(size: 15))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if part.kind == .other {
                            Label(part.text, systemImage: "paperclip")
                                .font(.system(size: 12))
                                .foregroundStyle(OCTheme.muted)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(OCTheme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(OCTheme.accent.opacity(0.22), lineWidth: 0.7)
                )
            }
            .padding(.vertical, 3)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.parts) { part in
                    switch part.kind {
                    case .text:
                        MarkdownText(text: part.text)
                    case .reasoning:
                        DisclosureGroup {
                            Text(part.text)
                                .font(.system(size: 13))
                                .foregroundStyle(OCTheme.muted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        } label: {
                            Label("Размышления", systemImage: "brain")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(OCTheme.muted)
                        }
                        .tint(OCTheme.accent)
                    case .tool:
                        ToolCardView(part: part)
                    case .other:
                        Label(part.text, systemImage: "square.stack.3d.up")
                            .font(.system(size: 12))
                            .foregroundStyle(OCTheme.muted)
                    }
                }
                if !message.error.isEmpty {
                    Text(message.error)
                        .font(.system(size: 13))
                        .foregroundStyle(OCTheme.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(OCTheme.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                if !message.model.isEmpty || message.tokens > 0 || message.duration > 0 {
                    HStack(spacing: 8) {
                        if !message.model.isEmpty { Text(message.model) }
                        if message.tokens > 0 { Text("\(message.tokens) tok") }
                        if message.duration > 0 { Text(String(format: "%.1fs", message.duration)) }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(OCTheme.muted.opacity(0.85))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
    }
}