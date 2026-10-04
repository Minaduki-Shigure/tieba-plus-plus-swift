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
复用已有两个首页、三个搜索 UI 流程，导出编译后的 Info.plist、真实截图和层级。
尚需读取实际结果，特别确认粘贴/搜索取消等系统控件，而不能仅以 YAML 中出现中文
语言代码作为界面完成证据。LiveContainer 的客体语言行为仍须实机验证。
