import Foundation

/// Three-way merge of config.json, run by git as a merge driver (`--merge-config %O %A %B`), so
/// two Macs that changed different sounds or keys never conflict. The library merges by sound
/// id, field by field; pages merge key by key. Where both Macs changed the same thing, the
/// repository's copy ("theirs") wins, except that an edit beats a removal so nothing is lost.
enum ConfigMerge {
    /// git's `%O %A %B`: base, ours (replaced with the result), theirs. Returns the exit status.
    static func run(base: String, ours: String, theirs: String) -> Int32 {
        guard let o = read(ours), let t = read(theirs) else { return 1 }
        // An empty base: both sides added the file (a Mac joining a repository already in use).
        let merged = merge(base: read(base) ?? [:], ours: o, theirs: t)
        guard let data = try? JSONSerialization.data(withJSONObject: tidyNumbers(merged),
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: ours))) != nil else { return 1 }
        return 0
    }

    /// JSONSerialization writes 0.8 as 0.80000000000000004; decimal numbers write as typed.
    static func tidyNumbers(_ value: Any) -> Any {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID() && CFNumberIsFloatType(number):
            NSDecimalNumber(string: "\(number.doubleValue)")
        case let object as [String: Any]: object.mapValues(tidyNumbers)
        case let array as [Any]: array.map(tidyNumbers)
        default: value
        }
    }

    private static func read(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func merge(base: [String: Any], ours: [String: Any], theirs: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in Set(ours.keys).union(theirs.keys) {
            switch key {
            case "library":
                result[key] = library(base[key] as? [[String: Any]], ours[key] as? [[String: Any]] ?? [],
                                      theirs[key] as? [[String: Any]] ?? [])
            case "pages":
                result[key] = pages(base[key] as? [Any], ours[key] as? [Any] ?? [], theirs[key] as? [Any] ?? [])
            default:
                result[key] = pick(base[key], ours[key], theirs[key])
            }
        }
        if base.isEmpty { dropUnusedDefaults(&result, theirs: theirs) }
        return result
    }

    /// The usual three-way choice for one value (`nil` = absent, `NSNull` = an empty key).
    /// `fields`: when both changed the same object, merge it field by field.
    static func pick(_ b: Any?, _ o: Any?, _ t: Any?, fields: Bool = false) -> Any? {
        if same(o, b) { return t }
        if same(t, b) || same(o, t) { return o }
        // Both changed it. Removed on one side, edited on the other: keep the edit.
        if b != nil, isEmpty(o) { return t }
        if b != nil, isEmpty(t) { return o }
        // Both edited the same sound: merge its fields, so different settings both survive.
        if fields, let b = b as? [String: Any], let o = o as? [String: Any], let t = t as? [String: Any] {
            var result: [String: Any] = [:]
            for key in Set(o.keys).union(t.keys) { result[key] = pick(b[key], o[key], t[key]) }
            return result
        }
        return t
    }

    private static func isEmpty(_ value: Any?) -> Bool { value == nil || value is NSNull }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): (a as AnyObject).isEqual(b)
        default: false
        }
    }

    /// Sounds by id, in the repository's order, followed by the ones only this Mac has.
    private static func library(_ base: [[String: Any]]?, _ ours: [[String: Any]], _ theirs: [[String: Any]]) -> [[String: Any]] {
        func byID(_ list: [[String: Any]]) -> [String: [String: Any]] {
            Dictionary(list.compactMap { entry in (entry["id"] as? String).map { ($0, entry) } }) { first, _ in first }
        }
        let b = byID(base ?? []), o = byID(ours), t = byID(theirs)
        var ids: [String] = []
        for id in (theirs + ours).compactMap({ $0["id"] as? String }) where !ids.contains(id) { ids.append(id) }
        return ids.compactMap { pick(b[$0], o[$0], t[$0], fields: true) as? [String: Any] }
    }

    /// Pages key by key. (Deleting a page shifts the ones after it, so a page deleted on one Mac
    /// while a later page changed on the other can mix keys up; the repository's history has both.)
    private static func pages(_ base: [Any]?, _ ours: [Any], _ theirs: [Any]) -> [Any] {
        (0..<max(ours.count, theirs.count)).compactMap { p in
            let b = base?[safe: p], o = ours[safe: p], t = theirs[safe: p]
            if same(o, b) { return t }
            if same(t, b) || same(o, t) { return o }
            if b != nil, o == nil { return t }
            if b != nil, t == nil { return o }
            let bk = b as? [Any], ok = o as? [Any] ?? [], tk = t as? [Any] ?? []
            return (0..<max(ok.count, tk.count)).map { k in
                pick(bk?[safe: k], ok[safe: k], tk[safe: k]) ?? NSNull()
            }
        }
    }

    /// A Mac joining a repository already in use takes its keys, so the starter sounds that
    /// ship with Soundboard would only clutter the library.
    private static func dropUnusedDefaults(_ result: inout [String: Any], theirs: [String: Any]) {
        guard var library = result["library"] as? [[String: Any]] else { return }
        let theirIDs = Set((theirs["library"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let used = Set((result["pages"] as? [Any] ?? []).flatMap { $0 as? [Any] ?? [] }
            .compactMap { ($0 as? [String: Any])?["sound"] as? String })
        library.removeAll { entry in
            guard let id = entry["id"] as? String, let file = entry["file"] as? String else { return false }
            return !theirIDs.contains(id) && !used.contains(id) && file.hasPrefix("/System/Library/Sounds/")
        }
        result["library"] = library
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
