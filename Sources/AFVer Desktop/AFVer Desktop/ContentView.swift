import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers
import DiskArbitration   // 光学ディスク判定（CD/DVD/BD）

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var model = FileListModel()
    @Environment(\.openWindow) private var openWindow
    // 設定ウインドウと共有する単一インスタンス。変更でこの View が再評価され OutlineList へライブ反映される
    // （@AppStorage はクロスウインドウ伝播が不安定だったため共有 ObservableObject に変更）。
    @ObservedObject private var settings = AppSettings.shared
    /// 「新規ウインドウで表示」から開かれた場合の初期フォルダ（通常起動は nil）
    let initialFolder: URL?
    /// Dock へのファイルドロップから開かれた場合の初期ファイル群（フラット表示。通常起動は nil）
    let initialDroppedFiles: [URL]?

    init(initialFolder: URL? = nil, initialDroppedFiles: [URL]? = nil) {
        self.initialFolder = initialFolder
        self.initialDroppedFiles = initialDroppedFiles
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.rootItems.isEmpty && !model.isLoading {
                    DropPlaceholder(isTargeted: model.isDropTargeted)
                } else {
                    listView
                }

                if model.isLoading {
                    ProgressOverlay(
                        progress: model.loadProgress,
                        isCancellable: model.isCancellable,
                        onCancel: { model.cancelLoading() }
                    )
                }
            }

            // ステータスバー（Finder 風）。設定ONかつ内容ありのときだけ下部に出す。
            if settings.showStatusBar && !model.rootItems.isEmpty {
                StatusBarView(summary: model.statusSummary)
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        // ファイルメニュー「Finderに表示」(⌘R) が最前面ウィンドウのモデルを参照できるようにする
        .focusedSceneValue(\.fileListModel, model)
        // バージョン精度メニューのチェックを「そのウィンドウの実効モード」に追従させる
        // （光学ディスク自動高速を含む。model は @StateObject なので versionDetail 変化で再描画→ライブ更新）
        .focusedSceneValue(\.effectiveVersionDetail, model.versionDetail)
        .background(WindowSizeMatcher())
        .background(WindowAccessor { window in
            model.hostWindow = window
            // 複数項目ドロップの整列中は新規窓を隠す（内容の有無に関わらず）。
            AppDelegate.shared?.hideDuringDropIfNeeded(window, model: model)
            // hostWindow が解決したので出そろい判定（rootURL が先に来ていた場合の取りこぼし対策）。
            AppDelegate.shared?.noteBatchContentReady()
        })
        .background(ToolbarConfigurator(
            folderURL: model.isFlatDrop ? nil : model.rootURL,
            hasContent: !model.rootItems.isEmpty,
            isFlatList: model.isFlatDrop && !model.rootItems.isEmpty,
            versionOn: model.showVersionColumn,
            onToggleVersion: { model.setShowVersion($0) },
            versionDetail: model.versionDetail,
            onSetVersionDetail: { model.setVersionDetail($0) },
            onExpandAll: { model.expandAll() },
            onCollapseAll: { model.collapseAll() },
            onAdjustColumns: { model.adjustColumnWidths() },
            onPrint: { model.printList() }
        ))
        .onDrop(of: [.fileURL], isTargeted: $model.isDropTargeted) { providers in
            model.handleDrop(providers: providers)
            return true
        }
        .onAppear {
            if let initialFolder {
                model.showFolder(initialFolder)
            } else if let initialDroppedFiles {
                model.showDroppedItems(initialDroppedFiles)
            }
            registerDockDropHandler()
            AppDelegate.shared?.registerModel(model)
        }
    }

    /// Dockアイコンへのドロップの受け口を登録する（最後に現れたウィンドウが担当）。
    /// このウィンドウが空ならそこに表示し、表示中なら新規ウインドウを開く。
    /// 起動直後（登録前）に届いた保留分もここで消化する。
    private func registerDockDropHandler() {
        guard let delegate = AppDelegate.shared else { return }

        delegate.openDroppedFolder = { [weak model] url in
            if let model, model.rootURL == nil, model.rootItems.isEmpty {
                model.showFolder(url)
            } else {
                openWindow(id: "folder", value: FolderWindowValue(url: url))
            }
        }
        delegate.openDroppedFiles = { [weak model] urls in
            if let model, model.rootURL == nil, model.rootItems.isEmpty {
                model.showDroppedItems(urls)
            } else {
                openWindow(id: "files", value: DroppedFilesWindowValue(urls: urls))
            }
        }

        // ウインドウへの複数・混在ドロップを「フォルダは各ウインドウ／ファイルは1枚」に振り分ける
        //（Dock・右クリックCと同じ）。このウインドウが空なら先頭を再利用して空ウインドウを残さない。
        model.onRouteMultipleDropped = { [weak model] urls in
            guard let model else { return }
            let isPlainFolder: (URL) -> Bool = { url in
                let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
                return rv?.isDirectory == true && rv?.isPackage != true && rv?.isSymbolicLink != true
            }
            var folders = urls.filter(isPlainFolder)
            let files = urls.filter { !isPlainFolder($0) }

            // 空ウインドウ（プレースホルダ）なら先頭をここで再利用する（フォルダ優先）。
            var filesConsumed = false
            if model.rootURL == nil, model.rootItems.isEmpty {
                if !folders.isEmpty {
                    model.showFolder(folders.removeFirst())
                } else if !files.isEmpty {
                    model.showDroppedItems(files)
                    filesConsumed = true
                }
            }

            // 新規に開く内容ウインドウ枚数（フォルダ各1枚＋ファイル群1枚）。2枚以上はカスケード整列。
            let newWindowCount = folders.count + ((!files.isEmpty && !filesConsumed) ? 1 : 0)
            if newWindowCount >= 2 {
                AppDelegate.shared?.beginProgrammaticWindowBatch(expectedContentWindowCount: newWindowCount)
            }
            for url in folders {
                openWindow(id: "folder", value: FolderWindowValue(url: url))
            }
            if !files.isEmpty, !filesConsumed {
                openWindow(id: "files", value: DroppedFilesWindowValue(urls: files))
            }
        }

        // 起動直後（ハンドラ登録前）に届いた保留分を消化する。
        var folders = delegate.pendingFolderURLs
        let files = delegate.pendingDroppedFiles
        delegate.pendingFolderURLs = []
        delegate.pendingDroppedFiles = []
        guard !folders.isEmpty || !files.isEmpty else { return }

        // この空ウィンドウは 1 つだけ再利用できる。フォルダ優先（従来挙動）、無ければファイル群。
        let canReuse = (initialFolder == nil && initialDroppedFiles == nil
                        && model.rootURL == nil && model.rootItems.isEmpty)
        var filesConsumed = false
        if canReuse {
            if !folders.isEmpty {
                model.showFolder(folders.removeFirst())
            } else if !files.isEmpty {
                model.showDroppedItems(files)
                filesConsumed = true
            }
        }
        // 残りのフォルダは 1 つずつ新規ウインドウへ
        for url in folders {
            openWindow(id: "folder", value: FolderWindowValue(url: url))
        }
        // ファイル群が未消化なら、まとめて 1 枚の新規フラットウインドウへ
        if !files.isEmpty, !filesConsumed {
            openWindow(id: "files", value: DroppedFilesWindowValue(urls: files))
        }
    }

    private var listView: some View {
        OutlineList(
            columns: model.displayColumns,
            rootItems: $model.rootItems,
            sortState: $model.sortState,
            columnWidths: model.columnWidths,
            versionRefreshToken: model.versionRefreshToken,
            folderDoubleClickOpensNewWindow: settings.folderDoubleClickAction == .newWindow,
            stripeBackground: settings.listBackgroundStripe,
            kindMismatchRedText: settings.kindMismatchRedText,
            onColumnWidthChanged: { id, w in
                // 列幅 KVO は reconcileColumns（updateNSView 内）の setFrame/tc.width 変更で
                // 同期発火しうる。columnWidths セッターは @AppStorage 書き込み＝objectWillChange
                // なので、ビュー更新中に書くと「Publishing changes from within view updates」
                // 警告になる。次ランループへ遅らせてサイクル外で書く（KVO は実変化時のみ発火＝ループしない）。
                DispatchQueue.main.async { model.columnWidths[id] = w }
            },
            onColumnOrderChanged: { ids in model.setVisibleColumnOrder(ids) },
            onExpandItem: { item, done in model.expandItem(item, completion: done) },
            onSelectionChanged: { model.selectedItem = $0 },
            onSelectionCountChanged: { model.selectedCount = $0 },
            onVisibleSummaryChanged: { total, counts in
                // 同値での @Published 書き込み（→ 再評価 → 再 push）の往復を避けるため変化時のみ更新。
                if model.visibleTotal != total { model.visibleTotal = total }
                if model.visibleFamilyCounts != counts { model.visibleFamilyCounts = counts }
            },
            onRegisterPrintRowProvider: { model.printRowProvider = $0 },
            onRegisterTreeActions: { model.treeActions = $0 },
            onOpenInNewWindow: { url in
                openWindow(id: "folder", value: FolderWindowValue(url: url))
            },
            onOpenItemsInNewWindow: { urls in
                openWindow(id: "files", value: DroppedFilesWindowValue(urls: urls))
            },
            onBeginNewWindowBatch: { count in
                AppDelegate.shared?.beginProgrammaticWindowBatch(expectedContentWindowCount: count)
            }
        )
        // safe area を尊重し、リストをツールバー下にきっちり収める。
        // 以前は .ignoresSafeArea() で不透明なリストを天井まで広げていたが、
        // macOS Tahoe(26) の Liquid Glass ツールバーは透過率が高く、潜り込んだ行が
        // 透けて二重写しに見える（キモい表示）。上端をツールバー下で止めて透けを防ぐ。
    }
}

// MARK: - StatusBarView

/// ウインドウ下部のステータスバー（高さ28px）。Finder 風に中央寄せで、
/// 「N項目」（選択時は「N項目中のM項目を選択」）とアプリ系統別のカラードット集計を並べる。
private struct StatusBarView: View {
    let summary: FileListModel.StatusSummary

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 18) {
                Text(countText)
                ForEach(summary.perFamily, id: \.family) { entry in
                    // ドット集計はドット＋番号のみ（「項目」なし・ドットと番号の間は 4pt）。
                    HStack(spacing: 4) {
                        Group {
                            if entry.family == .epsOther {
                                Circle().strokeBorder(Color(nsColor: entry.family.markerColor), lineWidth: 1.5)
                            } else {
                                Circle().fill(Color(nsColor: entry.family.markerColor))
                            }
                        }
                        .frame(width: 8, height: 8)
                        Text(String(entry.count))
                    }
                }
            }
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 27)
        }
        .frame(height: 28)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// 左端のテキスト。未選択＝「123項目」／選択＝「123項目中の3項目を選択」（和欧間スペースなし）。
    private var countText: String {
        if summary.selected > 0 {
            return String(format: String(localized: "%1$lld of %2$lld selected"),
                          Int64(summary.selected), Int64(summary.total))
        }
        return String(format: String(localized: "%lld items"), Int64(summary.total))
    }
}

// MARK: - WindowAccessor

/// 自身が載っている NSWindow を解決してコールバックする不可視ビュー。
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onResolve = onResolve
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onResolve: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }
    }
}

// MARK: - DropPlaceholder

private struct DropPlaceholder: View {
    let isTargeted: Bool

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            VStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Drop folders or files")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.clear,
                    lineWidth: 3
                )
                .padding(4)
        )
    }
}

// MARK: - ProgressOverlay

private struct ProgressOverlay: View {
    let progress: Double?
    let isCancellable: Bool
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                if let p = progress {
                    ProgressView(value: p)
                        .frame(width: 200)
                } else {
                    ProgressView()
                }
                if isCancellable {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.bordered)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - FileListModel

@MainActor
final class FileListModel: ObservableObject {
    @Published var rootItems: [FileItem] = []
    @Published var rootURL: URL? = nil {
        didSet {
            // 内容が確定（rootURL 非 nil）したら AppDelegate に通知する。
            // ・複数項目ドロップの整列中は隠したまま（出そろったら一斉表示）／・通常は即表示。
            if rootURL != nil { AppDelegate.shared?.noteContentWindowReady(hostWindow) }
        }
    }
    /// ファイル等を「落とした項目そのもの」として表示中か（true のときタイトル空白・印刷ヘッダは日時のみ）。
    /// 単一の素のフォルダを通常表示しているときは false。
    @Published var isFlatDrop = false
    @Published var sortState = SortState(columnID: "name", ascending: true)
    @Published var isLoading = false
    @Published var loadProgress: Double? = nil
    @Published var isCancellable = false
    @Published var isDropTargeted = false
    /// スイッチON で「バージョン」列を表示する（状態は終了時に保存し次回起動時に復元）
    private static let showVersionKey = "showVersionColumn"
    @Published var showVersionColumn = UserDefaults.standard.bool(forKey: showVersionKey)
    /// バージョン取得の精度（詳細=xref / 高速=ヘッダのみ）。終了時に保存し次回起動時に復元
    private static let versionDetailKey = "versionDetail"
    @Published var versionDetail: VersionDetail =
        VersionDetail(rawValue: UserDefaults.standard.string(forKey: versionDetailKey) ?? "") ?? .full

    /// バージョン取得の並列数（既定32）。`defaults write com.tama-san.AFVerDesktop versionFetchConcurrency N`
    /// で 1〜64 に上書きできる（再起動で反映。範囲外・未設定は 32）。
    /// 実測 2026-06-16: DVD-R / ネットワーク(LAN) / リムーバブルSSD いずれも並列が有効で、N が大きいほど
    /// 速い（N=1<4<16<32<64）。ただし逓減で 32→64 の差はわずか。並列で各ファイルの I/O 待ちを別ファイルの
    /// CPU 解析と重ねられるため（特にレイテンシの高いネットワーク/光学で有効）。「光学はヘッド1つだから
    /// 直列が速いはず」の当初仮説は誤りで、「遅いメディアは並列度を下げる」案（旧 HANDOFF §4 TODO）は破棄。
    /// 既定は逓減と同時メモリ負荷のバランスで 32 を採用（最速を要するなら defaults で 64 に。1ファイル内の
    /// FileHandle は逐次オープンのため瞬間 FD は ~N 個で、64 でも安全）。
    private static var versionFetchConcurrency: Int {
        let v = UserDefaults.standard.integer(forKey: "versionFetchConcurrency")
        return (1...64).contains(v) ? v : 32
    }
    /// バージョン取得が進むたびに増やしてリスト再描画を促すトークン
    @Published var versionRefreshToken = 0
    /// 現在の選択行数（ステータスバー表示用。OutlineList の選択変更で更新）
    @Published var selectedCount = 0
    /// 現在「表示されている行数」（展開状態を反映。ステータスバーの総数表示用）
    @Published var visibleTotal = 0
    /// 表示中行のアプリ系統別ドット数（展開状態を反映。バージョン列ON時のドット集計用）
    @Published var visibleFamilyCounts: [AppFamily: Int] = [:]
    /// このモデルを表示しているウインドウ（ドロップ後の空ウインドウ掃除に使う）
    weak var hostWindow: NSWindow?
    /// リストで現在選択中のアイテム（ファイルメニュー「Finderに表示」用）
    var selectedItem: FileItem?
    /// 印刷用：現在の表示行スナップショットを返すプロバイダ（OutlineList が登録する）
    var printRowProvider: (() -> [PrintRow])?
    /// ツリー操作（すべて展開／すべて閉じる。OutlineList が登録する）
    var treeActions: OutlineTreeActions?
    /// 複数・混在のウインドウドロップを「フォルダは各ウインドウ／ファイルは1枚」に振り分ける。
    /// 新規ウインドウを開くのは View 側のため ContentView が登録する（Dock・右クリックCと同じ部品）。
    var onRouteMultipleDropped: (([URL]) -> Void)?

    @AppStorage("columnWidths") private var columnWidthsData: Data = Data()
    var columnWidths: [String: CGFloat] {
        get { (try? JSONDecoder().decode([String: CGFloat].self, from: columnWidthsData)) ?? [:] }
        set { columnWidthsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// 列の並び順（名前列を除く。終了後も保存し次回起動時に復元）。
    /// 既定はバージョン列を含む正準順＝変更日→サイズ→バージョン→種類。
    /// バージョン列は表示OFFのときも順序を温存しておき、再表示時に元の位置へ戻す。
    static let canonicalColumnOrder = ["date", "size", "version", "kind"]
    @AppStorage("columnOrder") private var columnOrderData: Data = Data()
    var columnOrder: [String] {
        get { (try? JSONDecoder().decode([String].self, from: columnOrderData)) ?? Self.canonicalColumnOrder }
        set { columnOrderData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    /// 未知IDを除き、欠けている正準列を末尾に補った安全な並び順。
    private var normalizedColumnOrder: [String] {
        var o = columnOrder.filter { Self.canonicalColumnOrder.contains($0) }
        for id in Self.canonicalColumnOrder where !o.contains(id) { o.append(id) }
        return o
    }
    /// ヘッダのドラッグで変わった「表示中の列順（名前列を除く）」を、非表示の列
    /// （OFF のバージョン列）の相対位置を保ったまま保存する。
    func setVisibleColumnOrder(_ visible: [String]) {
        let stored = normalizedColumnOrder
        let visibleSet = Set(visible)
        var it = visible.makeIterator()
        var result: [String] = []
        for id in stored {
            if visibleSet.contains(id) {
                if let next = it.next() { result.append(next) }
            } else {
                result.append(id)   // 非表示の列はその位置に温存
            }
        }
        while let extra = it.next() { result.append(extra) }
        for id in visible where !result.contains(id) { result.append(id) }
        if result != columnOrder {
            objectWillChange.send()
            columnOrder = result
        }
    }

    private var loadTask: Task<Void, Never>?
    private var progressShowTask: Task<Void, Never>?
    private var versionFetchTask: Task<Void, Never>?

    static let columns: [OutlineListColumn] = [
        OutlineListColumn(id: "name",  title: String(localized: "Name"),          minWidth: 170, width: 240),
        OutlineListColumn(id: "date",  title: String(localized: "Date Modified"), minWidth: 100, width: 130),
        OutlineListColumn(id: "size",  title: String(localized: "Size"),          minWidth: 60,  width: 80, alignment: .right),
        OutlineListColumn(id: "kind",  title: String(localized: "Kind"),          minWidth: 80,  width: 240),
    ]

    /// 「バージョン」列（サイズと種類の間に挿入）
    static let versionColumn = OutlineListColumn(
        id: "version", title: String(localized: "Version"), minWidth: 100, width: 140)

    /// 実際に表示する列。名前列を先頭に固定し、以降は保存済みの並び順（`columnOrder`）に従う。
    /// バージョン列はスイッチON のときだけ表示する（OFF のときは順序のみ温存）。
    var displayColumns: [OutlineListColumn] {
        var defs = Dictionary(uniqueKeysWithValues: Self.columns.map { ($0.id, $0) })
        defs[Self.versionColumn.id] = Self.versionColumn
        let visibleIDs = ["name"] + normalizedColumnOrder.filter { id in
            id == "version" ? showVersionColumn : true
        }
        return visibleIDs.compactMap { defs[$0] }
    }

    // MARK: D&D

    /// 指定フォルダを表示する（「新規ウインドウで表示」用。ドロップと同じ読み込み）。
    func showFolder(_ url: URL) {
        loadFolder(url: url, cancellable: false)
    }

    func handleDrop(providers: [NSItemProvider]) {
        Task { @MainActor in
            // ドロップされた全項目の URL を順序保持で集める（複数ドロップ対応）
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.loadFileURL(from: provider) { urls.append(url) }
            }
            guard !urls.isEmpty else { return }
            self.route(droppedURLs: urls)
        }
    }

    /// NSItemProvider から file URL を取り出す（public.file-url）。取れなければ nil。
    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// ドロップ内容を振り分ける。
    /// ・単一の素のフォルダ／ボリューム → このウインドウに中身を一覧（loadFolder）
    /// ・単一のファイル等、または複数でもフォルダを含まない（ファイルのみ）→ このウインドウに
    ///   「ファイル一覧」として表示（showDroppedItems）
    /// ・素のフォルダを含む複数／混在 → フォルダは各ウインドウ・ファイルは1枚に分割
    ///   （onRouteMultipleDropped。Dock ドロップ・右クリック「新規ウインドウで表示」と同じ振り分け）
    private func route(droppedURLs urls: [URL]) {
        if urls.count == 1 {
            let rv = try? urls[0].resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if rv?.isDirectory == true, rv?.isPackage != true {
                loadFolder(url: urls[0], cancellable: false)
            } else {
                showDroppedItems(urls)
            }
            return
        }
        // 素のフォルダ（パッケージ・シンボリックリンクを除く）を含むかで分ける。
        let hasPlainFolder = urls.contains { url in
            let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            return rv?.isDirectory == true && rv?.isPackage != true && rv?.isSymbolicLink != true
        }
        if hasPlainFolder, let onRouteMultipleDropped {
            // フォルダを含む → フォルダは各ウインドウ・ファイルは1枚に分割（View 側が担当）。
            onRouteMultipleDropped(urls)
        } else {
            // ファイルのみ（またはハンドラ未登録）→ このウインドウに「ファイル一覧」として統合。
            showDroppedItems(urls)
        }
    }

    /// ドロップされたファイル等を「落とした項目そのもの」のフラットリストとして表示する。
    /// 親フォルダの列挙はせず、渡された URL を 1 行ずつ FileItem 化するだけ（即時・プログレス不要）。
    /// フォルダが混じっていれば展開可能な行として並ぶ（既定は閉じたまま）。
    func showDroppedItems(_ urls: [URL]) {
        loadTask?.cancel()
        isFlatDrop = true
        isLoading = false
        isCancellable = false
        loadProgress = nil

        // タイトル・印刷ヘッダは出さないが、CSV 既定名／光学・ネットワーク判定／空ウィンドウ判定に
        // 親フォルダの URL を使う（rootURL == nil は「空ウィンドウ」を意味するため非 nil を保つ）。
        let parent = urls[0].deletingLastPathComponent()
        rootURL = parent

        // 光学（CD/DVD/BD）・ネットワークは自動で「簡易」（loadFolder と同じ方針。親フォルダ基準で判定）
        let savedDetail = VersionDetail(rawValue:
            UserDefaults.standard.string(forKey: Self.versionDetailKey) ?? "") ?? .full
        let autoFast = (Self.autoFastOnOptical && Self.isOpticalVolume(parent))
                    || (Self.autoFastOnNetwork && Self.isNetworkVolume(parent))
        versionDetail = autoFast ? .fast : savedDetail

        // 明示ドロップは不可視属性でも表示する（includeHidden: true）
        rootItems = urls.compactMap { FileLoader.makeItem(url: $0, includeHidden: true) }
        startVersionFetch(for: rootItems)
    }

    // MARK: 読み込み

    private func loadFolder(url: URL, cancellable: Bool) {
        loadTask?.cancel()
        isFlatDrop = false
        rootItems = []
        rootURL = url

        // 光学（CD/DVD/BD）・ネットワーク（SMB/AFP/NFS 等）は遅いので自動で「簡易」にする
        // （そのウィンドウ限り・保存設定は変えない。光学／ネットワークは個別に defaults で無効化可）。
        // 非該当は保存設定（versionDetailKey）へ戻す。手動切替は setVersionDetail が別途保存する。
        // ※ versionDetail は @Published。startVersionFetch は冒頭で値を捕捉するのでここで決めておけば反映される。
        let savedDetail = VersionDetail(rawValue:
            UserDefaults.standard.string(forKey: Self.versionDetailKey) ?? "") ?? .full
        let autoFast = (Self.autoFastOnOptical && Self.isOpticalVolume(url))
                    || (Self.autoFastOnNetwork && Self.isNetworkVolume(url))
        versionDetail = autoFast ? .fast : savedDetail

        isLoading = true
        isCancellable = false
        loadProgress = nil

        loadTask = Task {
            do {
                let items = try FileLoader.loadChildren(of: url)
                guard !Task.isCancelled else { return }
                rootItems = items
                startVersionFetch(for: items)
            } catch FileLoadError.accessDenied {
                // ドロップしたフォルダ自体が読めない場合のみフルディスクアクセスへ誘導（HANDOFF §2）
                rootURL = nil
                isLoading = false
                showFullDiskAccessGuide()
            } catch {
                // 読み込み失敗
                rootURL = nil
            }
            isLoading = false
        }
    }

    // MARK: 光学・ネットワーク自動高速

    /// 光学ディスクの自動高速を有効にするか（隠し設定。既定 ON。`versionAutoFastOptical` で無効化）。
    private static var autoFastOnOptical: Bool {
        UserDefaults.standard.object(forKey: "versionAutoFastOptical") == nil
            ? true : UserDefaults.standard.bool(forKey: "versionAutoFastOptical")
    }

    /// ネットワーク経由の自動高速を有効にするか（隠し設定。既定 ON。`versionAutoFastNetwork` で無効化）。
    private static var autoFastOnNetwork: Bool {
        UserDefaults.standard.object(forKey: "versionAutoFastNetwork") == nil
            ? true : UserDefaults.standard.bool(forKey: "versionAutoFastNetwork")
    }

    /// ドロップされた root が光学ディスク（CD/DVD/BD）上かを判定する。
    /// DiskArbitration で判定する。`statfs` のファイルシステム種別は使えない（DVD-R が HFS+ で焼かれていると
    /// `hfs` を返し、ISO/UDF 以外の光学を取りこぼす）。USB SuperDrive では DAMediaKind も汎用 `IOMedia` に
    /// なるため、メディアクラスに加えてデバイスパスの光学サービスクラス／メディアアイコンの StorageFamily も見る。
    private static func isOpticalVolume(_ url: URL) -> Bool {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return false }

        // 1) メディアの IOKit クラスが光学なら確定（内蔵 ATAPI ドライブ等）
        if let kind = desc[kDADiskDescriptionMediaKindKey as String] as? String,
           kind == "IOCDMedia" || kind == "IODVDMedia" || kind == "IOBDMedia" {
            return true
        }
        // 2) USB 光学ドライブ等では DAMediaKind が汎用 IOMedia になる。デバイスパスの
        //    光学サービスクラス（IOCDServices/IODVDServices/IOBDServices）で判定する。
        if let devicePath = desc[kDADiskDescriptionDevicePathKey as String] as? String {
            for m in ["IOCDServices", "IODVDServices", "IOBDServices"] where devicePath.contains(m) {
                return true
            }
        }
        // 3) 最後の砦：メディアアイコンの StorageFamily（IOCD/DVD/BDStorageFamily）
        if let icon = desc[kDADiskDescriptionMediaIconKey as String] as? [String: Any],
           let bundle = icon["CFBundleIdentifier"] as? String {
            for f in ["IOCDStorageFamily", "IODVDStorageFamily", "IOBDStorageFamily"] where bundle.contains(f) {
                return true
            }
        }
        return false
    }

    /// ドロップされた root がネットワークボリューム（SMB/AFP/NFS 等）上かを判定する。
    /// URLResourceKey.volumeIsLocalKey == false で判定（判定不能はローカル扱い＝自動高速しない・安全側）。
    private static func isNetworkVolume(_ url: URL) -> Bool {
        let rv = try? url.resourceValues(forKeys: [.volumeIsLocalKey])
        if let isLocal = rv?.volumeIsLocal { return !isLocal }
        return false
    }

    /// フルディスクアクセスへの誘導アラート。「システム設定を開く」で該当ペインへ遷移する。
    private func showFullDiskAccessGuide() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Could not read the dropped folder")
        alert.informativeText = String(localized:
            "AFVer Desktop may need Full Disk Access. Open System Settings > Privacy & Security > Full Disk Access, turn on AFVer Desktop, then drop the folder again.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func expandItem(_ item: FileItem, completion: @escaping () -> Void) {
        progressShowTask?.cancel()
        let progressDelay = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isCancellable = true
                isLoading = true
            }
        }
        progressShowTask = progressDelay

        loadTask = Task {
            do {
                let children = try FileLoader.loadChildren(of: item.url)
                if Task.isCancelled {
                    item.children = []
                    item.needsLoading = true
                    progressDelay.cancel()
                    isLoading = false
                    isCancellable = false
                    completion()   // → OutlineList 側で閉じた状態に戻す（needsLoading で判別）
                    return
                }
                item.children = children
                startVersionFetch(for: children)
            } catch {
                item.children = []
                item.isDimmed = true
            }
            progressDelay.cancel()
            isLoading = false
            isCancellable = false
            completion()
        }
    }

    // MARK: すべて展開／すべて閉じる（表示メニュー）

    /// すべて展開（⌥⌘→）：未読み込みのサブフォルダを再帰的に読み込んでから、
    /// ツリー全体を展開する。0.5秒超でプログレス表示（キャンセル可）。
    /// キャンセル時は、それまでに読み込めた分まで展開する。
    func expandAll() {
        guard !rootItems.isEmpty else { return }

        progressShowTask?.cancel()
        let progressDelay = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isCancellable = true
                isLoading = true
            }
        }
        progressShowTask = progressDelay

        loadTask = Task {
            await loadAllDescendants(of: rootItems)
            progressDelay.cancel()
            isLoading = false
            isCancellable = false
            treeActions?.expandAllLoaded()
            startVersionFetch(for: rootItems)
        }
    }

    /// すべて閉じる（⌥⌘←）
    func collapseAll() {
        treeActions?.collapseAll()
    }

    /// 列幅を調整（⌘J）：変更日・サイズ・バージョン・種類を内容に合わせる（種類を省略させない）。
    func adjustColumnWidths() {
        treeActions?.adjustColumnWidths()
    }

    /// 未読み込みのフォルダを再帰的に読み込む。
    /// フォルダ1つ読み込むごとに yield して、プログレス表示とキャンセル操作に制御を返す。
    private func loadAllDescendants(of items: [FileItem]) async {
        for item in items {
            if Task.isCancelled { return }
            guard item.isDirectory, !item.isPackage, !item.isSymlink else { continue }
            if item.needsLoading {
                item.needsLoading = false
                do {
                    item.children = try FileLoader.loadChildren(of: item.url)
                } catch {
                    item.children = []
                    item.isDimmed = true
                }
                await Task.yield()
            }
            if let children = item.children {
                await loadAllDescendants(of: children)
            }
        }
    }

    // MARK: バージョン取得（スイッチON時）

    /// スイッチの切替。ON にしたら現在読み込み済みの全アイテムを取得対象にする。
    func setShowVersion(_ on: Bool) {
        showVersionColumn = on
        UserDefaults.standard.set(on, forKey: Self.showVersionKey)
        if on {
            startVersionFetch(for: rootItems)
        }
    }

    /// バージョン取得精度の切替。fast/full で結果が変わるため、読み込み済みアイテムを
    /// 未取得へ戻して再取得する（別精度の結果は別キーでキャッシュ済みなら即時復元）。
    func setVersionDetail(_ detail: VersionDetail) {
        guard detail != versionDetail else { return }
        versionDetail = detail
        UserDefaults.standard.set(detail.rawValue, forKey: Self.versionDetailKey)
        versionFetchTask?.cancel()
        for it in collectLoaded(rootItems) { it.versionState = .idle }
        if showVersionColumn {
            startVersionFetch(for: rootItems)
        }
    }

    /// 「Photoshop形式のバージョンを検出する」設定の切替時に呼ぶ。読み込み済みアイテムを未取得へ戻して
    /// 再取得する（PSD/PSB・編集PDF の結果が変わるため。別フラグ値の結果は別キーでキャッシュ済みなら即時復元）。
    /// `AppDelegate.refetchVersionsAllWindows()` が全ウインドウのモデルに対して呼ぶ。
    func refetchLoadedVersions() {
        guard showVersionColumn else { return }
        versionFetchTask?.cancel()
        for it in collectLoaded(rootItems) { it.versionState = .idle }
        startVersionFetch(for: rootItems)
    }

    // MARK: バージョン解決のメモリキャッシュ

    /// パス＋変更日＋サイズが一致すれば再解析せず結果を再利用する（プロセス内のみ）。
    /// 値の nil は「対象外と確定」を意味する（拡張子なしの非Ai/Ps等）。
    private struct VersionCacheKey: Hashable {
        let path: String
        let modified: Date?
        let size: Int64?
        let detail: VersionDetail   // 精度モードで結果が変わるためキーに含める
        let detectPs: Bool          // Photoshop ネイティブ版検出の実効値（PSD/PSB・編集PDF の結果が変わる）
    }
    private static var versionCache: [VersionCacheKey: VersionResolution?] = [:]

    private static func cacheKey(for item: FileItem, detail: VersionDetail, detectPs: Bool) -> VersionCacheKey {
        VersionCacheKey(path: item.url.path,
                        modified: item.modifiedDate,
                        size: item.fileSize,
                        detail: detail,
                        detectPs: detectPs)
    }

    private static func apply(_ res: VersionResolution?, to item: FileItem) {
        item.versionText = res?.version ?? ""
        item.kindOverride = res?.kindOverride
        item.kindMismatch = res?.extMismatch ?? false
        item.appFamily = res?.family
        item.versionState = .resolved
    }

    /// 指定アイテム（とその読み込み済み子孫）のうち未取得のものを非同期で解析する。
    /// キャッシュ命中分は即時確定し、残りを最大4並列で解析する。
    func startVersionFetch(for items: [FileItem]) {
        guard showVersionColumn else { return }
        let detail = versionDetail
        // Photoshop ネイティブ版（PSD/PSB・編集PDF）の検出可否（実効値）。
        // 「full モード かつ 設定 ON」のときだけ true（fast は常にスキップ＝B、full は設定で切替＝A）。
        let detectPs = (detail != .fast) && AppSettings.shared.detectPhotoshopVersion
        let loaded = collectLoaded(items)

        var toFetch: [FileItem] = []
        for it in loaded where it.versionState == .idle {
            guard VersionInfo.isPotentialTarget(url: it.url) else {
                it.versionState = .resolved   // 対象外：バージョン空・種類は macOS 任せ
                continue
            }
            if let cached = Self.versionCache[Self.cacheKey(for: it, detail: detail, detectPs: detectPs)] {
                Self.apply(cached, to: it)    // キャッシュ命中：再解析しない
                continue
            }
            it.versionState = .fetching
            toFetch.append(it)
        }
        guard !toFetch.isEmpty else {
            versionRefreshToken &+= 1   // プレースホルダ消去のため一度だけ再描画
            return
        }
        versionRefreshToken &+= 1       // 「…」表示へ

        versionFetchTask = Task { [weak self] in
            let maxConcurrent = Self.versionFetchConcurrency
            await withTaskGroup(of: (Int, VersionResolution?).self) { group in
                var next = 0
                func enqueue(_ index: Int) {
                    let url = toFetch[index].url
                    group.addTask { (index, await VersionInfo.resolveAsync(url: url, detail: detail, detectPsVersion: detectPs)) }
                }
                while next < min(maxConcurrent, toFetch.count) {
                    enqueue(next); next += 1
                }
                // リスト再描画はコアレッシングする：1ファイルごとに reloadData すると総コストが
                // 「解決数 × 見えている行数」になり、窓が大きいほど取得が遅くなる（実測）。
                // versionRefreshToken の加算を約200msに1回へ間引き、最後に必ず1回フラッシュする。
                // apply 自体は毎回行うのでデータは即時反映され、再描画の頻度だけを上限で抑える。
                let uiRefreshInterval = 0.2
                var lastUIRefresh = CFAbsoluteTimeGetCurrent()
                for await (index, res) in group {
                    guard let self, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    let item = toFetch[index]
                    Self.versionCache[Self.cacheKey(for: item, detail: detail, detectPs: detectPs)] = res
                    Self.apply(res, to: item)
                    let now = CFAbsoluteTimeGetCurrent()
                    if now - lastUIRefresh >= uiRefreshInterval {
                        lastUIRefresh = now
                        self.versionRefreshToken &+= 1
                    }
                    if next < toFetch.count {
                        enqueue(next); next += 1
                    }
                }
                // 完了時のフラッシュ：間引きで取りこぼした最後のぶんを必ず反映する
                self?.versionRefreshToken &+= 1
            }
        }
    }

    /// 読み込み済みアイテムを再帰的に集める（展開済みフォルダの子も含む）。
    private func collectLoaded(_ items: [FileItem]) -> [FileItem] {
        var out: [FileItem] = []
        for it in items {
            out.append(it)
            if let ch = it.children, !ch.isEmpty {
                out.append(contentsOf: collectLoaded(ch))
            }
        }
        return out
    }

    /// ステータスバー用の集計。「現在表示されている行」（フォルダの展開状態を反映）を対象に、
    /// 総数・選択数・アプリ系統別ドット数を返す。visibleTotal / visibleFamilyCounts /
    /// selectedCount は OutlineList から更新され、変化で ContentView が再評価される。
    struct StatusSummary {
        var total: Int
        var selected: Int
        /// 系統別ドット数（0件は除外・表示順で整列）。バージョン列OFF時は空。
        var perFamily: [(family: AppFamily, count: Int)]
    }

    var statusSummary: StatusSummary {
        // 表記規約の並び：InDesign → Illustrator → PDF → Photoshop
        let order: [AppFamily] = [.indesign, .illustrator, .pdf, .photoshop, .epsOther]
        let per = showVersionColumn ? order.compactMap { fam -> (AppFamily, Int)? in
            let c = visibleFamilyCounts[fam] ?? 0
            return c > 0 ? (fam, c) : nil
        } : []
        return StatusSummary(total: visibleTotal, selected: selectedCount, perFamily: per)
    }

    func cancelLoading() {
        loadTask?.cancel()
        progressShowTask?.cancel()
        isLoading = false
        isCancellable = false
    }

    /// 選択中のアイテムを Finder に表示（ファイルメニュー ⌘R）。未選択なら何もしない。
    func revealSelectionInFinder() {
        guard let item = selectedItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: CSV書き出し（⌘E）

    /// 現在の展開状態のリストを CSV に書き出す。リストが空なら何もしない。
    func exportList() {
        guard let rootURL, !rootItems.isEmpty,
              let rows = printRowProvider?(), !rows.isEmpty else { return }

        // ダイアログ表示中にリストが変わっても良いよう、内容は先に確定しておく
        let csv = Self.makeCSV(rows: rows, columns: displayColumns,
                               versionOn: showVersionColumn)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue =
            FileManager.default.displayName(atPath: rootURL.path) + ".csv"

        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let dest = panel.url else { return }
            do {
                try csv.write(to: dest, atomically: true, encoding: .utf8)
            } catch {
                NSSound.beep()
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: write)
        } else {
            write(panel.runModal())
        }
    }

    /// CSV 文字列を組み立てる。名前列はツリー階層を行頭スペースで表現する。
    private static func makeCSV(rows: [PrintRow], columns: [OutlineListColumn],
                                versionOn: Bool) -> String {
        func escape(_ s: String) -> String {
            guard s.contains("\"") || s.contains(",") || s.contains("\n") else { return s }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines: [String] = [columns.map { escape($0.title) }.joined(separator: ",")]
        for row in rows {
            let item = row.item
            let fields = columns.map { col -> String in
                switch col.id {
                case "name":
                    return String(repeating: "    ", count: row.level) + item.name
                case "date":    return item.displayDate
                case "size":    return item.displaySize
                case "version": return item.displayVersion
                case "kind":    return item.displayKind(versionMode: versionOn)
                default:        return ""
                }
            }
            lines.append(fields.map(escape).joined(separator: ","))
        }
        // Excel が UTF-8 を正しく認識するよう BOM を付ける
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    // MARK: プリント（⌘P）

    /// 現在の展開状態のリストを印刷する。リストが空なら何もしない。
    /// バージョン列ONのときは既定の用紙方向を横向きにする（ダイアログで変更可能）。
    func printList() {
        guard let rootURL, !rootItems.isEmpty,
              let rows = printRowProvider?(), !rows.isEmpty else { return }

        let keyWindow = NSApp.keyWindow
        let columns = displayColumns
        let versionOn = showVersionColumn

        let flat = isFlatDrop
        Task {
            // フラット表示（ファイル等のドロップ）はヘッダを日時のみにする（フォルダの素性を出さない）。
            // 通常のフォルダ表示はアイコン＋名称＋合計サイズ（ボリュームは即時／フォルダは3秒タイムアウト）。
            let header: PrintHeaderInfo
            if flat {
                header = PrintHeaderInfo(icon: nil,
                                         title: String(localized: "File List"),
                                         totalSize: nil)
            } else {
                let totalSize = await PrintTotalSize.resolve(for: rootURL)
                let icon = NSWorkspace.shared.icon(forFile: rootURL.path)
                header = PrintHeaderInfo(
                    icon: icon,
                    title: FileManager.default.displayName(atPath: rootURL.path),
                    totalSize: totalSize
                )
            }
            // 変更日／サイズの表示切替（印刷パネルのアクセサリと共有）。毎回両方ONで開始。
            let columnOptions = PrintColumnOptions()
            let printView = PrintLayoutView(
                rows: rows, columns: columns,
                versionMode: versionOn, header: header,
                columnOptions: columnOptions,
                kindMismatchRedText: AppSettings.shared.kindMismatchRedText
            )

            let printInfo = NSPrintInfo()
            // 折り返し対応により横幅が不要になったため、既定は常に縦向き
            //（印刷ダイアログで横向きに変更可能）。
            printInfo.orientation = .portrait
            // 希望マージン：上・左右は 36pt（0.5インチ）。下はページ番号まわりの余白が
            // 大きく見えるため 18pt（0.25インチ）に詰めてレイアウトのバランスを整える。
            // いずれもプリンターの印字可能領域（imageablePageBounds）を絶対にはみ出さない
            // よう、ハードウェアマージンを下限にする。orientation 設定後に取得する。
            let desiredMargin: CGFloat = 36
            let desiredBottomMargin: CGFloat = 18
            let paper = printInfo.paperSize
            let imageable = printInfo.imageablePageBounds  // 原点は用紙左下
            let hwLeft   = imageable.minX
            let hwBottom = imageable.minY
            let hwRight  = paper.width - imageable.maxX
            let hwTop    = paper.height - imageable.maxY
            // 値が不正（負・NaN・用紙をはみ出す）な場合は固定値にフォールバック
            let marginsValid = [hwLeft, hwRight, hwTop, hwBottom].allSatisfy { $0.isFinite && $0 >= 0 }
                && (hwLeft + hwRight) < paper.width
                && (hwTop + hwBottom) < paper.height
            if marginsValid {
                printInfo.leftMargin   = max(desiredMargin, hwLeft)
                printInfo.rightMargin  = max(desiredMargin, hwRight)
                printInfo.topMargin    = max(desiredMargin, hwTop)
                printInfo.bottomMargin = max(desiredBottomMargin, hwBottom)
            } else {
                printInfo.leftMargin = desiredMargin
                printInfo.rightMargin = desiredMargin
                printInfo.topMargin = desiredMargin
                printInfo.bottomMargin = desiredBottomMargin
            }
            printInfo.horizontalPagination = .clip
            printInfo.verticalPagination = .clip
            printInfo.isHorizontallyCentered = false
            printInfo.isVerticallyCentered = false

            let op = NSPrintOperation(view: printView, printInfo: printInfo)
            op.jobTitle = header.title
            op.printPanel.options.formUnion([.showsOrientation, .showsPaperSize, .showsPreview])
            op.printPanel.addAccessoryController(PrintColumnOptionsController(options: columnOptions))
            if let keyWindow {
                op.runModal(for: keyWindow, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                op.run()
            }
        }
    }
}

// MARK: - FocusedValues（最前面ウィンドウのモデルをメニューコマンドへ渡す）

private struct FileListModelFocusedKey: FocusedValueKey {
    typealias Value = FileListModel
}

private struct VersionDetailFocusedKey: FocusedValueKey {
    typealias Value = VersionDetail
}

extension FocusedValues {
    var fileListModel: FileListModel? {
        get { self[FileListModelFocusedKey.self] }
        set { self[FileListModelFocusedKey.self] = newValue }
    }
    /// 最前面ウィンドウの「実効バージョン精度」（光学自動高速を含む）。メニューのチェック追従用。
    var effectiveVersionDetail: VersionDetail? {
        get { self[VersionDetailFocusedKey.self] }
        set { self[VersionDetailFocusedKey.self] = newValue }
    }
}
