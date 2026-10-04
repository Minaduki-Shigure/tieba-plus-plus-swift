# 搜索历史操作顺序

全局搜索历史和吧内搜索历史原先只把连续的“记录搜索”操作串行化。
删除、清空、重置会等待当时已有的记录任务，但不成为后续任务的前驱；
初次读取和重试读取也不参与排序。后台文件读取已经取得旧快照、等待主线程
恢复时，新的用户操作仍可能修改文件和界面，随后旧快照又覆盖新界面。

在不改生产代码的 [macOS 复现](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37184426818)
中，原有 14 项全局历史测试通过，新增三项全部失败：

- 清空后，先前读取的旧快照返回，界面恢复已清空的记录。
- 清空尚未完成时提交新搜索，新记录先写入，随后被较早的清空操作删除。
- 删除词条尚未完成时再次搜索同一词，新访问被旧删除操作抹掉。

测试通过受控仓库暂停操作完成时机，覆盖仓库协议允许的异步次序；它不表示
每次真机文件读取都会触发相同交错。未使用账号或真实搜索接口。

修复使用每个历史模型独立拥有的 `SearchHistoryOperationQueue`，让读取、
记录、删除、清空、重置以及对应的界面更新按调用顺序执行。调用者离页或取消
等待，不取消已经接受的本地操作。任务结束后释放队尾；操作失败由模型呈现，
不阻断后续操作。并发首次加载共享同一任务，完成后在任务内部清理共享句柄。

这条队列只串行本地历史操作，不阻塞网络搜索。吧内清空仍只处理当前吧；
用户明确选择重置损坏的整个吧内历史文件时，仍沿用原有全局重置语义。
存储格式、容量、搜索词身份和记录时间规则均保持原样。

[修复后的 macOS 验证](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37188767855)
直接链接生产模型与文件仓库源码，20 项测试全部通过，包括上述三项复现、
取消等待后继续写入、失败恢复和重置后新搜索。它验证模型与真实文件存储的
原有契约，不替代 iOS 界面运行。吧内另新增七项操作顺序、论坛隔离、网络独立
和取消测试。

[组合 iOS 候选](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37188924914)
在 iPhone 16 Pro / iOS 18.5 模拟器实际通过 90 项模型测试和两项原生搜索联想
UI 测试，均零失败、零跳过。UI 记录确认选取联想只写一次历史，返回帖子不重复
提交；关闭联想时服务未收到联想请求。后续吧内搜索恢复另通过
[35 项模型测试和六项搜索 UI 回归](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37189754514)，
消息分页修复另通过[四项原生 UI 回归](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37192652980)，
均零失败、零跳过。这些专项测试有重叠，不能相加作为完整测试数量。
alpha.47 的完整界面回归另外发现了搜索结果追加时的真实跳动，未发布。
修复后的 [alpha.48 搜索专项](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37198420318)
已通过新增的暂停响应位置测试及原有三项分类测试，四项均零失败、零跳过：
第二页追加前后，第 20 条标题均位于 Y=568.7 pt，随后实际读取第 21 条且只有两次
帖子请求。同候选随后通过原有三项联想/吧内恢复集成测试，未修改测试或重跑；
两份独立报告分别为 4/0/0 和 3/0/0（通过/失败/跳过），共七项 UI 测试通过。
[alpha.48/build 126 完整标签 CI](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/actions/runs/37198478997)
已通过全部 2,695 项 App 测试、27 项手机 UI 测试和三项 iPad UI 测试，均零失败、
零跳过，Core 和匿名集成也已通过。这些修改已随
[alpha.48/build 126](https://github.com/Minaduki-Shigure/tieba-plus-plus-swift/releases/tag/v0.65.0-alpha.48)
发布；公开应用源与 IPA 的大小、SHA-256 和包内版本验证均通过。
详见[发布验证记录](search-and-inbox-release-validation.md)。
