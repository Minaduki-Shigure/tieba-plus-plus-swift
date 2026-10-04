# 简体中文界面与系统控件语言

2026-10-04 检查公开 alpha.42（build 120）IPA：`CFBundleDevelopmentRegion`
为 `en`，未声明 `CFBundleLocalizations`，包内也没有 `.lproj` 资源目录。
应用自身界面文本以简体中文提供，但包的语言声明仍是英语。

候选将项目开发语言、`CFBundleDevelopmentRegion` 设为 `zh-Hans`，并用
`CFBundleLocalizations: [zh-Hans]` 声明当前实际支持的语言。它不伪造英文或繁体
翻译，不改系统语言、日期/数字格式偏好，也不覆盖 SwiftUI 的全局 locale。

Apple 的[语言选择说明](https://developer.apple.com/library/archive/qa/qa1828/_index.html)
明确指出，没有 `.lproj` 而自行处理界面文本的应用应声明 `CFBundleLocalizations`；
系统控件的错误语言应从应用实际支持的本地化配置检查。
[CFBundleDevelopmentRegion](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledevelopmentregion)
定义回退语言；[XcodeGen 项目规范](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md)
的 `developmentLanguage` 默认值为 `en`。

[原生候选 37179108351](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37179108351)
复用已有两个首页、三个搜索 UI 流程，实际全部通过，零失败、零跳过。编译后的
Info.plist 确认 `CFBundleDevelopmentRegion=zh-Hans` 与
`CFBundleLocalizations=[zh-Hans]`。真实首页截图显示“粘贴”，搜索截图及可访问性
层级显示“取消”；导航、刷新、分页、排序、位置保留及重新搜索重置的原断言通过。
验证环境为 iOS 18.5 模拟器、简体中文启动偏好。其他语言偏好和 LiveContainer
客体环境没有由此获得实机验证，后续组合版本仍须经过完整发布测试。
