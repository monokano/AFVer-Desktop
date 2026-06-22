//
// 新規ウインドウのサイズを最前面ウインドウのサイズに合わせる
//

import SwiftUI

struct WindowSizeMatcher: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return WindowSizeView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class WindowSizeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = self.window else { return }
        window.tabbingMode = .disallowed
        // 状態復元を無効化する。本アプリはフォルダ内容を保存しない（スナップショット仕様）ため、
        // 終了時のウインドウを次回起動で復元すると「空のウインドウ」が蘇ってしまう。
        // 位置・サイズの保存（NSWindow Frame 自動保存）は復元とは別系統なので影響しない。
        window.isRestorable = false
        // lastWindowSize は windowDidBecomeMain でしか更新されないため、起動直後の初回は nil。
        // その場合は「この新規窓を開いた元の主ウインドウ」のサイズへフォールバックする。
        if let size = AppDelegate.shared?.referenceContentSize(excluding: window) {
            window.setContentSize(size)
        }
        // ディスプレイ外・Dock への食い込みを防ぐ。サイズ適用後に可視領域へ収める
        //（基準窓が画面いっぱい／端寄りでも、新規窓は必ず画面内に収まる）。
        AppDelegate.shared?.constrainToVisibleFrame(window)
    }
}
