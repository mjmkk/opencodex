//
//  RunestoneCodeView.swift
//  CodexWorker
//
//  基于 Runestone 的只读代码查看器（支持语法高亮、行号、双向滚动）
//

import Foundation
import Runestone
import SwiftUI
import TreeSitterBashRunestone
import TreeSitterCSSRunestone
import TreeSitterHTMLRunestone
import TreeSitterJSONRunestone
import TreeSitterJavaScriptRunestone
import TreeSitterMarkdownRunestone
import TreeSitterPythonRunestone
import TreeSitterSwiftRunestone
import TreeSitterTOMLRunestone
import TreeSitterTSXRunestone
import TreeSitterTypeScriptRunestone
import TreeSitterYAMLRunestone
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public struct RunestoneCodeView: UIViewRepresentable {
    public let content: String
    public let language: String
    public let focusLine: Int?
    public let isEditable: Bool
    public let onContentChanged: ((String) -> Void)?

    public init(
        content: String,
        language: String,
        focusLine: Int?,
        isEditable: Bool = false,
        onContentChanged: ((String) -> Void)? = nil
    ) {
        self.content = content
        self.language = language
        self.focusLine = focusLine
        self.isEditable = isEditable
        self.onContentChanged = onContentChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(onContentChanged: onContentChanged)
    }

    public func makeUIView(context: Context) -> TextView {
        let textView = context.coordinator.textView
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.editorDelegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.showLineNumbers = true
        textView.lineSelectionDisplayType = .line
        textView.isLineWrappingEnabled = false
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.smartQuotesType = .no
        textView.spellCheckingType = .no
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 8, bottom: 16, right: 16)
        textView.verticalOverscrollFactor = 0.2
        textView.horizontalOverscrollFactor = 0.2
        textView.backgroundColor = backgroundColor(for: context.environment.colorScheme)
        return textView
    }

    public func updateUIView(_ uiView: TextView, context: Context) {
        uiView.backgroundColor = backgroundColor(for: context.environment.colorScheme)
        uiView.isEditable = isEditable
        context.coordinator.onContentChanged = onContentChanged

        let languageKey = normalizedLanguageKey(language)
        let shouldApplyExternalState =
            context.coordinator.lastLanguageKey != languageKey ||
            context.coordinator.lastEditable != isEditable ||
            (content != context.coordinator.lastContent && content != uiView.text)

        if shouldApplyExternalState {
            context.coordinator.isApplyingExternalState = true
            let state = makeTextViewState(content: content, languageKey: languageKey)
            uiView.setState(state)
            context.coordinator.lastContent = content
            context.coordinator.lastLanguageKey = languageKey
            context.coordinator.lastEditable = isEditable
            context.coordinator.lastFocusLine = nil
            context.coordinator.isApplyingExternalState = false
        }

        guard !isEditable else { return }
        guard focusLine != context.coordinator.lastFocusLine else {
            return
        }
        context.coordinator.lastFocusLine = focusLine

        guard let focusLine, focusLine > 0 else {
            return
        }
        let location = textLocation(forLine: focusLine, in: content)
        let range = NSRange(location: location, length: 0)
        uiView.selectedRange = range
        uiView.scrollRangeToVisible(range)
    }

    private func makeTextViewState(content: String, languageKey: String) -> TextViewState {
        let theme = DefaultTheme()
        if let treeLanguage = treeSitterLanguage(for: languageKey) {
            return TextViewState(text: content, theme: theme, language: treeLanguage)
        }
        return TextViewState(text: content, theme: theme)
    }

    private func normalizedLanguageKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func treeSitterLanguage(for languageKey: String) -> TreeSitterLanguage? {
        switch languageKey {
        case "swift":
            return .swift
        case "javascript", "js", "mjs", "cjs", "jsx":
            return languageKey == "jsx" ? .jsx : .javaScript
        case "typescript", "ts":
            return .typeScript
        case "tsx":
            return .tsx
        case "json":
            return .json
        case "yaml", "yml":
            return .yaml
        case "toml":
            return .toml
        case "markdown", "md":
            return .markdown
        case "bash", "shell", "sh", "zsh":
            return .bash
        case "python", "py":
            return .python
        case "css", "scss":
            return .css
        case "html", "htm":
            return .html
        default:
            return nil
        }
    }

    private func textLocation(forLine line: Int, in content: String) -> Int {
        guard line > 1 else { return 0 }
        // 单次线性扫描收集行首偏移，避免对每一行重复 range(of:) 导致 O(n²) 复杂度。
        var offset = content.startIndex
        var currentLine = 1
        while offset < content.endIndex {
            if currentLine >= line {
                return content.distance(from: content.startIndex, to: offset)
            }
            if content[offset] == "\n" {
                currentLine += 1
            }
            content.formIndex(after: &offset)
        }
        return content.count
    }

    private func backgroundColor(for colorScheme: ColorScheme) -> UIColor {
        colorScheme == .dark
            ? UIColor.secondarySystemBackground
            : UIColor.systemBackground
    }

    @MainActor
    public final class Coordinator: @MainActor TextViewDelegate {
        fileprivate let textView = TextView()
        fileprivate var lastContent = ""
        fileprivate var lastLanguageKey = ""
        fileprivate var lastEditable = false
        fileprivate var lastFocusLine: Int?
        fileprivate var isApplyingExternalState = false
        fileprivate var onContentChanged: ((String) -> Void)?

        init(onContentChanged: ((String) -> Void)?) {
            self.onContentChanged = onContentChanged
        }

        public func textViewDidChange(_ textView: TextView) {
            guard !isApplyingExternalState else { return }
            let latestText = textView.text
            guard latestText != lastContent else { return }
            lastContent = latestText
            onContentChanged?(latestText)
        }
    }
}
