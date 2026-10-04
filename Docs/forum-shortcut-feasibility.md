# 每吧一个 iOS 主屏幕入口：可行性与签名实验

核实日期：2026-10-04。状态：研究与隔离实验，尚未实现产品功能，不计入 TiebaLite 对齐完成度。

## 已确认的需求与现有基础

TiebaLite `9701bfb6` 的 [ForumPage.kt](https://github.com/zzc10086/TiebaLite/blob/9701bfb6aaf261cc37b20b5793a8404261077f49/app/src/main/java/com/huanchengfly/tieba/post/ui/page/forum/ForumPage.kt#L349)
为指定贴吧生成头像、名称和直达 URL；616 行的菜单调用它，
`utils.kt:285` 再通过 Android 的 `requestPinShortcut` 请求创建桌面图标。
本项目已有 `tieba-plus-plus://forum/<编码吧名>` 路由，但 App 首页固定吧卡片、
长按应用图标的四个 Quick Actions 均不等同于独立的主屏幕图标。

## 可审阅的完整路径（待实现、待实机验证）

1. 一次性制作并导出公开可用的 `.shortcut` 模板，内容仅为“URL → 打开 URL”，
   用导入问题设置 URL。之后原样分发此签名文件，不在 App 中修改其签名字节。
2. 贴吧页面准备具体目标 URL、吧名和头像，并引导用户导入模板、填入目标 URL。
   模板导入问题修改的是动作参数；不能假设它能直接重命名快捷指令。
3. 用户运行导入后的快捷指令，确认打开正确贴吧和正确 LiveContainer 数据容器。
4. 用户在系统快捷指令界面选择“添加到主屏幕”，设置吧名、头像并确认添加。
   此后点击图标应直接打开该贴吧，不能只停留在 App 首页。

Apple 官方支持[自定义 URL 方案](https://support.apple.com/guide/shortcuts/apd621a1ad7a/ios)、
[导入问题](https://support.apple.com/zh-cn/guide/shortcuts/apdf330fd3a0/ios)、
[文件共享](https://support.apple.com/zh-cn/guide/shortcuts/-apdf01f8c054/ios)和
[添加到主屏幕](https://support.apple.com/guide/shortcuts/apd735880972/ios)。
公开的 `shortcuts://create-shortcut` 只打开新建编辑器，并不能代替上述模板和添加流程。

## 一次人工制作公共模板的最少步骤

可使用用户自己已登录 iCloud 的 iPhone 或 iPad，无需把 Apple 账号、密码、令牌或
LiveContainer 容器信息交给项目。Apple 的 iPhone/iPad 文件共享文档明确列出
“任何人（Anyone）”导出选项，不限于 Mac；Apple 会验证导出的副本。

1. 在“快捷指令”中新建“贴吧主屏幕入口模板”，添加“URL”操作，内容设为固定的
   `tieba-plus-plus://forum/swift`；在其后添加“打开 URL”，输入连接到前一操作的 URL。
   不加入账号、剪贴板读取、网页请求或其他操作。
2. 打开快捷指令详情（ⓘ）→“设置 / Setup”→“添加新问题”，选择第一步的 URL 参数。
   问题写“粘贴贴吧++生成的主屏幕启动链接”，默认回答使用同一个固定示例 URL。
   可通过“自定义快捷指令”检查此问题确实修改 URL 字段。
3. 打开共享表单 →“选项”→“文件”→“任何人（Anyone）”→“完成”→“存储到‘文件’”。
   某些版本也可从名称旁的菜单进入“导出文件”。不要选择“认识我的人”，该方式会包含联系信息。
4. 后续只需提供导出的公共 `.shortcut` 文件，供检查、导入测试和原样分发；制作时不必运行
   示例链接，也不需要任何真实贴吧账号或宿主容器 URL。

以上是按 Apple 界面文档整理的制作说明，尚未在本项目目标设备上执行。
导入问题的序列化 schema 没有在本次实验中验证；不通过猜测 plist 字段制作可发布模板。

## 无 iCloud GitHub runner 的实测结果

[运行 37179082301](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37179082301)，
提交 `90b1412c585a93ddb2f0ae708c977572e3255dd3`，`macos-15` 实际系统为 macOS 15.7.9（24G830）。
隔离分支为 `ci/forum-shortcut-signing-1004`，没有修改 App、main、版本或应用源。

| 命令 | 退出码 | 结果 |
| --- | --- | --- |
| `shortcuts --help` | 0 | CLI 可用 |
| `shortcuts list` | 0 | 输出为空 |
| `shortcuts sign --help` | 0 | 确认支持 `anyone` 模式 |
| `shortcuts sign --mode anyone --input … --output …` | 1 | 明确要求登录 iCloud |

最终错误：`Error: In order to do this, you must be signed into iCloud.`
没有生成签名文件；仅有 586 字节的未签名二进制 plist，以及源码、日志、退出码和 SHA-256。
证据归档为该运行的 `forum-shortcut-signing-37179082301-1` artifact（保留 7 天）。
没有登录 iCloud、添加凭据、导入或运行快捷指令，也没有发生超时。

[Apple 的 CLI 文档](https://support.apple.com/guide/shortcuts-mac/apd455c82f02/mac)
说明签名方法，但本次实际结果证明此 runner 即使使用 `anyone` 也不能匿名签名。
这不是对 fixture 导入有效性的证明：登录要求可能先于后续格式验证。
因此需要一次已登录设备的公共文件导出，不能宣称当前 CI 已闭环生成发布模板。

## 独立 IPA 与 LiveContainer 的边界

- 独立安装：使用已注册的 `tieba-plus-plus://forum/…`；保留现有严格吧名校验与 URL 编码。
- LiveContainer：必须由宿主提供完整 `livecontainer-launch` URL，再附加 Base64 编码的
  `open-url` 贴吧目标。`bundle-name` 是宿主的相对应用路径，不能用 Bundle ID 猜测；
  `container-folder-name` 必须明确存在且唯一，不能省略后依赖当前默认容器。
- 可靠配置来源是用户在宿主选定目标数据容器后执行“Copy Launch URL”。未发现可供客体使用的
  稳定公共身份 API；不读取宿主私有偏好、猜测文件目录或擅自挑选另一容器。
- 实现应校验宿主方案、`livecontainer-launch` 主机和唯一的应用/容器参数，拒绝歧义链接，
  用 `URLComponents` 编码附加参数。导出前还需验证链接确实回到预期 App/数据容器；
  该绑定不能扩大为自动选择或切换贴吧登录账号。

协议依据为官方 [LCSharedUtils.m](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainer/LCSharedUtils.m)、
[LaunchAppExtension.swift](https://github.com/LiveContainer/LiveContainer/blob/main/LaunchAppExtension/LaunchAppExtension.swift)
和 [LCAppModel.swift](https://github.com/LiveContainer/LiveContainer/blob/main/LiveContainerSwiftUI/Models/LCAppModel.swift)。
宿主的 [Add to Home Screen 指南](https://livecontainer.github.io/docs/guides/add-to-home-screen)
支持 Launch App 和 Open URLs 两种方式；客体自己的 App Intent 不能被当作宿主动作的通用替代。
[LiveContainer 3.8.0](https://github.com/LiveContainer/LiveContainer/releases/tag/3.8.0)
记录了冷启动丢失 deep link 的修复，旧版最低版本说明不构成完整链路可靠性的保证。

## 完成前必须补足

公共模板的真实导入与参数填充；目标 iOS 16+ 版本兼容性；主屏幕名称和头像；中文、空格与
特殊字符吧名；独立安装冷热启动；LiveContainer 冷热启动、不同实例及至少两个数据容器不串用；
应用更新/重签及容器变更后的行为。签名成功、URL 单测或仅复制 URL 都不代表此流程完成。
