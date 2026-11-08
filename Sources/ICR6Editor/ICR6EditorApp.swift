import SwiftUI

@main
struct ICR6EditorApp: App {
    @State private var model = EditorModel()
    @NSApplicationDelegateAdaptor(EditorAppDelegate.self) private var delegate

    var body: some Scene {
        Window("IC-R6 メモリーエディタ", id: "editor") {
            EditorView(model: model)
                .frame(minWidth: 980, minHeight: 625)
                .onAppear { delegate.model = model }
                .onOpenURL { model.openFile($0) }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("ファイルを開く…", action: model.openFile)
                    .keyboardShortcut("o")
                    .disabled(model.busy)
                Button("ファイルに保存…", action: model.saveFile)
                    .keyboardShortcut("s")
                    .disabled(model.busy || model.image == nil)
                Divider()
                Button("バックアップを表示", action: model.revealBackups)
            }
        }
    }
}

@MainActor
final class EditorAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: EditorModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true {
            NSSound.beep()
            return .terminateCancel
        }
        return model?.confirmDiscard() == false ? .terminateCancel : .terminateNow
    }
}
