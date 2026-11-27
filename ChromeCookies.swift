import Foundation
import CommonCrypto
import SQLite3

// MARK: - Chrome Profile 與 cookie 讀取
//
// 直接讀 ~/Library/Application Support/Google/Chrome 下的 cookie 資料庫，
// 用钥匙串裡的 "Chrome Safe Storage" 派生金鑰解密（AES-128-CBC / PBKDF2-SHA1, 1003 輪）。

struct ChromeProfile {
    let dir: String          // 目錄名，例如 "Profile 11"
    let name: String         // 顯示名稱，例如 "Default"
    let email: String
    let cookieCount: Int
    let lastUsed: Date?

    var lastUsedText: String {
        guard let d = lastUsed else { return "未使用過" }
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        return f.string(from: d)
    }
}

enum ChromeCookieError: LocalizedError {
    case notInstalled
    case noDatabase(String)
    case keychain(String)
    case sqlite(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "找不到 Chrome 資料夾，可能沒安裝過 Chrome。"
        case .noDatabase(let d): return "\(d) 裡找不到 cookie 資料庫。"
        case .keychain(let m): return "讀取鑰匙串失敗：\(m)"
        case .sqlite(let m): return "讀取 cookie 資料庫失敗：\(m)"
        case .empty: return "這個 Profile 裡沒有 muse.ai 的 cookie（可能沒登入過 Muse）。"
        }
    }
}

enum ChromeCookies {
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static var cachedKey: Data?

    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    // MARK: 列出 Profile

    static func profiles() -> [ChromeProfile] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }

        // 顯示名稱與 email 來自 Local State
        var meta: [String: (name: String, email: String)] = [:]
        if let data = try? Data(contentsOf: root.appendingPathComponent("Local State")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = obj["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any] {
            for (dir, raw) in cache {
                guard let d = raw as? [String: Any] else { continue }
                let name = (d["name"] as? String) ?? dir
                let email = (d["user_name"] as? String) ?? ""
                meta[dir] = (name, email)
            }
        }

        var out: [ChromeProfile] = []
        for url in items {
            let dir = url.lastPathComponent
            guard dir == "Default" || dir.hasPrefix("Profile ") else { continue }
            guard let dbURL = databaseURL(for: dir) else { continue }

            // 上次使用時間：History / Cookies 檔案的修改時間取較新者
            var last: Date?
            for f in ["History", "Cookies", "Network/Cookies"] {
                let p = url.appendingPathComponent(f)
                if let attr = try? fm.attributesOfItem(atPath: p.path),
                   let d = attr[.modificationDate] as? Date {
                    if last == nil || d > last! { last = d }
                }
            }

            let count = (try? countCookies(at: dbURL.path)) ?? -1
            let m = meta[dir]
            out.append(ChromeProfile(dir: dir,
                                     name: m?.name ?? dir,
                                     email: m?.email ?? "",
                                     cookieCount: count,
                                     lastUsed: last))
        }
        return out.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    /// 依名稱找最合適的 Profile：先精確比對，再忽略大小寫
    static func profile(matching name: String, in list: [ChromeProfile]) -> ChromeProfile? {
        list.first { $0.name == name } ?? list.first { $0.name.lowercased() == name.lowercased() }
    }

    static func databaseURL(for dir: String) -> URL? {        let base = root.appendingPathComponent(dir, isDirectory: true)
        for rel in ["Network/Cookies", "Cookies"] {
            let u = base.appendingPathComponent(rel)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    // MARK: 匯出 cookie

    static func cookies(for dir: String) throws -> [HTTPCookie] {
        guard isInstalled else { throw ChromeCookieError.notInstalled }
        guard let src = databaseURL(for: dir) else { throw ChromeCookieError.noDatabase(dir) }

        // 複製一份（含 -wal / -shm）再讀，避免跟執行中的 Chrome 搶鎖
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("musedock-chrome-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dst = tmpDir.appendingPathComponent("Cookies")
        try FileManager.default.copyItem(at: src, to: dst)
        for ext in ["-wal", "-shm"] {
            let from = URL(fileURLWithPath: src.path + ext)
            if FileManager.default.fileExists(atPath: from.path) {
                try? FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: dst.path + ext))
            }
        }

        let rows = try readRows(at: dst.path)
        let key = try safeStorageKey()

        var out: [HTTPCookie] = []
        for r in rows {
            let value: String
            if !r.plain.isEmpty {
                value = r.plain
            } else if let dec = decrypt(r.encrypted, key: key, host: r.host) {
                value = dec
            } else {
                continue
            }
            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: r.host,
                .path: r.path.isEmpty ? "/" : r.path,
                .name: r.name,
                .value: value,
            ]
            if r.secure { props[.secure] = "TRUE" }
            if r.httpOnly { props[.init("HttpOnly")] = "TRUE" }
            if r.expires > 0 {
                let t = TimeInterval(r.expires) / 1_000_000 - 11_644_473_600
                if t > 0 { props[.expires] = Date(timeIntervalSince1970: t) }
            }
            if let c = HTTPCookie(properties: props) { out.append(c) }
        }
        guard !out.isEmpty else { throw ChromeCookieError.empty }
        return out
    }

    // MARK: 私有

    private struct RawRow {
        let host: String
        let path: String
        let secure: Bool
        let expires: Int64
        let name: String
        let plain: String
        let encrypted: Data
        let httpOnly: Bool
    }

    private static func openReadOnly(_ path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            throw ChromeCookieError.sqlite("無法開啟資料庫")
        }
        return db
    }

    private static func countCookies(at path: String) throws -> Int {
        let db = try openReadOnly(path)
        defer { sqlite3_close(db) }
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM cookies WHERE host_key LIKE '%muse%'",
                                 -1, &st, nil) == SQLITE_OK, let st else { return -1 }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int(st, 0))
    }

    private static func readRows(at path: String) throws -> [RawRow] {
        let db = try openReadOnly(path)
        defer { sqlite3_close(db) }

        let sql = """
        SELECT host_key, path, is_secure, expires_utc, name, value, encrypted_value, is_httponly
        FROM cookies WHERE host_key LIKE ?
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else {
            throw ChromeCookieError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, "%muse%", -1, transient)

        var rows: [RawRow] = []
        while sqlite3_step(st) == SQLITE_ROW {
            func text(_ i: Int32) -> String {
                guard let c = sqlite3_column_text(st, i) else { return "" }
                return String(cString: c)
            }
            var blob = Data()
            if let b = sqlite3_column_blob(st, 6) {
                blob = Data(bytes: b, count: Int(sqlite3_column_bytes(st, 6)))
            }
            rows.append(RawRow(host: text(0),
                               path: text(1),
                               secure: sqlite3_column_int(st, 2) != 0,
                               expires: sqlite3_column_int64(st, 3),
                               name: text(4),
                               plain: text(5),
                               encrypted: blob,
                               httpOnly: sqlite3_column_int(st, 7) != 0))
        }
        return rows
    }

    /// 從鑰匙串取 Chrome Safe Storage 密碼。
    /// 走 /usr/bin/security（系統工具，通常已取得授權）比 SecItemCopyMatching 更不易反覆彈窗。
    private static func safeStorageKey() throws -> Data {
        if let k = cachedKey { return k }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-w", "-s", "Chrome Safe Storage", "-a", "Chrome"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { throw ChromeCookieError.keychain("無法執行 security") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ChromeCookieError.keychain("拿不到 Chrome Safe Storage（鑰匙串未授權？）")
        }
        var pw = String(data: data, encoding: .utf8) ?? ""
        while pw.hasSuffix("\n") { pw.removeLast() }
        guard !pw.isEmpty else { throw ChromeCookieError.keychain("密碼為空") }

        // 關鍵：密碼字串原樣取 UTF-8 位元組，PBKDF2-SHA1 / salt=saltysalt / 1003 輪 / 16 bytes
        let salt = Array("saltysalt".utf8)
        let pwBytes = Array(pw.utf8).map { Int8(bitPattern: $0) }
        var key = [UInt8](repeating: 0, count: 16)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                          pwBytes, pwBytes.count,
                                          salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                          1003, &key, key.count)
        guard status == kCCSuccess else { throw ChromeCookieError.keychain("金鑰派生失敗 \(status)") }
        let d = Data(key)
        cachedKey = d
        return d
    }

    private static func decrypt(_ blob: Data, key: Data, host: String) -> String? {
        guard blob.count > 3 else { return nil }
        let magic = String(data: blob.prefix(3), encoding: .utf8) ?? ""
        guard magic == "v10" || magic == "v11" else {
            return String(data: blob, encoding: .utf8)
        }
        let payload = blob.dropFirst(3)
        guard payload.count > 0, payload.count % 16 == 0 else { return nil }

        var out = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var outLen = 0
        let iv = [UInt8](repeating: 0x20, count: 16)   // 16 個空白
        let status = payload.withUnsafeBytes { raw -> CCCryptorStatus in
            key.withUnsafeBytes { kb in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(0), kb.baseAddress, key.count,
                        iv, raw.baseAddress, payload.count,
                        &out, out.count, &outLen)
            }
        }
        guard status == kCCSuccess, outLen > 0 else { return nil }

        var bytes = Array(out[0..<outLen])
        // 手動去 PKCS7 padding（上面沒開 padding 選項）
        if let pad = bytes.last, pad >= 1, pad <= 16, bytes.count >= Int(pad) {
            bytes.removeLast(Int(pad))
        }
        // Chrome 130+：明文前 32 bytes 是 sha256(host) 的域綁定前綴
        if bytes.count > 32 {
            var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            let hostBytes = Array(host.utf8)
            CC_SHA256(hostBytes, CC_LONG(hostBytes.count), &digest)
            if Array(bytes.prefix(32)) == digest {
                bytes.removeFirst(32)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}
