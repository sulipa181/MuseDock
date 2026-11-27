import AppKit
import WebKit
import Carbon.HIToolbox
import ServiceManagement

// MARK: - 帳號資料

struct Account: Codable {
    static let mainGroup = "主力"
    static let backupGroup = "備用"

    var name: String
    var email: String
    var storeID: String
    var group: String
    var slot: Int
    var loggedIn: Bool
    /// 來源 Chrome Profile 目錄（例如 "Profile 11"），空字串表示非 Chrome 匯入
    var profileDir: String
    /// 對話列表指紋 "v1|<筆數>|<hash>"，用來偵測重複登入的同一個 Muse 帳號
    var fingerprint: String
    /// 指紋樣本（左側欄標題），用相似度比對，避免載入不完整造成漏判
    var fpItems: [String]

    enum CodingKeys: String, CodingKey {
        case name, email, storeID, group, slot, loggedIn, profileDir, fingerprint, fpItems
    }

    init(name: String, email: String, storeID: String, group: String = Account.mainGroup,
         slot: Int = 0, loggedIn: Bool = false, profileDir: String = "",
         fingerprint: String = "", fpItems: [String] = []) {
        self.name = name
        self.email = email
        self.storeID = storeID
        self.group = group
        self.slot = slot
        self.loggedIn = loggedIn
        self.profileDir = profileDir
        self.fingerprint = fingerprint
        self.fpItems = fpItems
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? "未登入"
        storeID = try c.decode(String.self, forKey: .storeID)
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? Account.mainGroup
        slot = try c.decodeIfPresent(Int.self, forKey: .slot) ?? 0
        loggedIn = try c.decodeIfPresent(Bool.self, forKey: .loggedIn) ?? false
        profileDir = try c.decodeIfPresent(String.self, forKey: .profileDir) ?? ""
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        fpItems = try c.decodeIfPresent([String].self, forKey: .fpItems) ?? []
    }

    /// 樣本是否足夠比對（樣本太少時不比，避免兩個空白帳號被誤判為同一個）
    var hasUsableFp: Bool { fpItems.count >= 2 }

    /// 兩份樣本是否指向同一個 Muse 帳號。
    /// 樣本多時看「覆蓋率」，樣本少（2 筆）時要求完全一致，避免誤判。
    func sameAccount(as other: Account) -> Bool {
        guard hasUsableFp, other.hasUsableFp else { return false }
        let mine = Set(fpItems), theirs = Set(other.fpItems)
        let common = mine.intersection(theirs).count
        let smaller = min(mine.count, theirs.count)
        if smaller >= 3 { return common >= 3 && Double(common) / Double(smaller) >= 0.6 }
        return common == smaller
    }
}

enum Store {
    static let dir: URL = {
        // MUSE_STATE_DIR 可把狀態檔導到別處：做截圖／示範時用假資料跑，
        // 不碰真實帳號，兩個行程也不會共用同一份 accounts.json（鎖也跟著走）。
        if let custom = ProcessInfo.processInfo.environment["MUSE_STATE_DIR"], !custom.isEmpty {
            let d = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        }
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MuseDock", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var file: URL { dir.appendingPathComponent("accounts.json") }
    /// 跨行程讀寫鎖，與 accounts.json 同目錄。flock 由 kernel 釋放，不會留下殘留鎖。
    static var lockFile: URL { dir.appendingPathComponent("accounts.lock") }
    /// 上次讀到／寫入的內容指紋，用來發現「檔案被別的行程改過」
    static var lastDigest: String?

    static func digest(_ d: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a 64
        for b in d { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return String(h, radix: 16)
    }

    /// 在 flock 保護下執行。拿不到鎖就直接執行——寧可寫，也不能把 UI 卡住。
    @discardableResult
    static func withLock<T>(_ op: Int32, _ body: () -> T) -> T {
        let fd = open(lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        flock(fd, op)
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }

    static func load() -> [Account] {
        // 讀取持共享鎖：避開另一行程 rename 的瞬間
        let data: Data? = withLock(LOCK_SH) {
            let d = try? Data(contentsOf: file)
            lastDigest = d.map(digest)
            return d
        }
        if let data,
           var list = try? JSONDecoder().decode([Account].self, from: data) {
            var next = (list.map(\.slot).max() ?? 0) + 1
            var changed = false
            for i in list.indices where list[i].slot <= 0 {
                list[i].slot = next
                next += 1
                changed = true
            }
            if changed { save(list) }
            return list
        }
        // 首次啟動的佔位帳號：讓使用者有卡片可以直接匯入，名字之後可改
        let seed = [
            Account(name: "帳號 1", email: "未登入", storeID: UUID().uuidString, group: Account.mainGroup, slot: 1),
            Account(name: "帳號 2", email: "未登入", storeID: UUID().uuidString, group: Account.backupGroup, slot: 2),
        ]
        save(seed)
        return seed
    }

    static func save(_ list: [Account]) {
        guard let data = try? JSONEncoder().encode(list) else {
            print("STORE_SAVE_ERR encode failed count=\(list.count)")
            return
        }
        withLock(LOCK_EX) {
            // 別的行程改過檔 → 這次寫入會蓋掉它。蓋是蓋，但要留下痕跡，
            // 否則就是「帳號無聲消失」，只能靠猜。
            if lastDigest != nil, let existing = try? Data(contentsOf: file),
               digest(existing) != lastDigest {
                print("STORE_CONFLICT 檔案已被其他行程改過（磁碟 \(existing.count)B / 本次 \(data.count)B），以本次為準")
            }
            do {
                // .atomic：先寫同目錄暫存檔再 rename。中途被 kill 不會留下半截 JSON，
                // 讀取端永遠只會看到「舊的完整檔」或「新的完整檔」。
                try data.write(to: file, options: .atomic)
                lastDigest = digest(data)
            } catch {
                print("STORE_SAVE_ERR \(error.localizedDescription)")
            }
        }
    }

    // MARK: 網站資料目錄

    /// WebKit 依 storeID 建立的資料目錄。
    /// `WKWebsiteDataStore.removeData(...)` 只清 cookie/localStorage/IndexedDB 那幾類，
    /// NetworkCache、AlternativeServices、MediaKeys 會留在這個目錄裡，所以刪帳號要另外補刀。
    static func websiteDataDir(for storeID: String) -> URL? {
        // 只接受合法 UUID，避免拼出奇怪的相對路徑
        guard UUID(uuidString: storeID) != nil else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "local.sulipa.musedock"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/WebKit", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("WebsiteDataStore", isDirectory: true)
            .appendingPathComponent(storeID, isDirectory: true)
    }

    /// 目錄大小（給日誌與自測用），不存在回 nil
    static func websiteDataSize(for storeID: String) -> String? {
        guard let dir = websiteDataDir(for: storeID),
              FileManager.default.fileExists(atPath: dir.path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sh", dir.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\t").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
    }

    /// 刪掉 storeID 對應的整個 WebKit 資料目錄。
    /// WebKit 可能還握著檔案句柄，刪不掉時重試幾次；完成後在 main queue 回呼。
    static func purgeWebsiteDataDir(for storeID: String,
                                    completion: ((_ removed: Bool, _ detail: String) -> Void)? = nil) {
        guard let dir = websiteDataDir(for: storeID) else {
            DispatchQueue.main.async { completion?(false, "invalid storeID") }
            return
        }
        let fm = FileManager.default
        DispatchQueue.global(qos: .utility).async {
            let before = websiteDataSize(for: storeID) ?? "0"
            var removed = false
            for attempt in 1...4 {
                guard fm.fileExists(atPath: dir.path) else { removed = true; break }
                try? fm.removeItem(at: dir)
                if !fm.fileExists(atPath: dir.path) { removed = true; break }
                if attempt < 4 { Thread.sleep(forTimeInterval: 0.4) }
            }
            let detail = removed ? "removed \(before)" : "still present \(websiteDataSize(for: storeID) ?? "?")"
            DispatchQueue.main.async { completion?(removed, detail) }
        }
    }
}

// MARK: - 小工具

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 主題色（跟隨系統深／淺色）

enum Theme {
    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static let sidebar = dynamic(
        NSColor(srgbRed: 0.960, green: 0.960, blue: 0.968, alpha: 1),
        NSColor(srgbRed: 0.121, green: 0.121, blue: 0.133, alpha: 1))
    static let content = dynamic(
        NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.086, green: 0.086, blue: 0.094, alpha: 1))
    static let accent = dynamic(
        NSColor(srgbRed: 0.239, green: 0.510, blue: 0.933, alpha: 1),
        NSColor(srgbRed: 0.345, green: 0.596, blue: 0.984, alpha: 1))
    static let hairline = dynamic(
        NSColor(white: 0, alpha: 0.09),
        NSColor(white: 1, alpha: 0.09))
}

final class SidebarView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        wantsLayer = true
        layer?.backgroundColor = Theme.sidebar.cgColor
    }
}

final class CanvasView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        wantsLayer = true
        layer?.backgroundColor = Theme.content.cgColor
    }
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.29, green: 0.56, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.45, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.72, blue: 0.48, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.45, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.66, blue: 0.28, alpha: 1),
        NSColor(srgbRed: 0.25, green: 0.72, blue: 0.78, alpha: 1),
    ]
    static func color(for name: String) -> NSColor {
        var h: UInt32 = 5381
        for b in name.utf8 { h = (h &* 33) &+ UInt32(b) }
        return colors[Int(h % UInt32(colors.count))]
    }
}

final class AvatarView: NSView {
    private let tint: NSColor
    private let initial: String

    init(name: String, diameter: CGFloat) {
        tint = Palette.color(for: name)
        let first = name.trimmingCharacters(in: .whitespaces).first.map { String($0) } ?? "M"
        initial = first.uppercased()
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let d = min(bounds.width, bounds.height)
        let rect = NSRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
        tint.setFill()
        NSBezierPath(ovalIn: rect).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: d * 0.44, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: initial, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

final class BadgeView: NSView {
    var text: String { didSet { widthC.constant = BadgeView.width(for: text, fontSize: fontSize); needsDisplay = true } }
    private let fontSize: CGFloat
    private var widthC: NSLayoutConstraint!

    init(_ text: String, fontSize: CGFloat = 9.5) {
        self.text = text
        self.fontSize = fontSize
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthC = widthAnchor.constraint(equalToConstant: BadgeView.width(for: text, fontSize: fontSize))
        widthC.isActive = true
        heightAnchor.constraint(equalToConstant: 15).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    static func width(for text: String, fontSize: CGFloat) -> CGFloat {
        let w = (text as NSString).size(withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
        ]).width
        return max(19, w + 9)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}


// MARK: - 藍色實心按鈕

final class AccentButton: NSButton {
    private let titleInset: CGFloat

    init(_ title: String, symbol: String? = nil, fontSize: CGFloat = 11.5,
         height: CGFloat = 22, target: AnyObject?, action: Selector) {
        titleInset = symbol == nil ? 14 : 8
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Theme.accent.cgColor
        font = .systemFont(ofSize: fontSize, weight: .semibold)
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image = img
            imagePosition = .imageLeading
        }
        contentTintColor = .white
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        var w = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).width + titleInset * 2
        if symbol != nil { w += 16 }
        widthAnchor.constraint(equalToConstant: ceil(w)).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = Theme.accent.cgColor
        layer?.cornerRadius = 6
    }
}


// MARK: - 分組標題

final class SectionHeader: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        let label = NSTextField(labelWithAttributedString: NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 0.6,
        ]))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 帳號卡片

final class AccountCard: NSView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateAppearance() } }
    private var hover = false { didSet { updateAppearance() } }
    private var tracking: NSTrackingArea?

    init(account: Account, index: Int, shortcutModifier: String, duplicateOf: (slot: Int, name: String)? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 64).isActive = true

        let avatar = AvatarView(name: account.name, diameter: 32)
        let name = NSTextField(labelWithString: account.name)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let badge = BadgeView("\(shortcutModifier)\(index + 1)")

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (account.loggedIn ? NSColor.systemGreen : NSColor.tertiaryLabelColor)
            .withAlphaComponent(0.9).cgColor
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 5).isActive = true

        // 副標題：標明來源（Chrome Profile）＋該 Profile 的 Google 帳號
        let hasEmail = account.email.contains("@")
        let hasProfile = !account.profileDir.isEmpty
        let subText: String
        if hasProfile && hasEmail {
            subText = "\(account.profileDir) · \(account.email)"
        } else if hasProfile {
            subText = "\(account.profileDir) · \(account.loggedIn ? "已登入" : "未登入")"
        } else if hasEmail {
            subText = account.email
        } else {
            subText = account.loggedIn ? "已登入 · cookie 匯入" : "未登入"
        }
        let sub = NSTextField(labelWithString: subText)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingMiddle
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [avatar, name, badge, dot, sub]
        // 重複登入同一個 Muse 帳號時，在右上角標一個警示
        var warn: NSTextField?
        if let dup = duplicateOf {
            let w = NSTextField(labelWithString: "⚠︎")
            w.font = .systemFont(ofSize: 11, weight: .semibold)
            w.textColor = NSColor.systemOrange
            w.setContentHuggingPriority(.required, for: .horizontal)
            w.toolTip = "與 \(dup.slot) 號（\(dup.name)）是同一個 Muse 帳號"
            self.toolTip = "\(account.name)：與 \(dup.slot) 號（\(dup.name)）登入同一個 Muse 帳號"
            warn = w
            views.append(w)
        } else if hasProfile {
            self.toolTip = "\(account.name)：來自 Chrome \(account.profileDir)\(hasEmail ? "（\(account.email)）" : "")"
        }

        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            avatar.centerYAnchor.constraint(equalTo: centerYAnchor),

            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 10),
            name.topAnchor.constraint(equalTo: topAnchor, constant: 14),

            badge.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 6),
            badge.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -11),

            dot.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: sub.centerYAnchor),

            sub.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            sub.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3),
            sub.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -11),
        ])

        if let warn {
            NSLayoutConstraint.activate([
                warn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
                warn.centerYAnchor.constraint(equalTo: name.centerYAnchor),
                badge.trailingAnchor.constraint(lessThanOrEqualTo: warn.leadingAnchor, constant: -6),
            ])
        }

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        addGestureRecognizer(click)
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func handleClick() { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    private func updateAppearance() {
        guard let layer else { return }
        layer.cornerRadius = 10
        layer.borderWidth = isSelected ? 1 : 0
        layer.borderColor = Theme.accent.withAlphaComponent(0.75).cgColor
        if isSelected {
            layer.backgroundColor = Theme.accent.withAlphaComponent(0.13).cgColor
        } else if hover {
            layer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07).cgColor
        } else {
            layer.backgroundColor = NSColor.clear.cgColor
        }
    }
}

// MARK: - 全域快捷鍵（Carbon，不需輔助使用權限）

final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    var onPress: ((Int) -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            me.onPress?(Int(hkID.id))
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(count: Int) {
        for r in refs { if let r { UnregisterEventHotKey(r) } }
        refs = []
        guard count > 0 else { return }
        for i in 1...min(count, 9) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D53444B), id: UInt32(i)) // 'MSDK'
            RegisterEventHotKey(UInt32(kVK_ANSI_1) + UInt32(i - 1), UInt32(cmdKey | shiftKey),
                                id, GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

// MARK: - 主控

final class Controller: NSObject, WKNavigationDelegate, NSApplicationDelegate, NSMenuDelegate {
    let window: NSWindow
    var accounts: [Account]
    var webViews: [String: WKWebView] = [:]
    var chromeProfiles: [ChromeProfile] = []
    var statusItem: NSStatusItem?
    /// 第二實例發來的「叫回視窗」通知（持有 token，否則會被釋放）
    var showObserver: NSObjectProtocol?
    /// 指紋計算中的 storeID，避免重入
    var fpBusy: Set<String> = []
    /// 各 storeID 上次計算指紋的時間
    var fpAt: [String: Date] = [:]
    /// 登入探測中的 storeID，避免重入
    var loginProbeBusy: Set<String> = []
    /// 各 storeID 上次登入探測的時間（節流用）
    var loginProbeAt: [String: Date] = [:]
    /// 登入探測節流秒數
    let loginProbeInterval: TimeInterval = 180
    /// 閒置多久釋放非當前帳號的 WebView（秒）。10 分鐘＝「切回去不痛」與「省記憶體」的折中。
    var idleReleaseAfter: TimeInterval {
        Double(ProcessInfo.processInfo.environment["MUSE_IDLE_RELEASE_SEC"] ?? "") ?? 600
    }
    /// 各 storeID 最後一次被選取的時間
    var lastActiveAt: [String: Date] = [:]
    /// 掃描閒置帳號的計時器
    var idleTimer: Timer?
    /// 最近一次探測結果（storeID → 是否登入），自測用
    var lastProbe: [String: Bool] = [:]
    var cards: [AccountCard] = []
    var current: Int = 0

    let contentHost = CanvasView()
    var sidebarView: SidebarView!
    var rootView: CanvasView!
    let cardStack = NSStackView()
    let statusLabel = NSTextField(labelWithString: "⇧⌘1–4 快速切換帳號")
    let countBadge = BadgeView("0", fontSize: 10)
    let hotKeys = HotKeys()
    let url = URL(string: "https://muse.ai")!

    override init() {
        accounts = Store.load()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "MuseDock"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 900, height: 600)
        window.center()
        window.setFrameAutosaveName("MuseDockMain")
        window.isReleasedWhenClosed = false   // 常駐：關窗後仍保留，可從選單列叫回
        window.appearance = nil // 跟隨系統深／淺色

        super.init()

        let root = CanvasView()
        root.translatesAutoresizingMaskIntoConstraints = false
        rootView = root

        // ── 側邊欄 ──
        let sidebar = SidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebarView = sidebar

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(header)

        let title = NSTextField(labelWithString: "Muse · Meta")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(title)

        countBadge.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(countBadge)

        let addBtn = AccentButton("新增", symbol: "plus", target: self, action: #selector(addAccount))
        header.addSubview(addBtn)

        let moreBtn = NSButton(image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "更多")!,
                               target: self, action: #selector(showMoreMenu(_:)))
        moreBtn.isBordered = false
        moreBtn.contentTintColor = .secondaryLabelColor
        moreBtn.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(moreBtn)

        // ── 卡片清單 ──
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(scroll)

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        cardStack.orientation = .vertical
        cardStack.spacing = 4
        cardStack.alignment = .width
        cardStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(cardStack)

        // ── 底部狀態 ──
        statusLabel.font = .systemFont(ofSize: 10.5)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 34),
            header.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            countBadge.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 7),
            countBadge.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            addBtn.trailingAnchor.constraint(equalTo: moreBtn.leadingAnchor, constant: -4),
            addBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            moreBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            moreBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            moreBtn.widthAnchor.constraint(equalToConstant: 22),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -6),

            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),

            cardStack.topAnchor.constraint(equalTo: doc.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            cardStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -12),
            statusLabel.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -10),
        ])

        // ── 右側內容 ──
        contentHost.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.hairline.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(divider)
        root.addSubview(contentHost)
        window.contentView = root

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 280),

            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            contentHost.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        syncChromeIdentity()
        rebuildCards()
        buildMenu()
        setupStatusItem()
        reportDuplicates()

        // 有人重複啟動時，第二個行程會發這個通知，這裡負責把視窗叫回來
        showObserver = DistributedNotificationCenter.default().addObserver(
            forName: InstanceLock.showNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.showWindow()
        }

        hotKeys.onPress = { [weak self] n in
            guard let self else { return }
            self.selectHotKey(n)
            if !self.window.isKeyWindow { self.showWindow() }
        }
        hotKeys.register(count: accounts.count)

        window.contentView?.layoutSubtreeIfNeeded()

        if SNAPSHOT {
            window.orderBack(nil)
            if accounts.isEmpty { showEmptyState() } else { cards.first?.isSelected = true }
            window.contentView?.layoutSubtreeIfNeeded()
            return
        }
        if PROBE_MODE {
            if ProcessInfo.processInfo.environment["MUSE_SHOW"] == "1" {
                window.orderFrontRegardless()   // 需要可見視窗才能測 rAF／hydration
            }
            return
        }


        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startIdleTimer()
        if accounts.isEmpty {
            showEmptyState()
        } else {
            let start = Int(ProcessInfo.processInfo.environment["MUSE_START_SLOT"] ?? "")
                .flatMap { slot in accounts.firstIndex(where: { $0.slot == slot }) } ?? 0
            select(start)
        }
    }

    // MARK: 卡片

    /// 畫面順序：主力全部在前、備用全部在後，各自維持原陣列順序
    var visualOrder: [Int] {
        let main = accounts.indices.filter { accounts[$0].group == Account.mainGroup }
        let back = accounts.indices.filter { accounts[$0].group != Account.mainGroup }
        return main + back
    }

    // MARK: 帳號指紋（偵測重複登入）

    /// 取左側欄的對話標題做成指紋；至少 3 筆才可信
    private let fingerprintJS = """
    return await (async () => {
      const clean = s => (s || '').replace(/\\s+/g, ' ').trim();
      const IGNORE = /^(主要聊天室|頻道|副聊天室|聊天室|對話|Chats?|Channels?|傳送訊息|Send a message|Send message|新增|新對話|新聊天|New chat|搜尋|Search|設定|Settings|探索|Explore|首頁|Home|登入|Sign in|Log in|升級|Upgrade|方案|Plans?|說明|Help|我的檔案|Files)$/i;
      const nodes = [...document.querySelectorAll('a[href], [role="link"], [role="button"], button, li')]
          .filter(e => e.offsetParent !== null);
      const seen = new Set();
      const items = [];
      for (const e of nodes) {
        const r = e.getBoundingClientRect();
        if (r.width < 60 || r.height < 16 || r.height > 90) continue;
        if (r.left > 400) continue;              // 只看左側欄
        const t = clean(e.innerText);
        if (!t || t.length > 80 || IGNORE.test(t)) continue;
        if (seen.has(t)) continue;
        seen.add(t);
        items.push(t);
      }
      const picked = items.sort().slice(0, 24);
      let h = 0x811c9dc5;
      const src = picked.join('|');
      for (let i = 0; i < src.length; i++) { h ^= src.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
      return JSON.stringify({n: picked.length, hash: h.toString(16),
                            items: picked.slice(0, 6), all: picked});
    })();
    """

    /// 載入後（或切換到該帳號時）重新計算指紋；同一帳號 3 分鐘內不重複算
    func scheduleFingerprint(for index: Int, attempt: Int = 0) {
        if DEMO { return }
        guard accounts.indices.contains(index) else { return }
        let acc = accounts[index]
        guard acc.loggedIn, let w = webViews[acc.storeID] else { return }
        guard !fpBusy.contains(acc.storeID) else { return }
        if let t = fpAt[acc.storeID], Date().timeIntervalSince(t) < 180 { return }
        fpBusy.insert(acc.storeID)
        fpAt[acc.storeID] = Date()
        let storeID = acc.storeID
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self, weak w] in
            guard let self, let w, w.url?.host?.contains("muse.ai") == true else {
                self?.fpBusy.remove(storeID); return
            }
            w.callAsyncJavaScript(self.fingerprintJS, arguments: [:], in: nil, in: .page) { r in
                self.fpBusy.remove(storeID)
                guard case .success(let v) = r, let text = v as? String,
                      let data = text.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let n = obj["n"] as? Int, let hash = obj["hash"] as? String,
                      let idx = self.accounts.firstIndex(where: { $0.storeID == storeID }) else { return }
                let items = (obj["items"] as? [String]) ?? []
                print("FP name=\(self.accounts[idx].name) n=\(n) hash=\(hash) items=\(items.prefix(3))")
                if n < 2 && attempt == 0 {
                    // 樣本不足：可能清單還沒載完，稍後再試一次
                    self.fpAt[storeID] = .distantPast
                    self.scheduleFingerprint(for: idx, attempt: 1)
                    return
                }
                let fp = n >= 2 ? "v1|\(n)|\(hash)" : ""
                let all = (obj["all"] as? [String]) ?? items
                guard self.accounts[idx].fingerprint != fp || self.accounts[idx].fpItems != all else { return }
                self.accounts[idx].fingerprint = fp
                self.accounts[idx].fpItems = n >= 2 ? all : []
                Store.save(self.accounts)
                self.rebuildCards()
                self.reportDuplicates()
            }
        }
    }

    /// 有重複時更新狀態列與選單，並印出診斷
    func reportDuplicates() {
        let dups = duplicateMap()
        buildMenu()
        guard !dups.isEmpty else { return }
        let text = dups.sorted { accounts[$0.key].slot < accounts[$1.key].slot }
            .map { "\(accounts[$0.key].slot) 號（\(accounts[$0.key].name)）與 \(accounts[$0.value].slot) 號相同" }
            .joined(separator: "、")
        statusLabel.stringValue = "⚠︎ 偵測到重複帳號：" + text
        print("DUP \(text)")
    }

    // MARK: 登入狀態即時化

    private let loginProbeJS = """
    return await (async () => {
      let apiStatus = 0, apiBody = '';
      for (const p of ['/api/me', '/api/user', '/api/session']) {
        try {
          const r = await fetch(p, {credentials: 'include'});
          apiStatus = r.status;
          const t = await r.text();
          if (r.status !== 404) { apiBody = p + ' => ' + t.slice(0, 160); break; }
        } catch (e) { apiBody = 'err ' + e.message; }
      }
      const b = document.body;
      const html = b ? b.innerHTML : '';
      const hasSend = /傳送訊息|Send message|Send a message/i.test(html);
      const loggedIn = apiStatus !== 401 && !/Authentication required/.test(apiBody) && hasSend;
      return JSON.stringify({ loggedIn, api: apiStatus, hasSend,
                              visibility: document.visibilityState,
                              url: location.href, apiBody });
    })();
    """

    /// 探測某個帳號現在的登入狀態，並回寫 `loggedIn`。
    /// 只在「當前、且視窗可見」的帳號上跑：隱藏時 Next.js 不 hydrate，DOM 沒有輸入框會被誤判成登出。
    func scheduleLoginProbe(for index: Int, force: Bool = false) {
        if DEMO { return }        // 示範資料沒有真的 cookie，探測只會把圓點刷成灰色
        guard accounts.indices.contains(index), index == current else { return }
        guard window.isVisible else { return }
        let acc = accounts[index]
        guard let w = webViews[acc.storeID], w.url?.host?.contains("muse.ai") == true else { return }
        guard !loginProbeBusy.contains(acc.storeID) else { return }
        if !force, let t = loginProbeAt[acc.storeID],
           Date().timeIntervalSince(t) < loginProbeInterval { return }
        loginProbeBusy.insert(acc.storeID)
        loginProbeAt[acc.storeID] = Date()
        let storeID = acc.storeID

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak w] in
            guard let self, let w, w.url?.host?.contains("muse.ai") == true else {
                self?.loginProbeBusy.remove(storeID)
                return
            }
            w.callAsyncJavaScript(self.loginProbeJS, arguments: [:], in: nil, in: .page) { r in
                self.loginProbeBusy.remove(storeID)
                guard case .success(let v) = r, let text = v as? String,
                      let data = text.data(using: .utf8),
                      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let idx = self.accounts.firstIndex(where: { $0.storeID == storeID }) else { return }
                let loggedIn = (obj["loggedIn"] as? Bool) ?? false
                let api = (obj["api"] as? Int) ?? 0
                self.lastProbe[storeID] = loggedIn
                let changed = self.accounts[idx].loggedIn != loggedIn
                print("LOGIN_PROBE name=\(self.accounts[idx].name) loggedIn=\(loggedIn) api=\(api) changed=\(changed)")
                guard changed else { return }
                self.accounts[idx].loggedIn = loggedIn
                Store.save(self.accounts)
                self.rebuildCards()
                if idx == self.current {
                    self.statusLabel.stringValue = loggedIn
                        ? "\(self.accounts[idx].name) 已登入"
                        : "⚠︎ \(self.accounts[idx].name) 的登入已失效（cookie 可能過期）"
                }
            }
        }
    }

    /// 比對對話列表指紋，找出「登入同一個 Muse 帳號」的重複項。
    /// 回傳 [重複者索引: 最早那個索引]，以編號小者為基準。
    func duplicateMap() -> [Int: Int] {
        let order = accounts.indices.sorted { accounts[$0].slot < accounts[$1].slot }
        var result: [Int: Int] = [:]
        for (pos, idx) in order.enumerated() where accounts[idx].hasUsableFp {
            // 跟編號較小的帳號比，第一個像的就是「原帳號」
            for prev in order.prefix(pos) where accounts[idx].sameAccount(as: accounts[prev]) {
                result[idx] = prev
                break
            }
        }
        return result
    }

    func rebuildCards() {
        for v in cardStack.arrangedSubviews {
            cardStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        // 徽章用「帳號在 accounts 陣列中的固定位置」，換組不會改編號
        var temp = [AccountCard?](repeating: nil, count: accounts.count)
        var lastGroup = ""
        let dups = duplicateMap()
        for idx in visualOrder {
            let acc = accounts[idx]
            if acc.group != lastGroup {
                cardStack.addArrangedSubview(SectionHeader(acc.group))
                lastGroup = acc.group
            }
            let dup = dups[idx].map { (slot: accounts[$0].slot, name: accounts[$0].name) }
            let card = AccountCard(account: acc, index: acc.slot - 1, shortcutModifier: "⇧", duplicateOf: dup)
            card.onClick = { [weak self] in self?.select(idx) }
            card.isSelected = (idx == current)
            temp[idx] = card
            cardStack.addArrangedSubview(card)
        }
        cards = temp.compactMap { $0 }
        countBadge.text = "\(accounts.count)"
        hotKeys.register(count: accounts.count)
    }

    func updateCount() {
        countBadge.text = "\(accounts.count)"
    }

    // MARK: 切換

    func select(_ index: Int) {
        guard index >= 0 && index < accounts.count else { return }
        current = index
        for (i, card) in cards.enumerated() { card.isSelected = (i == index) }
        contentHost.subviews.forEach { $0.removeFromSuperview() }

        let w = webView(for: index)
        w.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(w)
        NSLayoutConstraint.activate([
            w.topAnchor.constraint(equalTo: contentHost.topAnchor),
            w.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            w.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            w.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        if w.url == nil { w.load(URLRequest(url: url)) }
        lastActiveAt[accounts[index].storeID] = Date()   // 這個帳號現在是「在用」，不准被釋放
        scheduleFingerprint(for: index)
        scheduleLoginProbe(for: index)
        window.title = "MuseDock — \(accounts[index].name)"
        statusLabel.stringValue = "⇧⌘\(index + 1) 切換 · \(accounts[index].name)"
    }

    func selectHotKey(_ n: Int) {
        guard let idx = accounts.firstIndex(where: { $0.slot == n }) else { return }
        select(idx)
    }

    // MARK: 省資源（閒置釋放）

    /// tick 取「釋放門檻的 1/5」：預設 10 分鐘 → 每 60 秒掃一次；
    /// 自測設 10 秒 → 每 2 秒掃一次，不必等一分鐘才知道有沒有生效。
    func startIdleTimer() {
        let tick = min(60, max(1, idleReleaseAfter / 5))
        idleTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            self?.releaseIdleWebViews()
        }
        t.tolerance = tick * 0.2        // 省電：允許系統合併計時器
        idleTimer = t
        print("IDLE_TIMER tick=\(Int(tick))s releaseAfter=\(Int(idleReleaseAfter))s")
    }

    func releaseIdleWebViews() {
        guard !accounts.isEmpty, accounts.indices.contains(current) else { return }
        let keep = accounts[current].storeID
        let now = Date()
        // 先收成陣列再處理：走訪字典的同時改字典不安全
        let candidates = webViews.keys.filter { $0 != keep }
        for storeID in candidates {
            let idle = now.timeIntervalSince(lastActiveAt[storeID] ?? now)
            guard idle >= idleReleaseAfter else { continue }
            releaseWebView(storeID: storeID, reason: "idle=\(Int(idle))s")
        }
    }

    /// 丟掉 WebView，但**保留 storeID 與磁碟上的 WKWebsiteDataStore**：
    /// 下次切回來 cookie 還在，等於只是重新載入頁面，不會被登出。
    func releaseWebView(storeID: String, reason: String) {
        guard let w = webViews.removeValue(forKey: storeID) else { return }
        w.stopLoading()
        w.navigationDelegate = nil      // 斷開 delegate，讓 WKWebView 能被完整回收
        w.removeFromSuperview()
        // 重建的頁面是全新載入，舊的節流／忙碌標記不該延用，否則登入狀態會停在釋放前
        loginProbeAt.removeValue(forKey: storeID)
        fpAt.removeValue(forKey: storeID)
        let name = accounts.first(where: { $0.storeID == storeID })?.name ?? "?"
        print("RELEASE name=\(name) \(reason) remain=\(webViews.count)")
    }

    /// 自測：`MUSE_IDLE_TEST=1 MUSE_IDLE_RELEASE_SEC=10`
    /// 開 1 號 → 切到 2 號 → 等門檻過去，1 號的 WebView 應該被釋放、2 號留下。
    func runIdleTest() {
        guard accounts.count >= 2 else { print("IDLE_TEST need two accounts"); exit(9) }
        window.orderFrontRegardless()          // 要真的可見，WKWebView 才會載入
        select(0)
        print("IDLE_TEST step1 select=\(accounts[0].name)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            print("IDLE_TEST step2 switch=\(self.accounts[1].name) webViews=\(self.webViews.count)")
            self.select(1)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + self.idleReleaseAfter + 20) {
            let names = self.webViews.keys.compactMap { id in
                self.accounts.first(where: { $0.storeID == id })?.name
            }
            print("IDLE_TEST end webViews=\(self.webViews.count) keep=\(names)")
            let released = self.webViews.count == 1
            print("IDLE_TEST result1 \(released ? "PASS" : "FAIL")（閒置者已釋放）")

            // 回到被釋放的帳號：cookie 在磁碟上，應該直接載入已登入頁面
            self.lastProbe[self.accounts[0].storeID] = nil      // 清掉舊結果，只認這次探測
            self.select(0)
            print("IDLE_TEST rehydrate select=\(self.accounts[0].name) webViews=\(self.webViews.count)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 18) {
                let back = self.lastProbe[self.accounts[0].storeID] == true
                print("IDLE_TEST rehydrate name=\(self.accounts[0].name) loggedIn=\(String(describing: self.lastProbe[self.accounts[0].storeID])) webViews=\(self.webViews.count)")
                print("IDLE_TEST result2 \(back ? "PASS" : "FAIL")（重建後仍登入）")
                exit((released && back) ? 0 : 7)
            }
        }
    }

    func webView(for index: Int) -> WKWebView {
        let acc = accounts[index]
        if let w = webViews[acc.storeID] { return w }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = WKWebsiteDataStore(forIdentifier: UUID(uuidString: acc.storeID)!)
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        if PROBE_MODE {
            let probe = """
            window.__errs = [];
            window.addEventListener('error', function(e){ try { window.__errs.push('error: ' + (e.message||'') + ' @' + (e.filename||'').split('/').pop() + ':' + (e.lineno||0)); } catch(_){} }, true);
            window.addEventListener('unhandledrejection', function(e){ try { window.__errs.push('reject: ' + (e.reason && e.reason.message ? e.reason.message : String(e.reason))); } catch(_){} });
            (function(){ var oe = console.error; console.error = function(){ try { window.__errs.push('cerr: ' + Array.prototype.map.call(arguments, function(x){ try { return typeof x === 'string' ? x : (x && x.message) || JSON.stringify(x); } catch(_) { return String(x); } }).join(' ')); } catch(_){}; return oe.apply(console, arguments); }; })();
            """
            cfg.userContentController.addUserScript(WKUserScript(source: probe,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let w = WKWebView(frame: .zero, configuration: cfg)
        if let ua = ProcessInfo.processInfo.environment["MUSE_UA"] { w.customUserAgent = ua }
        w.navigationDelegate = self
        w.allowsBackForwardNavigationGestures = true
        webViews[acc.storeID] = w
        lastActiveAt[acc.storeID] = Date()
        if webViews.count > 1 { print("WEBVIEW rebuilt name=\(acc.name) total=\(webViews.count)") }
        return w
    }

    // MARK: 空狀態

    func showEmptyState() {
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(box)

        let avatar = AvatarView(name: "Muse", diameter: 68)
        let title = NSTextField(labelWithString: "Muse · Meta")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        let sub = NSTextField(wrappingLabelWithString: "從左側選擇帳號開始對話，或新增一個獨立隔離空間。")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = .secondaryLabelColor
        sub.alignment = .center
        sub.maximumNumberOfLines = 2
        let btn = AccentButton("新增 Muse 帳號", symbol: "plus", fontSize: 12.5, height: 30,
                               target: self, action: #selector(addAccount))

        let stack = NSStackView(views: [avatar, title, sub, btn])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(18, after: title)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)

        NSLayoutConstraint.activate([
            box.topAnchor.constraint(equalTo: contentHost.topAnchor),
            box.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -30),
            sub.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
        window.title = "MuseDock"
    }

    // MARK: 選單

    func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        let auto = NSMenuItem(title: launchAtLoginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        auto.target = self
        auto.state = launchAtLogin ? .on : .off
        appMenu.addItem(auto)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "結束 MuseDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let acctItem = NSMenuItem()
        main.addItem(acctItem)
        let acctMenu = NSMenu(title: "帳號")
        let dups = duplicateMap()
        for idx in visualOrder where accounts[idx].slot <= 9 {
            let acc = accounts[idx]
            var title = "\(acc.name)（\(acc.group)）"
            if let d = dups[idx] { title += "⚠︎ 同 \(accounts[d].slot) 號" }
            let it = NSMenuItem(title: title, action: #selector(switchTo(_:)),
                                keyEquivalent: "\(acc.slot)")
            it.tag = idx
            it.target = self
            acctMenu.addItem(it)
        }
        acctMenu.addItem(.separator())
        let addItem = NSMenuItem(title: "新增帳號…", action: #selector(addAccount), keyEquivalent: "n")
        addItem.target = self
        acctMenu.addItem(addItem)
        acctItem.submenu = acctMenu

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "檢視")
        let reload = NSMenuItem(title: "重新載入", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        viewMenu.addItem(reload)
        let browser = NSMenuItem(title: "在瀏覽器打開", action: #selector(openInBrowser), keyEquivalent: "o")
        browser.target = self
        viewMenu.addItem(browser)
        viewItem.submenu = viewMenu

        NSApp.mainMenu = main
    }

    // MARK: - 選單列常駐

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let img = NSImage(systemSymbolName: "rectangle.stack.fill",
                              accessibilityDescription: "MuseDock")?
                .withSymbolConfiguration(cfg)
            img?.isTemplate = true
            button.image = img
            button.toolTip = "MuseDock — 點一下切換帳號"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == statusItem?.menu else { return }
        rebuildStatusMenu(menu)
    }

    func rebuildStatusMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let head = NSMenuItem(title: accounts.indices.contains(current)
                                ? "MuseDock · \(accounts[current].name)" : "MuseDock",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        let dups = duplicateMap()
        for idx in visualOrder {
            let acc = accounts[idx]
            let dup = dups[idx]
            var title = "\(acc.name)　⇧⌘\(acc.slot)"
            if let d = dup { title += "　⚠︎ 同 \(accounts[d].slot) 號" }
            let it = NSMenuItem(title: title, action: #selector(statusPick(_:)), keyEquivalent: "")
            it.target = self
            it.tag = idx
            it.state = idx == current ? .on : .off
            it.image = statusDot(loggedIn: acc.loggedIn)
            var tips: [String] = []
            if !acc.profileDir.isEmpty { tips.append("Chrome \(acc.profileDir)") }
            if acc.email.contains("@") { tips.append(acc.email) }
            tips.append(acc.loggedIn ? "已登入" : "未登入")
            if let d = dup {
                tips.append("與 \(accounts[d].slot) 號（\(accounts[d].name)）是同一個 Muse 帳號")
            }
            it.toolTip = tips.joined(separator: " · ")
            menu.addItem(it)
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: window.isVisible ? "隱藏視窗" : "顯示視窗",
                                action: #selector(toggleWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let reload = NSMenuItem(title: "重新載入", action: #selector(reloadPage), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)

        let chrome = NSMenuItem(title: "從 Chrome 匯入", action: nil, keyEquivalent: "")
        chrome.submenu = chromeSubmenu()
        menu.addItem(chrome)

        let add = NSMenuItem(title: "新增帳號…", action: #selector(addAccount), keyEquivalent: "")
        add.target = self
        menu.addItem(add)

        menu.addItem(.separator())
        let auto = NSMenuItem(title: launchAtLoginTitle, action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        auto.target = self
        auto.state = launchAtLogin ? .on : .off
        menu.addItem(auto)
        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 MuseDock", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
    }

    private func statusDot(loggedIn: Bool) -> NSImage {
        let d: CGFloat = 9
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        (loggedIn ? NSColor.systemGreen : NSColor.tertiaryLabelColor).setFill()
        NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: d - 1, height: d - 1)).fill()
        img.unlockFocus()
        return img
    }

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 視窗重新可見時補一次探測（隱藏時 Next.js 不 hydrate，量不準）
        scheduleLoginProbe(for: current)
    }

    // MARK: 開機自動啟動

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    /// 選單文字（需要系統批准時多給一句提示）
    var launchAtLoginTitle: String {
        switch SMAppService.mainApp.status {
        case .requiresApproval: return "開機時自動啟動（需在系統設定允許）"
        default: return "開機時自動啟動"
        }
    }

    @objc func toggleLaunchAtLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
                statusLabel.stringValue = "已關閉開機自動啟動"
                print("AUTOSTART off status=\(svc.status.rawValue)")
            } else {
                try svc.register()
                statusLabel.stringValue = svc.status == .requiresApproval
                    ? "請到「系統設定 › 一般 › 登入項目」允許 MuseDock"
                    : "已設定開機自動啟動"
                print("AUTOSTART on status=\(svc.status.rawValue)")
            }
        } catch {
            print("AUTOSTART err \(error.localizedDescription) status=\(svc.status.rawValue)")
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "無法設定開機自動啟動"
            a.informativeText = "\(error.localizedDescription)\n\n請確認 MuseDock 位於「應用程式」資料夾；若系統要求，請到「系統設定 › 一般 › 登入項目」允許。"
            a.addButton(withTitle: "好")
            a.runModal()
        }
        buildMenu()
    }

    /// 命令列自測：MUSE_AUTOSTART=status|on|off
    func autostartCLI(_ cmd: String) {
        let svc = SMAppService.mainApp
        switch cmd {
        case "on":
            do { try svc.register() } catch { print("AUTOSTART_ERR \(error.localizedDescription)") }
        case "off":
            do { try svc.unregister() } catch { print("AUTOSTART_ERR \(error.localizedDescription)") }
        default:
            break
        }
        let state: String
        switch svc.status {
        case .enabled: state = "enabled"
        case .requiresApproval: state = "requiresApproval"
        case .notRegistered: state = "notRegistered"
        case .notFound: state = "notFound"
        @unknown default: state = "unknown(\(svc.status.rawValue))"
        }
        print("AUTOSTART cmd=\(cmd) status=\(state)")
    }

    @objc func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showWindow()
        }
    }

    @objc func statusPick(_ sender: NSMenuItem) {
        showWindow()
        select(sender.tag)
    }

    /// 「從 Chrome 匯入」子選單（側邊欄與選單列共用）
    func chromeSubmenu() -> NSMenu {
        let sub = NSMenu()
        chromeProfiles = ChromeCookies.profiles()
        if chromeProfiles.isEmpty {
            let none = NSMenuItem(title: "找不到 Chrome Profile", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
            return sub
        }
        for (i, p) in chromeProfiles.enumerated() {
            let title = p.cookieCount <= 0
                ? "\(p.name) — \(p.dir)（無 muse cookie）"
                : "\(p.name) — \(p.dir) · \(p.cookieCount) 筆"
            let it = NSMenuItem(title: title, action: #selector(importChromeProfile(_:)), keyEquivalent: "")
            it.target = self
            it.tag = i
            it.isEnabled = p.cookieCount > 0 && !accounts.isEmpty
            it.toolTip = (p.email.isEmpty ? "" : p.email + " · ") + "上次使用 \(p.lastUsedText)"
            if accounts.indices.contains(current),
               ChromeCookies.profile(matching: accounts[current].name, in: chromeProfiles)?.dir == p.dir {
                it.state = .on
            }
            sub.addItem(it)
        }
        sub.addItem(.separator())
        let refresh = NSMenuItem(title: "重新掃描", action: #selector(refreshChromeList), keyEquivalent: "")
        refresh.target = self
        sub.addItem(refresh)
        return sub
    }

    @objc func showMoreMenu(_ sender: NSButton) {
        let m = NSMenu()

        // 直接從 Chrome Profile 匯入（不必先手動匯出 cookies.txt）
        let chromeItem = NSMenuItem(title: "從 Chrome 匯入", action: nil, keyEquivalent: "")
        chromeItem.submenu = chromeSubmenu()
        m.addItem(chromeItem)

        let importItem = NSMenuItem(title: "從 cookies.txt 匯入…", action: #selector(importCookies), keyEquivalent: "")
        importItem.target = self
        m.addItem(importItem)
        let rename = NSMenuItem(title: "重新命名…", action: #selector(renameAccount), keyEquivalent: "")
        rename.target = self
        m.addItem(rename)
        if !accounts.isEmpty {
            let target = accounts[current].group == Account.mainGroup ? Account.backupGroup : Account.mainGroup
            let move = NSMenuItem(title: "移至「\(target)」", action: #selector(moveGroup), keyEquivalent: "")
            move.target = self
            m.addItem(move)
        }
        m.addItem(.separator())
        let wipe = NSMenuItem(title: "清除此帳號資料", action: #selector(wipe), keyEquivalent: "")
        wipe.target = self
        m.addItem(wipe)
        m.addItem(.separator())
        let del = NSMenuItem(title: "刪除帳號…", action: #selector(deleteAccount), keyEquivalent: "")
        del.target = self
        m.addItem(del)
        let b = sender
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    // MARK: 動作

    @objc func switchTo(_ sender: NSMenuItem) { select(sender.tag) }
    @objc func reloadPage() { webView(for: current).reload() }

    @objc func openInBrowser() {
        guard !accounts.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func addAccount() {
        let alert = NSAlert()
        alert.messageText = "新增 Muse 帳號"
        alert.informativeText = "建立後會開啟一個獨立的隔離空間，可再用「匯入 Cookie」帶入登入態。"
        alert.addButton(withTitle: "建立")
        alert.addButton(withTitle: "取消")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        let field = NSTextField(frame: NSRect(x: 0, y: 34, width: 260, height: 24))
        field.placeholderString = "帳號名稱"
        field.stringValue = "帳號 \(accounts.count + 1)"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24), pullsDown: false)
        popup.addItems(withTitles: [Account.mainGroup, Account.backupGroup])
        popup.selectItem(at: 1)
        box.addSubview(field)
        box.addSubview(popup)
        alert.accessoryView = box
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = field.stringValue.isEmpty ? "帳號 \(accounts.count + 1)" : field.stringValue
        let group = popup.indexOfSelectedItem == 0 ? Account.mainGroup : Account.backupGroup
        let nextSlot = (accounts.map(\.slot).max() ?? 0) + 1
        accounts.append(Account(name: name, email: "未登入", storeID: UUID().uuidString,
                                group: group, slot: nextSlot))
        Store.save(accounts)
        rebuildCards()
        buildMenu()
        select(accounts.count - 1)
    }

    @objc func renameAccount() {
        guard !accounts.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "重新命名"
        alert.addButton(withTitle: "儲存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = accounts[current].name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        accounts[current].name = field.stringValue
        Store.save(accounts)
        rebuildCards()
        buildMenu()
        select(current)
    }

    @objc func deleteAccount() {
        guard !accounts.isEmpty else { return }
        let acc = accounts[current]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "刪除「\(acc.name)」？"
        alert.informativeText = "會一併清除它的登入態與網站資料（該帳號的獨立儲存空間），無法復原。編號 \(acc.slot) 不會被後面的帳號重用。"
        alert.addButton(withTitle: "刪除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performDelete(at: current)
    }

    /// 真正執行刪除（含清空 WebKit 資料目錄）。UI 與自測入口共用同一份。
    func performDelete(at index: Int, onPurged: ((_ removed: Bool, _ detail: String) -> Void)? = nil) {
        guard accounts.indices.contains(index) else { return }
        let acc = accounts[index]

        webViews[acc.storeID]?.stopLoading()
        webViews[acc.storeID]?.removeFromSuperview()
        webViews[acc.storeID] = nil

        // 先讓 WebKit 清 cookie/localStorage，再把它沒清掉的快取目錄整個刪掉
        let beforeSize = Store.websiteDataSize(for: acc.storeID)
        var purged = false
        func purge() {
            guard !purged else { return }
            purged = true
            Store.purgeWebsiteDataDir(for: acc.storeID) { [weak self] removed, detail in
                let freed = beforeSize.map { "，釋放 \($0)" } ?? ""
                self?.statusLabel.stringValue = removed
                    ? "已刪除 \(acc.name)（編號 ⇧\(acc.slot) 保留不重用）\(freed)"
                    : "已刪除 \(acc.name)，但資料目錄殘留（\(detail)）"
                print("PURGE slot=\(acc.slot) store=\(acc.storeID) removed=\(removed) \(detail)")
                onPurged?(removed, detail)
            }
        }
        if let id = UUID(uuidString: acc.storeID) {
            WKWebsiteDataStore(forIdentifier: id)
                .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                            modifiedSince: .distantPast) { purge() }
            // removeData 遲遲沒回呼也不卡住清理
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { purge() }
        } else {
            purge()
        }

        accounts.remove(at: index)
        Store.save(accounts)
        rebuildCards()
        buildMenu()
        if accounts.isEmpty {
            current = 0
            showEmptyState()
        } else {
            if index < current { current -= 1 }
            current = min(current, accounts.count - 1)
            select(current)
        }
        statusLabel.stringValue = "已刪除 \(acc.name)，正在清除網站資料…"
    }

    @objc func moveGroup() {
        guard !accounts.isEmpty else { return }
        let target = accounts[current].group == Account.mainGroup ? Account.backupGroup : Account.mainGroup
        accounts[current].group = target
        Store.save(accounts)
        rebuildCards()
        buildMenu()
        select(current)
        statusLabel.stringValue = "\(accounts[current].name) → \(target)"
    }

    @objc func wipe() {
        guard !accounts.isEmpty else { return }
        wipeAccount(at: current)
    }

    /// 清除某個帳號的網站資料（保留帳號），同樣補刀刪掉 WebKit 留下的快取目錄。
    /// 與 `performDelete` 的差別：這裡帳號還在，所以清完會重建一個乾淨的 WebView。
    func wipeAccount(at index: Int, done: ((_ removed: Bool, _ detail: String) -> Void)? = nil) {
        guard accounts.indices.contains(index) else { done?(false, "invalid index"); return }
        let acc = accounts[index]
        let storeID = acc.storeID
        guard let uuid = UUID(uuidString: storeID) else {
            done?(false, "invalid storeID"); return
        }
        let beforeSize = Store.websiteDataSize(for: storeID)
        WKWebsiteDataStore(forIdentifier: uuid)
            .removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                        modifiedSince: .distantPast) { [weak self] in
                guard let self else { return }
                self.webViews[storeID]?.stopLoading()
                self.webViews[storeID]?.removeFromSuperview()
                self.webViews[storeID] = nil
                if self.accounts.indices.contains(index) { self.accounts[index].loggedIn = false }
                Store.save(self.accounts)
                self.rebuildCards()
                self.statusLabel.stringValue = "已清除 \(acc.name) 的網站資料，正在清快取目錄…"

                Store.purgeWebsiteDataDir(for: storeID) { [weak self] removed, detail in
                    guard let self else { return }
                    let freed = beforeSize.map { "，釋放 \($0)" } ?? ""
                    self.statusLabel.stringValue = removed
                        ? "已清除 \(acc.name) 的所有網站資料（含快取目錄）\(freed)"
                        : "已清除 \(acc.name) 的資料，但目錄殘留（\(detail)）"
                    print("WIPE slot=\(acc.slot) store=\(storeID) removedDir=\(removed) \(detail)")
                    // 重建乾淨的 WebView（會讓 WebKit 重新建立一個空目錄）
                    if self.webViews[storeID] == nil, self.accounts.indices.contains(index) {
                        self.select(index)
                    }
                    done?(removed, detail)
                }
            }
    }

    // MARK: 匯入

    /// 把 cookie 寫進某個帳號的隔離存儲，並重新載入頁面
    func install(cookies: [HTTPCookie], into idx: Int, source: String,
                 email: String = "", profileDir: String = "") {
        guard accounts.indices.contains(idx) else { return }
        let acc = accounts[idx]
        guard let uuid = UUID(uuidString: acc.storeID) else { return }
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        let group = DispatchGroup()
        for c in cookies { group.enter(); store.httpCookieStore.setCookie(c) { group.leave() } }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.accounts[idx].loggedIn = true
            if email.contains("@") { self.accounts[idx].email = email }
            if !profileDir.isEmpty { self.accounts[idx].profileDir = profileDir }
            Store.save(self.accounts)
            self.rebuildCards()
            self.select(idx)
            self.statusLabel.stringValue = "已從\(source)匯入 \(cookies.count) 筆 cookie 到 \(acc.name)"
            self.webViews[acc.storeID]?.load(URLRequest(url: self.url))
        }
    }

    @objc func refreshChromeList() {
        chromeProfiles = ChromeCookies.profiles()
        let n = chromeProfiles.filter { $0.cookieCount > 0 }.count
        statusLabel.stringValue = "掃描到 \(chromeProfiles.count) 個 Chrome Profile，其中 \(n) 個有 muse cookie"
    }

    /// 用 Chrome Profile 補齊帳號的來源資訊（Profile 目錄 + email），只補空的
    func syncChromeIdentity() {
        guard ChromeCookies.isInstalled else { return }
        let list = ChromeCookies.profiles()
        var changed = false
        for i in accounts.indices {
            guard let p = ChromeCookies.profile(matching: accounts[i].name, in: list) else { continue }
            if accounts[i].profileDir.isEmpty {
                accounts[i].profileDir = p.dir
                changed = true
            }
            if !accounts[i].email.contains("@"), p.email.contains("@") {
                accounts[i].email = p.email
                changed = true
            }
        }
        if changed { Store.save(accounts) }
    }

    /// 依編號清除網站資料（保留帳號），供自測使用。走的是 UI 的同一條路徑。
    func wipeBySlot(slot: Int) {
        guard let idx = accounts.firstIndex(where: { $0.slot == slot }) else {
            print("ERR_NO_SLOT \(slot)"); exit(3)
        }
        let name = accounts[idx].name
        let storeID = accounts[idx].storeID
        let before = Store.websiteDataSize(for: storeID) ?? "none"
        print("WIPING slot=\(slot) name=\(name) dir_before=\(before)")
        wipeAccount(at: idx) { removed, detail in
            print("WIPE_DIR removed=\(removed) \(detail) (before \(before))")
            let after = Store.websiteDataSize(for: storeID) ?? "none"
            print("DIR_AFTER \(after)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { print("WIPE timeout"); exit(0) }
    }

    /// 依編號移除帳號並清空其隔離存儲（供自測／維護使用）。走的是 UI 刪除的同一條路徑。
    func dropAccount(slot: Int) {
        guard let idx = accounts.firstIndex(where: { $0.slot == slot }) else {
            print("ERR_NO_SLOT \(slot)"); exit(3)
        }
        let name = accounts[idx].name
        let storeID = accounts[idx].storeID
        let before = Store.websiteDataSize(for: storeID) ?? "none"
        print("DROPPING slot=\(slot) name=\(name) dir_before=\(before)")
        performDelete(at: idx) { removed, detail in
            print("PURGE_DIR removed=\(removed) \(detail) (before \(before))")
            exit(0)
        }
        print("DROPPED slot=\(slot) name=\(name) remain=\(accounts.count)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            print("DROP timeout"); exit(0)
        }
    }

    /// 診斷用：載入指定編號帳號並輸出頁面上的帳號資訊
    func probeWho(slot: Int) {
        guard let idx = accounts.firstIndex(where: { $0.slot == slot }) else {
            print("ERR_SLOT \(slot)"); exit(3)
        }
        print("WHO_START slot=\(slot) name=\(accounts[idx].name)")
        select(idx)
    }

    /// 命令列自測用：把頁面上所有可能是頭像的資源倒出來（img / 背景圖 / avatar 容器）
    func probeAvatar(slot: Int) {
        guard let idx = accounts.firstIndex(where: { $0.slot == slot }) else {
            print("ERR_SLOT \(slot)"); exit(3)
        }
        print("AVATAR_START slot=\(slot) name=\(accounts[idx].name) store=\(accounts[idx].storeID)")
        select(idx)
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
            print("AVATAR_TIMEOUT")
            exit(6)
        }
    }

    /// 命令列自測用：直接從某個 Chrome Profile 匯入到同名帳號
    func applyChromeImport(dir: String) {
        chromeProfiles = ChromeCookies.profiles()
        guard let p = chromeProfiles.first(where: { $0.dir == dir }) else {
            print("ERR_NO_PROFILE \(dir)"); exit(3)
        }
        guard !accounts.isEmpty else { print("ERR_NO_ACCOUNT"); exit(4) }
        let idx = accounts.firstIndex { $0.name == p.name }
            ?? accounts.firstIndex { $0.name.lowercased() == p.name.lowercased() } ?? current
        print("CHROME_APPLY dir=\(dir) profile=\(p.name) target=\(accounts[idx].name)")
        do {
            let cookies = try ChromeCookies.cookies(for: dir)
            print("CHROME_APPLY cookies=\(cookies.count)")
            install(cookies: cookies, into: idx, source: " \(dir) ", email: p.email, profileDir: dir)
        } catch {
            print("CHROME_APPLY_ERR \(error.localizedDescription)")
            exit(9)
        }
    }

    @objc func importChromeProfile(_ sender: NSMenuItem) {
        guard chromeProfiles.indices.contains(sender.tag), !accounts.isEmpty else { return }
        let p = chromeProfiles[sender.tag]

        // 同名帳號就直接匯進去，否則問一下
        var target = accounts.firstIndex { $0.name == p.name }
            ?? accounts.firstIndex { $0.name.lowercased() == p.name.lowercased() }
        if target == nil {
            let alert = NSAlert()
            alert.messageText = "要匯入到哪個帳號？"
            alert.informativeText = "\(p.dir)（\(p.name)）有 \(p.cookieCount) 筆 muse.ai cookie。"
            alert.addButton(withTitle: "匯入到「\(accounts[current].name)」")
            alert.addButton(withTitle: "建立新帳號「\(p.name)」")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                target = current
            case .alertSecondButtonReturn:
                let slot = (accounts.map(\.slot).max() ?? 0) + 1
                accounts.append(Account(name: p.name, email: p.email.isEmpty ? "未登入" : p.email,
                                        storeID: UUID().uuidString,
                                        group: Account.backupGroup, slot: slot,
                                        profileDir: p.dir))
                Store.save(accounts)
                target = accounts.count - 1
            default:
                return
            }
        }
        guard let idx = target else { return }

        statusLabel.stringValue = "正在解密 \(p.dir) 的 cookie…"
        let dir = p.dir
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let cookies = try ChromeCookies.cookies(for: dir)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.rebuildCards()
                    self.install(cookies: cookies, into: idx, source: " \(dir) ", email: p.email, profileDir: dir)
                    self.buildMenu()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.statusLabel.stringValue = "匯入失敗：\(error.localizedDescription)"
                    let a = NSAlert()
                    a.alertStyle = .warning
                    a.messageText = "匯入失敗"
                    a.informativeText = error.localizedDescription
                    a.runModal()
                }
            }
        }
    }

    @objc func importCookies() {
        guard !accounts.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "選擇 cookies.txt（Netscape 格式）"
        guard panel.runModal() == .OK, let f = panel.url else { return }
        guard let text = try? String(contentsOf: f, encoding: .utf8) else {
            statusLabel.stringValue = "讀不到檔案"; return
        }
        let cookies = CookieParser.parse(netscape: text)
        guard !cookies.isEmpty else {
            statusLabel.stringValue = "檔案裡沒有可用 cookie"; return
        }
        install(cookies: cookies, into: current, source: "檔案")
    }

    // MARK: 命令列匯入測試（MUSE_IMPORT_FILE / MUSE_IMPORT_ACCOUNT）

    func runImport(account key: String, file: String) {
        guard let idx = accounts.firstIndex(where: { String($0.slot) == key || $0.name == key }) else {
            print("ERR_NO_ACCOUNT key=\(key)")
            exit(3)
        }
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            print("ERR_READ_FILE \(file)")
            exit(4)
        }
        let cookies = CookieParser.parse(netscape: text)
        let acc = accounts[idx]
        print("IMPORT account=\(acc.name) slot=\(acc.slot) parsed=\(cookies.count)")
        guard !cookies.isEmpty else { exit(5) }

        let store = WKWebsiteDataStore(forIdentifier: UUID(uuidString: acc.storeID)!)
        let g = DispatchGroup()
        for c in cookies { g.enter(); store.httpCookieStore.setCookie(c) { g.leave() } }
        g.notify(queue: .main) {
            store.httpCookieStore.getAllCookies { list in
                let muse = list.filter { $0.domain.contains("muse") }
                print("STORE total=\(list.count) muse=\(muse.count) sess=\(muse.contains { $0.name == "hatch_sess" })")
                if idx < self.accounts.count {
                    self.accounts[idx].loggedIn = true
                    Store.save(self.accounts)
                }
                self.select(idx)
                self.webView(for: idx).load(URLRequest(url: URL(string: "https://muse.ai")!))
                DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                    print("RESULT timeout")
                    exit(6)
                }
            }
        }
    }

    // MARK: 生命週期

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.host?.contains("muse.ai") == true,
           let idx = accounts.firstIndex(where: { webViews[$0.storeID] === webView }) {
            scheduleFingerprint(for: idx)
            scheduleLoginProbe(for: idx)
        }
        if AVATAR_SLOT != nil && !avatarFired && webView.url?.host?.contains("muse.ai") == true {
            avatarFired = true
            let wait = Double(ProcessInfo.processInfo.environment["MUSE_PROBE_WAIT"] ?? "12") ?? 12
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let js = """
                return await (async () => {
                  const box = (el) => { const r = el.getBoundingClientRect();
                    return { w: Math.round(r.width), h: Math.round(r.height) }; };
                  const out = { href: location.href, imgCount: 0, imgs: [], bgs: [], cands: [],
                                hatch: [], canvases: 0, blobs: [] };
                  const chain = (el) => {
                    const p = [];
                    let n = el.parentElement, i = 0;
                    while (n && i < 4) {
                      const ds = [...n.attributes].filter(a => a.name.startsWith('data-'))
                        .map(a => a.name + '=' + String(a.value).slice(0, 24)).join(' ');
                      p.push(n.tagName + '.' + String(n.className || '').split(' ').slice(0, 3).join('.') +
                             (ds ? ' {' + ds + '}' : ''));
                      n = n.parentElement; i++;
                    }
                    return p;
                  };
                  out.canvases = document.querySelectorAll('canvas').length;
                  const hatchEls = document.querySelectorAll('[data-hatch-avatar-interaction], [aria-label="Muse"]');
                  for (const el of [...hatchEls].slice(0, 3)) {
                    const b = box(el);
                    out.hatch.push({ w: b.w, h: b.h,
                      attrs: [...el.attributes].map(a => a.name + '=' + String(a.value).slice(0, 40)),
                      html: el.outerHTML.replace(/\\s+/g, ' ').slice(0, 700) });
                  }
                  const imgs = [...document.querySelectorAll('img')];
                  out.imgCount = imgs.length;
                  for (const i of imgs.slice(0, 40)) {
                    const b = box(i);
                    out.imgs.push({ src: String(i.currentSrc || i.src || '').slice(0, 200),
                                    cls: String(i.className || '').slice(0, 60),
                                    alt: String(i.alt || '').slice(0, 30),
                                    w: b.w, h: b.h, nw: i.naturalWidth, nh: i.naturalHeight,
                                    vis: i.offsetParent !== null, chain: chain(i) });
                  }
                  // 把前 3 張 blob 圖轉成 dataURL，看看實際畫的是什麼
                  for (const i of imgs.slice(0, 3)) {
                    try {
                      const s = i.currentSrc || i.src;
                      if (!s.startsWith('blob:')) continue;
                      const blob = await (await fetch(s)).blob();
                      const dataUrl = await new Promise(res => {
                        const fr = new FileReader();
                        fr.onload = () => res(String(fr.result));
                        fr.readAsDataURL(blob);
                      });
                      out.blobs.push({ type: blob.type, size: blob.size,
                                       head: dataUrl.slice(0, 80), full: dataUrl });
                    } catch (e) { out.blobs.push({ err: String(e) }); }
                  }
                  out.videos = [];
                  for (const v of document.querySelectorAll('video')) {
                    const r = v.getBoundingClientRect();
                    const info = { src: String(v.currentSrc || v.src || '').slice(0, 60),
                                   w: Math.round(r.width), h: Math.round(r.height),
                                   vw: v.videoWidth, vh: v.videoHeight, rs: v.readyState };
                    try {
                      const c = document.createElement('canvas');
                      c.width = v.videoWidth || 128;
                      c.height = v.videoHeight || 128;
                      c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
                      info.frame = c.toDataURL('image/png');
                    } catch (e) { info.err = String(e); }
                    out.videos.push(info);
                    if (out.videos.length >= 4) break;
                  }
                  if (typeof clickSel === 'string' && clickSel.length > 0) {
                    const target = document.querySelector(clickSel);
                    out.clicked = !!target;
                    if (target) {
                      target.click();
                      await new Promise(r => setTimeout(r, 1600));
                      out.after = {
                        imgCount: document.querySelectorAll('img').length,
                        imgs: [...document.querySelectorAll('img')]
                                .map(i => String(i.currentSrc || i.src || '').slice(0, 200)).slice(0, 10),
                        text: (document.body ? document.body.innerText : '')
                                .replace(/\\s+/g, ' ').slice(-800)
                      };
                    }
                  }
                  const seen = new Set();
                  for (const el of document.querySelectorAll('body *')) {
                    if (el.children.length > 2) continue;
                    const bg = getComputedStyle(el).backgroundImage;
                    if (!bg || bg === 'none' || bg.indexOf('url(') < 0 || seen.has(bg)) continue;
                    seen.add(bg);
                    const b = box(el);
                    if (b.w < 16 || b.h < 16) continue;
                    out.bgs.push({ bg: bg.slice(0, 200), tag: el.tagName,
                                   cls: String(el.className || '').slice(0, 60), w: b.w, h: b.h });
                  }
                  const sel = '[class*=avatar],[class*=Avatar],[data-testid*=avatar],[class*=profile],[class*=account],[aria-label*=ccount]';
                  for (const el of document.querySelectorAll(sel)) {
                    const b = box(el);
                    if (b.w < 8 || b.h < 8 || b.w > 600) continue;
                    out.cands.push({ tag: el.tagName, cls: String(el.className || '').slice(0, 70),
                                     w: b.w, h: b.h,
                                     html: el.innerHTML.replace(/\\s+/g, ' ').slice(0, 180) });
                    if (out.cands.length >= 24) break;
                  }
                  return JSON.stringify(out);
                })();
                """
                let sel = ProcessInfo.processInfo.environment["MUSE_AVATAR_CLICK"] ?? ""
                webView.callAsyncJavaScript(js, arguments: ["clickSel": sel], in: nil, in: .page) { r in
                    switch r {
                    case .success(let v): print("AVATAR \(v)")
                    case .failure(let e):
                        let ns = e as NSError
                        print("AVATAR_ERR \(e.localizedDescription)")
                        print("AVATAR_ERR_DETAIL \(ns.userInfo)")
                    }
                    let cfg = WKSnapshotConfiguration()
                    cfg.rect = webView.bounds
                    webView.takeSnapshot(with: cfg) { img, _ in
                        if let img, let tiff = img.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/avatar_\(self.accounts[self.current].slot).png"))
                        }
                        exit(0)
                    }
                }
            }
        }
        if WHO_SLOT != nil && !importFired && webView.url?.host?.contains("muse.ai") == true {
            importFired = true
            let wait = Double(ProcessInfo.processInfo.environment["MUSE_PROBE_WAIT"] ?? "12") ?? 12
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let js = """
                return await (async () => {
                  const html = document.documentElement.innerHTML;
                  const emails = [...new Set((html.match(/[\\w.+-]+@[\\w-]+\\.[\\w.]{2,}/g) || []))].slice(0, 12);
                  const emailFields = [...new Set((html.match(/"[a-z_]*email[a-z_]*"\\s*:\\s*"([^"@]+@[^"]+)"/gi) || []))].slice(0, 8);
                  const ls = {};
                  try {
                    for (let i = 0; i < localStorage.length; i++) {
                      const k = localStorage.key(i);
                      ls['LS:' + k] = String(localStorage.getItem(k) || '').slice(0, 60);
                    }
                    for (let i = 0; i < sessionStorage.length; i++) {
                      const k = sessionStorage.key(i);
                      ls['SS:' + k] = String(sessionStorage.getItem(k) || '').slice(0, 60);
                    }
                    if (window.indexedDB && indexedDB.databases) {
                      const dbs = await indexedDB.databases();
                      ls['IDB'] = dbs.map(d => d.name).join(',');
                    }
                  } catch (e) { ls['ERR'] = String(e); }
                  const avatars = [...document.querySelectorAll('img')]
                      .map(i => i.src).filter(s => /avatar|user|profile|googleusercontent|cdn/i.test(s)).slice(0, 4);
                  return JSON.stringify({url: location.href, emails, emailFields, ls, avatars,
                      title: document.title,
                      text: (document.body ? document.body.innerText : '').replace(/\\s+/g, ' ').slice(0, 260)});
                })();
                """
                webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { r in
                    switch r {
                    case .success(let v): print("WHO \(v)")
                    case .failure(let e): print("WHO_ERR \(e.localizedDescription)")
                    }
                    let cfg = WKSnapshotConfiguration()
                    cfg.rect = webView.bounds
                    webView.takeSnapshot(with: cfg) { img, _ in
                        if let img, let tiff = img.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/who_\(self.accounts[self.current].slot).png"))
                        }
                        exit(0)
                    }
                }
            }
        }

        if PROBE_MODE && !importFired && webView.url?.host?.contains("muse.ai") == true {
            importFired = true
            let wait = Double(ProcessInfo.processInfo.environment["MUSE_PROBE_WAIT"] ?? "8") ?? 8
            print("PROBE wait=\(wait)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                let js = """
                return await (async () => {
                  let apiBody = '';
                  let apiStatus = 0;
                  for (const p of ['/api/me', '/api/user', '/api/session']) {
                    try {
                      const r = await fetch(p, {credentials: 'include'});
                      apiStatus = r.status;
                      const t = await r.text();
                      if (r.status !== 404) { apiBody = p + ' => ' + t.slice(0, 200); break; }
                    } catch (e) { apiBody = 'err ' + e.message; }
                  }
                  const b = document.body;
                  const root = document.getElementById('__next') || document.querySelector('main') || null;
                  const html = b ? b.innerHTML : '';
                  const signedIn = apiStatus !== 401 && !/Authentication required/.test(apiBody)
                                   && /傳送訊息|Send message|Send a message/i.test(html);
                  return JSON.stringify({
                    errs: (window.__errs || []).slice(0, 6),
                    rootLen: root ? root.innerHTML.length : -1,
                    visibility: document.visibilityState,
                    url: location.href,
                    children: b ? b.children.length : -1,
                    bodyHtml: b ? b.innerHTML.replace(/\\s+/g, ' ').slice(0, 400) : '',
                    hasSignIn: /sign in|log in|登入|登录/i.test(b ? b.innerHTML : ''),
                    hasSend: /傳送訊息|Send message|Send a message/i.test(b ? b.innerHTML : ''),
                    loggedIn: signedIn,
                    api: apiStatus,
                    apiBody: apiBody
                  });
                })();
                """

                // 偵測到「一鍵登入」卡片（殘留 hatch_native_auth_device）就自動點一次
                let clickJS = """
                return await (async () => {
                  const cands = [...document.querySelectorAll('button, a, div[role="button"]')]
                      .filter(e => e.offsetParent !== null);
                  const label = (e) => (e.innerText || '').replace(/\\s+/g, '').trim();
                  const want = ['登入', '登入Muse', 'Login', 'Signin', 'Continue', '登入帳號'];
                  const hits = cands.filter(e => want.includes(label(e)));
                  if (!hits.length) return 'no-button';
                  // 取最寬的（卡片內的整寬主按鈕），避開頁首小按鈕與標題
                  hits.sort((a, b) => b.getBoundingClientRect().width - a.getBoundingClientRect().width);
                  const best = hits[0];
                  const r = best.getBoundingClientRect();
                  const o = {bubbles: true, cancelable: true, view: window,
                             clientX: r.x + r.width / 2, clientY: r.y + r.height / 2,
                             button: 0, pointerId: 1, isPrimary: true};
                  best.dispatchEvent(new PointerEvent('pointerdown', o));
                  best.dispatchEvent(new MouseEvent('mousedown', o));
                  best.dispatchEvent(new PointerEvent('pointerup', o));
                  best.dispatchEvent(new MouseEvent('mouseup', o));
                  best.dispatchEvent(new MouseEvent('click', o));
                  return 'clicked:' + label(best) + ' w=' + Math.round(r.width);
                })();
                """

                var autoTried = false

                func snapshotAndExit() {
                    let cfg = WKSnapshotConfiguration()
                    cfg.rect = webView.bounds
                    webView.takeSnapshot(with: cfg) { img, err in
                        if let img, let tiff = img.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/musedock_page.png"))
                            print("SNAP ok \(Int(img.size.width))x\(Int(img.size.height))")
                        } else {
                            print("SNAP fail \(String(describing: err))")
                        }
                        print("RESULT done")
                        exit(0)
                    }
                }

                func probe() {
                    webView.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
                        var signedIn = false
                        switch result {
                        case .success(let v):
                            print("PAGE \(v)")
                            signedIn = String(describing: v).contains("\"loggedIn\":true")
                            if self.current < self.accounts.count {
                                self.accounts[self.current].loggedIn = signedIn
                                Store.save(self.accounts)
                                print("LOGIN name=\(self.accounts[self.current].name) loggedIn=\(signedIn)")
                            }
                        case .failure(let e):
                            print("JSERR \(e.localizedDescription)")
                            if self.current < self.accounts.count {
                                self.accounts[self.current].loggedIn = false
                                Store.save(self.accounts)
                            }
                        }

                        let auto = ProcessInfo.processInfo.environment["MUSE_AUTOLOGIN"] == "1"
                        if !signedIn && auto && !autoTried {
                            autoTried = true
                            webView.callAsyncJavaScript(clickJS, arguments: [:], in: nil, in: .page) { r in
                                if case .success(let cv) = r { print("AUTOLOGIN \(cv)") }
                                else { print("AUTOLOGIN js-fail") }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { probe() }
                            }
                            return
                        }
                        snapshotAndExit()
                    }
                }

                probe()
            }
        }

        guard let t = webView.title, !t.isEmpty, current < accounts.count else { return }
        statusLabel.stringValue = "⇧⌘\(current + 1) 切換 · \(accounts[current].name)"
    }
}

// MARK: - Netscape cookies.txt 解析

enum CookieParser {
    static func parse(netscape: String) -> [HTTPCookie] {
        var out: [HTTPCookie] = []
        for raw in netscape.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line = String(line.dropFirst("#HttpOnly_".count))
            } else if line.hasPrefix("#") {
                continue
            }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 7 else { continue }
            let domain = parts[0]
            let path = parts[2]
            let secure = parts[3].uppercased() == "TRUE"
            let expiry = TimeInterval(parts[4]) ?? 0
            let name = parts[5]
            let value = parts[6]
            guard !name.isEmpty, !domain.isEmpty else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: domain,
                .path: path.isEmpty ? "/" : path,
                .name: name,
                .value: value,
            ]
            if secure { props[.secure] = "TRUE" }
            if httpOnly { props[.init("HttpOnly")] = "TRUE" }
            if expiry > 0 { props[.expires] = Date(timeIntervalSince1970: expiry) }
            if let c = HTTPCookie(properties: props) { out.append(c) }
        }
        return out
    }
}

// MARK: - 單一實例鎖

/// 兩個行程同時跑會共用同一份 accounts.json，後寫的整檔覆蓋先寫的（會丟帳號）。
/// 用 `flock` 仲裁：鎖由 kernel 在行程結束（含 crash、pkill -9）時自動釋放，
/// 不會出現「殘留鎖要手動清」的問題，這是它比 pid 檔可靠的地方。
enum InstanceLock {
    /// 跟 `accounts.json` 放同一個目錄：`MUSE_STATE_DIR` 換目錄時，鎖也跟著換，
    /// 示範用的行程才不會被真實實例擋掉（反過來也一樣）。
    static var lockPath: String { Store.dir.appendingPathComponent("instance.lock").path }

    /// 取排他鎖。成功回傳 fd（**保持開啟就等於持鎖**，不可 close），失敗回傳 nil。
    static func acquire() -> Int32? {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        ftruncate(fd, 0)
        let text = "\(getpid())\n"          // 只為了讓後來的失敗方能印出「是誰佔著」
        _ = text.withCString { write(fd, $0, strlen($0)) }
        return fd
    }

    /// 持鎖者的 pid，僅供提示用（讀不到就 nil）
    static func holderPID() -> pid_t? {
        guard let s = try? String(contentsOfFile: lockPath, encoding: .utf8) else { return nil }
        return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static let showNotification = NSNotification.Name("local.sulipa.musedock.show")

    /// 叫醒既有實例。先發分散式通知請它把視窗叫回——使用者可能已經把視窗關了
    /// （常駐模式下只是 orderOut），單純 activate 對這種 App 沒有效果。
    static func activateExisting() {
        DistributedNotificationCenter.default().postNotificationName(
            showNotification, object: nil, userInfo: nil, deliverImmediately: true)
        NSRunningApplication
            .runningApplications(withBundleIdentifier: "local.sulipa.musedock")
            .first?
            .activate(options: [.activateAllWindows])
    }
}

// MARK: - 進入點

let SNAPSHOT = ProcessInfo.processInfo.environment["MUSE_SNAPSHOT"] == "1"
/// 示範／截圖模式：搭配 `MUSE_STATE_DIR` 指向假資料，不做登入探測與指紋取樣
let DEMO = ProcessInfo.processInfo.environment["MUSE_DEMO"] == "1"
let IMPORT_FILE = ProcessInfo.processInfo.environment["MUSE_IMPORT_FILE"]
let IMPORT_ACCOUNT = ProcessInfo.processInfo.environment["MUSE_IMPORT_ACCOUNT"] ?? "1"
let CHROME_APPLY = ProcessInfo.processInfo.environment["MUSE_CHROME_APPLY"]
let PROBE_MODE = IMPORT_FILE != nil || CHROME_APPLY != nil
let WHO_SLOT = Int(ProcessInfo.processInfo.environment["MUSE_WHO"] ?? "")
let AVATAR_SLOT = Int(ProcessInfo.processInfo.environment["MUSE_AVATAR_PROBE"] ?? "")
var importFired = false
var avatarFired = false

func render(_ view: NSView, to path: String) {
    view.layoutSubtreeIfNeeded()
    guard view.bounds.width > 1, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        print("render failed: \(path) bounds=\(view.bounds)")
        return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) \(Int(view.bounds.width))x\(Int(view.bounds.height))")
}

setvbuf(stdout, nil, _IONBF, 0)

// ── 單一實例：只有「一般啟動」與「會寫 accounts.json 的 CLI」才搶鎖 ──
// 唯讀自測（快照、列 Profile、狀態列結構）允許與執行中的實例並存，
// 否則開發時每次都要先關掉 App 才能截圖／診斷。
let ENV = ProcessInfo.processInfo.environment
let READONLY_CLI = ["MUSE_CHROME_LIST", "MUSE_CHROME_IMPORT", "MUSE_STATUS_TEST",
                    "MUSE_CLOSE_TEST", "MUSE_SNAPSHOT", "MUSE_WHO", "MUSE_AUTOSTART",
                    "MUSE_AVATAR_PROBE"]
    .contains { ENV[$0] != nil }
let WRITING_CLI = ["MUSE_DROP_SLOT", "MUSE_WIPE_SLOT", "MUSE_IMPORT_FILE", "MUSE_CHROME_APPLY",
                   "MUSE_STORE_SELFTEST", "MUSE_IDLE_TEST"]
    .contains { ENV[$0] != nil }

var instanceLockFD: Int32 = -1
if !READONLY_CLI {
    if let fd = InstanceLock.acquire() {
        instanceLockFD = fd          // 保持開啟直到行程結束；close 就等於放鎖
        print("INSTANCE_LOCK acquired pid=\(getpid())")
    } else {
        let holder = InstanceLock.holderPID().map(String.init) ?? "不明"
        if WRITING_CLI {
            // 寫入型 CLI 絕不與執行中的實例並存，否則兩邊先後寫檔會丟帳號
            print("REFUSE 另一個 MuseDock 正在執行（pid \(holder)）；此命令會改寫 accounts.json，已中止")
            print("請先結束它：⌘Q，或選單列 → 結束 MuseDock")
            exit(3)
        }
        print("SINGLE_INSTANCE already running pid=\(holder)，已叫回既有視窗")
        InstanceLock.activateExisting()
        exit(0)
    }
}

// 自查：連續寫入 accounts.json（內容不變），驗證「讀取端永遠拿到完整 JSON」。
// 搭配外部輪詢使用：一邊跑這個、一邊讓 python 迴圈解析檔案，不該出現任何半截檔。
if ENV["MUSE_STORE_SELFTEST"] == "1" {
    let list = Store.load()
    print("STORE_SELFTEST begin accounts=\(list.count) rounds=200")
    // 故意製造「檔案被外部改過」：只在結尾多一個換行，內容不變。
    // 下一次 Store.save 應該出聲（STORE_CONFLICT），然後照常覆寫。
    if var raw = try? String(contentsOf: Store.file, encoding: .utf8) {
        raw += "\n"
        try? raw.data(using: .utf8)?.write(to: Store.file, options: .atomic)
        print("STORE_SELFTEST injected external change")
    }
    for i in 0..<200 {
        Store.save(list)
        if i % 50 == 0 { print("  wrote \(i)") }
    }
    let ok = (try? Data(contentsOf: Store.file)).flatMap { try? JSONDecoder().decode([Account].self, from: $0) } != nil
    print("STORE_SELFTEST done readable=\(ok) bytes=\((try? Data(contentsOf: Store.file))?.count ?? -1)")
    exit(ok ? 0 : 8)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// 命令列自測：列出 Chrome Profile
if ProcessInfo.processInfo.environment["MUSE_CHROME_LIST"] == "1" {
    let list = ChromeCookies.profiles()
    print("CHROME installed=\(ChromeCookies.isInstalled) profiles=\(list.count)")
    for p in list {
        print("  \(p.dir) | \(p.name) | \(p.email) | cookies=\(p.cookieCount) | last=\(p.lastUsedText)")
    }
    exit(0)
}

// 命令列自測：直接解密某個 Profile 的 muse cookie
if let dir = ProcessInfo.processInfo.environment["MUSE_CHROME_IMPORT"] {
    do {
        let cookies = try ChromeCookies.cookies(for: dir)
        print("CHROME_IMPORT dir=\(dir) cookies=\(cookies.count)")
        for c in cookies where c.name.contains("hatch") || c.name.contains("sess") {
            print("  \(c.domain) \(c.name) = \(c.value.prefix(12))…")
        }
        exit(0)
    } catch {
        print("CHROME_IMPORT_ERR \(error.localizedDescription)")
        exit(9)
    }
}

let controller = Controller()
app.delegate = controller

// 命令列自測：檢查選單列項目結構
if ProcessInfo.processInfo.environment["MUSE_STATUS_TEST"] == "1" {
    let m = NSMenu()
    controller.rebuildStatusMenu(m)
    print("STATUS item=\(controller.statusItem != nil) hasIcon=\(controller.statusItem?.button?.image != nil) items=\(m.items.count)")
    for it in m.items {
        if it.isSeparatorItem { print("  ---"); continue }
        let mark = it.state == .on ? "◉" : "○"
        let sub = it.submenu != nil ? " ▸(\(it.submenu?.items.count ?? 0))" : ""
        print("  \(mark) \(it.title)\(sub)")
    }
    exit(0)
}

// 命令列自測：關窗後是否仍在執行（常駐行為）
if ProcessInfo.processInfo.environment["MUSE_CLOSE_TEST"] == "1" {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        controller.window.performClose(nil)
        print("AFTER_CLOSE visible=\(controller.window.isVisible) statusItem=\(controller.statusItem != nil)")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        print("STILL_RUNNING windows=\(NSApp.windows.count)")
        exit(0)
    }
    app.run()
}

if let cmd = ProcessInfo.processInfo.environment["MUSE_AUTOSTART"] {
    controller.autostartCLI(cmd)
    exit(0)
} else if let s = ProcessInfo.processInfo.environment["MUSE_WIPE_SLOT"], let slot = Int(s) {
    controller.wipeBySlot(slot: slot)
    app.run()
} else if ProcessInfo.processInfo.environment["MUSE_IDLE_TEST"] == "1" {
    controller.runIdleTest()
    app.run()
} else if let s = ProcessInfo.processInfo.environment["MUSE_DROP_SLOT"], let slot = Int(s) {
    controller.dropAccount(slot: slot)
    app.run()
} else if let slot = WHO_SLOT {
    controller.probeWho(slot: slot)
    app.run()
} else if let slot = AVATAR_SLOT {
    controller.probeAvatar(slot: slot)
    app.run()
} else if let f = IMPORT_FILE {
    controller.runImport(account: IMPORT_ACCOUNT, file: f)
    app.run()
} else if let dir = CHROME_APPLY {
    controller.applyChromeImport(dir: dir)
    app.run()
} else if SNAPSHOT {
    let shots: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]
    for (tag, name) in shots {
        let appearance = NSAppearance(named: name)
        controller.window.appearance = appearance
        controller.sidebarView?.appearance = appearance
        controller.window.contentView?.layoutSubtreeIfNeeded()
        controller.window.contentView?.needsDisplay = true
        controller.sidebarView?.needsDisplay = true
        render(controller.sidebarView, to: "/tmp/musedock_sidebar_\(tag).png")
        render(controller.window.contentView!, to: "/tmp/musedock_window_\(tag).png")
    }
    exit(0)
}

app.run()
