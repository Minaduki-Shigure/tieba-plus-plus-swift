import Foundation

public enum TiebaClassicEmoticonCatalog {
  /// The fixed, legacy Tieba emoticon names in their canonical display order.
  public static let names: [String] = [
    "呵呵", "哈哈", "吐舌", "啊", "酷", "怒", "开心", "汗", "泪", "黑线",
    "鄙视", "不高兴", "真棒", "钱", "疑问", "阴险", "吐", "咦", "委屈", "花心",
    "呼~", "笑眼", "冷", "太开心", "滑稽", "勉强", "狂汗", "乖", "睡觉", "惊哭",
    "生气", "惊讶", "喷", "爱心", "心碎", "玫瑰", "礼物", "彩虹", "星星月亮", "太阳",
    "钱币", "灯泡", "茶杯", "蛋糕", "音乐", "haha", "胜利", "大拇指", "弱", "OK",
  ]

  /// Returns the exact Tieba wire token for a canonical catalog name.
  ///
  /// Lookup is deliberately byte-exact. A canonically equivalent but non-NFC
  /// spelling is rejected instead of being normalized behind the caller's back.
  public static func token(for name: String) -> String? {
    guard let name = canonicalName(exactly: name) else { return nil }
    return "#(\(name))"
  }

  static func canonicalName(exactly candidate: String) -> String? {
    let normalized = candidate.precomposedStringWithCanonicalMapping
    guard candidate.utf8.elementsEqual(normalized.utf8) else { return nil }
    return names.first { $0.utf8.elementsEqual(candidate.utf8) }
  }
}
