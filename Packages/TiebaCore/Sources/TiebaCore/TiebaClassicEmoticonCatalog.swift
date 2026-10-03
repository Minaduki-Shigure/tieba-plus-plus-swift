import Foundation

public enum TiebaClassicEmoticonCatalog {
  public struct Entry: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let thumbnailURL: URL?
  }

  private static let legacyNames: [String] = [
    "呵呵", "哈哈", "吐舌", "啊", "酷", "怒", "开心", "汗", "泪", "黑线",
    "鄙视", "不高兴", "真棒", "钱", "疑问", "阴险", "吐", "咦", "委屈", "花心",
    "呼~", "笑眼", "冷", "太开心", "滑稽", "勉强", "狂汗", "乖", "睡觉", "惊哭",
    "生气", "惊讶", "喷", "爱心", "心碎", "玫瑰", "礼物", "彩虹", "星星月亮", "太阳",
    "钱币", "灯泡", "茶杯", "蛋糕", "音乐", "haha", "胜利", "大拇指", "弱", "OK",
  ]

  /// The original 50 wire names keep their order and spelling for saved drafts.
  /// Additional names and image identifiers are compiled from Tieba's official
  /// client dictionary, never learned from content returned by the server.
  public static let entries: [Entry] = {
    var result = legacyNames.enumerated().map { index, name in
      // Legacy clients disagree on whether 生气 denotes image 31 or 61. The
      // official dictionary calls image 31 哼, so retain the token without
      // inventing a thumbnail identity or silently changing old drafts.
      Entry(name: name, thumbnailURL: name == "生气" ? nil : thumbnailURL(number: index + 1))
    }
    let additionalNames: [(Int, String)] = [
      (31, "哼"), (86, "吃瓜"), (63, "扔便便"), (64, "惊恐"), (65, "哎呦"),
      (66, "小乖"), (67, "捂嘴笑"), (68, "你懂的"), (69, "what"), (70, "酸爽"),
      (71, "呀咩爹"), (72, "笑尿"), (73, "挖鼻"), (74, "犀利"), (75, "小红脸"),
      (76, "懒得理"), (77, "沙发"), (78, "手纸"), (79, "香蕉"), (80, "便便"),
      (81, "药丸"), (82, "红领巾"), (83, "蜡烛"), (84, "三道杠"), (85, "暗中观察"),
      (87, "喝酒"), (88, "嘿嘿嘿"), (89, "噗"), (90, "困成狗"), (91, "微微一笑"),
      (92, "托腮"), (93, "摊手"), (94, "柯基暗中观察"), (95, "欢呼"), (96, "炸药"),
      (97, "突然兴奋"), (98, "紧张"), (99, "黑头瞪眼"), (100, "黑头高兴"),
      (101, "不跟丑人说话"), (102, "么么哒"), (103, "亲亲才能起来"),
      (104, "伦家只是宝宝"), (105, "你是我的人"), (106, "假装看不见"),
      (107, "单身等撩"), (108, "吓到宝宝了"), (109, "哈哈哈"), (110, "嗯嗯"),
      (111, "好幸福"), (112, "宝宝不开心"), (113, "小姐姐别走"), (114, "小姐姐在吗"),
      (115, "小姐姐来啦"), (116, "小姐姐来玩呀"), (117, "我养你"),
      (118, "我是不会骗你的"), (119, "扎心了"), (120, "无聊"),
      (121, "月亮代表我的心"), (122, "来追我呀"), (123, "爱你的形状"), (124, "白眼"),
      (125, "奥特曼"), (126, "不听"), (127, "干饭"), (128, "望远镜"), (129, "菜狗"),
      (130, "老虎"), (131, "嗷呜"), (132, "烟花"), (133, "香槟"),
      (134, "文字啊"), (135, "文字对"), (136, "鼠1"), (137, "鼠2"),
    ]
    result.append(
      contentsOf: additionalNames.map { number, name in
        Entry(name: name, thumbnailURL: thumbnailURL(number: number))
      })
    return result
  }()

  public static let names: [String] = entries.map(\.name)

  /// Searches only the compiled catalog; searching never changes accepted wire names.
  public static func entries(matching query: String) -> [Entry] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return entries }
    return entries.filter { entry in
      entry.name.range(of: query, options: .caseInsensitive) != nil
        || "#(\(entry.name))".range(of: query, options: .caseInsensitive) != nil
    }
  }

  /// Accepts exactly the compiled HTTPS image URLs, without user-supplied paths,
  /// credentials, query strings, fragments, or alternate origins.
  public static func allowsThumbnailURL(_ url: URL) -> Bool {
    allowedThumbnailURLs.contains(url.absoluteString)
  }

  private static let allowedThumbnailURLs = Set(
    entries.compactMap { $0.thumbnailURL?.absoluteString })

  private static func thumbnailURL(number: Int) -> URL? {
    let identifier = number == 1 ? "image_emoticon" : "image_emoticon\(number)"
    return URL(string: "https://tb3.bdstatic.com/emoji/\(identifier)@2x.png")
  }

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
