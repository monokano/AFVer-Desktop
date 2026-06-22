import AppKit
import SwiftUI
import Combine

// MARK: - 設定値

/// 「フォルダのダブルクリック」時の挙動（設定ウィンドウのラジオボタン）。
/// `UserDefaults("folderDoubleClickAction")` に rawValue で永続化する（既定 `.expand`＝従来仕様）。
enum FolderDoubleClickAction: String, CaseIterable, Identifiable {
    /// 展開／閉じる（既定。リスト行のフォルダをその場で開閉する）
    case expand
    /// 新規ウインドウで表示（フォルダの中身を別ウインドウに開く。コンテキストメニューと同経路）
    case newWindow
    var id: String { rawValue }
}

// MARK: - AppSettings（全ウインドウ共有の設定ストア）

/// アプリ全体で共有する設定。**単一インスタンス**を設定ウインドウ（`SettingsView`）と
/// 各リストウインドウ（`ContentView`）の両方が `@ObservedObject` で監視する。
///
/// `@AppStorage` を別ウインドウ間で使うと、手動ホストした `NSHostingController`（設定ウインドウ）の
/// 書き込みが `ContentView` 側の `@AppStorage` 監視を発火させず**伝播しない**ことがある（実機で確認）。
/// 同一オブジェクトの `@Published` なら全 `ContentView` へ確実にライブ反映される。値は `didSet` で
/// UserDefaults に永続化する（次回起動時に復元）。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let doubleClickKey = "folderDoubleClickAction"
    private static let stripeKey = "listBackgroundStripe"
    private static let kindMismatchRedTextKey = "kindMismatchRedText"
    private static let showStatusBarKey = "showStatusBar"
    private static let detectPhotoshopVersionKey = "detectPhotoshopVersion"

    @Published var folderDoubleClickAction: FolderDoubleClickAction {
        didSet { UserDefaults.standard.set(folderDoubleClickAction.rawValue, forKey: Self.doubleClickKey) }
    }
    /// ウインドウ下部のステータスバー（項目数・アプリ別ドット集計）を表示するか（既定 true＝Finder 同様）。
    /// 全ウインドウ共通。「表示」メニューのトグルで切り替え、終了後も保持する。
    @Published var showStatusBar: Bool {
        didSet { UserDefaults.standard.set(showStatusBar, forKey: Self.showStatusBarKey) }
    }
    @Published var listBackgroundStripe: Bool {
        didSet { UserDefaults.standard.set(listBackgroundStripe, forKey: Self.stripeKey) }
    }
    /// 拡張子偽装の行で、種類名も赤文字にするか（既定 true）。
    /// ON（既定）＝先頭の警告記号 ⚠ ＋種類名の両方を赤／OFF＝⚠ だけ赤・種類名は通常色。
    @Published var kindMismatchRedText: Bool {
        didSet { UserDefaults.standard.set(kindMismatchRedText, forKey: Self.kindMismatchRedTextKey) }
    }
    /// Photoshop ネイティブ版（PSD/PSB の cinf・編集機能保持PDF の埋め込み cinf）を検出するか（既定 true＝ON）。
    /// cinf 走査は重い（PSD は最悪 Layer&Mask 全走査、編集PDF は inflate）ため既定で省く。種類判定は常に行う。
    /// ※ fast モードでは本設定に関わらず常にスキップ（実効判定は ContentView 側で `full かつ ON` に合成）。
    /// 切替時は全ウインドウの取得済みリストを再取得して即時反映する（`AppDelegate.refetchVersionsAllWindows`）。
    @Published var detectPhotoshopVersion: Bool {
        didSet {
            UserDefaults.standard.set(detectPhotoshopVersion, forKey: Self.detectPhotoshopVersionKey)
            AppDelegate.shared?.refetchVersionsAllWindows()
        }
    }

    private init() {
        folderDoubleClickAction = FolderDoubleClickAction(
            rawValue: UserDefaults.standard.string(forKey: Self.doubleClickKey) ?? "") ?? .expand
        listBackgroundStripe = UserDefaults.standard.bool(forKey: Self.stripeKey)   // 未設定は false（既定 OFF）
        // 未設定（初回起動）は true＝既定で種類名も赤。object(forKey:) が nil のときだけ既定 true を採る。
        kindMismatchRedText = (UserDefaults.standard.object(forKey: Self.kindMismatchRedTextKey) as? Bool) ?? true
        // 未設定（初回起動）は true＝既定で表示。object(forKey:) が nil のときだけ既定 true を採る。
        showStatusBar = (UserDefaults.standard.object(forKey: Self.showStatusBarKey) as? Bool) ?? true
        // 未設定（初回起動）は true＝既定 ON。object(forKey:) が nil のときだけ既定 true を採る。
        detectPhotoshopVersion = (UserDefaults.standard.object(forKey: Self.detectPhotoshopVersionKey) as? Bool) ?? true
    }
}

// MARK: - SettingsView（設定ウィンドウの中身）

/// 設定ウィンドウの内容。共有 `AppSettings` 直結で即時反映する（OK/キャンセルは設けない＝macOS の設定標準）。
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // フォルダのダブルクリック（ラジオボタン）
            VStack(alignment: .leading, spacing: 6) {
                Text("Folder Double-Click")
                Picker("Folder Double-Click", selection: $settings.folderDoubleClickAction) {
                    Text("Expand / Collapse").tag(FolderDoubleClickAction.expand)
                    Text("Open in New Window").tag(FolderDoubleClickAction.newWindow)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(.leading, 8)
            }

            Divider()

            // リストの背景をストライプにする（チェックボックス）
            Toggle(isOn: $settings.listBackgroundStripe) {
                Text("Stripe list background")
            }

            // 拡張子偽装時に種類名も赤文字にする（チェックボックス）
            Toggle(isOn: $settings.kindMismatchRedText) {
                Text("Show kind in red for disguised extensions")
            }

            // Photoshop ネイティブ版（PSD/PSB・編集機能保持PDF）を検出する（チェックボックス・既定 OFF）
            Toggle(isOn: $settings.detectPhotoshopVersion) {
                Text("Detect Photoshop version")
            }
        }
        .padding(20)
        .frame(width: 340, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - SettingsWindowController

/// 設定ウィンドウを表示する。Help/ChangeLog と同じく `AppDelegate` が保持し、
/// アプリメニュー「設定…」と Dock メニュー「設定…」の両方から `openSettings()` 経由で開く。
/// 中身は SwiftUI の `SettingsView` を `NSHostingController` で載せる（リサイズ不可の小パネル）。
final class SettingsWindowController: NSObject {

    private var window: NSWindow?

    func show() {
        // すでに表示中なら前面に出すだけ
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView())
        let win = NSWindow(contentViewController: hosting)   // SwiftUI の fitting サイズに合わせる
        win.styleMask = [.titled, .closable]                 // リサイズ不可・最小化不可
        win.title = String(localized: "Settings")
        win.isReleasedWhenClosed = false
        win.center()

        window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
}
