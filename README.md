# Riffa

Riffa（读作 “RIF-fa”，两个音节）是一款面向 Apple Silicon Mac 的原生比较工具。
`riff` 表示同一主题上的变化，对应“看见变化、理解差异、安全合并”。

项目采用 clean-room 方式开发：本机 Beyond Compare 5.2.3（32296）仅用于观察公开
行为、整理兼容性清单和设计验收用例；不复制其代码、资源、图标、商标、授权或密钥逻辑。
Riffa 目前是可运行的独立实现，**并不与 Beyond Compare 完全等价**。

## 当前能力

- 桌面端采用原创 Riffa 品牌标记和 App Icon，以及依据 `DESIGN.md` 落地的自适应设计系统：
  System/Light/Dark 外观、四级 surface、hairline、单一 accent、系统字体和可访问焦点状态。
  Midnight 是默认预设，另有 Graphite、Ocean、Forest；Settings 还支持自定义 accent 和严格
  分离 Light/Dark 变体的 JSON 主题导入。所有窗口即时使用同一主题，并响应提高对比度、无颜色区分、降低透明度
  和减少动态效果偏好。主题格式、解析顺序和安全边界见
  [Documentation/THEMING.md](Documentation/THEMING.md)。主页、
  Settings、Session Library、Workspace、十五类会话，以及 Resource Tools 的快照、归档、
  WebDAV 和操作历史页都已使用同一套 header、path、control、pane、status 与 empty-state
  组件完成主题化；差异和冲突同时提供文字、符号或图标，不只依赖颜色。26 个页面/模式及一张
  主视觉系统的 ImageGen 实现参考与逐图完整提示词见
  [Documentation/DesignMockups/README.md](Documentation/DesignMockups/README.md)。打包脚本会从
  原创 1024px 主图生成完整 `.icns`。
- Settings 提供 System、English 和简体中文，English/简体中文可在运行时切换而无需重启。
  UI、Info.plist 和 Finder Services 使用独立 String Catalog；本地化检查要求当前每个 key 都有
  English 与简体中文译文且格式占位符一致，打包时再编译并验证两套 `.lproj` 资源。
- macOS SwiftUI 桌面应用提供十五类会话：Folder Compare、Folder Merge、Folder Sync、
  Text Compare、Text Merge、Text Patch、Hex Compare、Media Compare、Image Compare、
  Table Compare、PDF Compare、Office Compare、Archive Compare、Metadata Compare 和
  Version Compare。
- 文本比较支持行级对齐、行内差异、hunk 导航、逻辑行书签与 overview 跳转、
  大小写/空白/换行规则，以及 Unicode、
  CR、LF、CRLF 和末尾换行；还可跨双栏进行文字/正则搜索与捕获组替换、在编辑缓冲区
  替换、按块双向复制。大输入使用有预算的 Patience 锚点并在超限区域稳定降级；三方文本
  合并支持结构化冲突、逐块选择和可编辑输出；冲突选择与手工编辑共享真正的 Undo/Redo，
  默认历史最多保留 100 条、16 MiB UTF-8 差量和 4,096 个冲突选择差量。新编辑会清除 Redo，
  单条超限时保留当前编辑但 fail-safe 清空历史，重载或换文件也会重置历史。UTF-8（含 BOM）
  与 UTF-16 LE/BE 会按原编码保存，
  覆盖已加载文件前会用内容指纹阻止外部修改冲突；Text Compare/Merge 会持续提示外部
  更改、移动或删除，并由用户选择重载或保留草稿。
- Text Patch 可有界读取并严格解析 Unified Diff；多文件补丁必须显式选择 file record，
  逐 hunk 验证后先生成可编辑的内存输出。另存为使用原编码，原位应用需要明确确认、原子
  替换及外部内容指纹校验。
- 文件夹比较支持本地递归枚举、稳定配对、元数据/内容比较和筛选。Folder Compare 的规则面板
  与 CLI 支持有预算的 `*`、`?`、`**` 包含/排除 glob、转义及可选大小写折叠；排除规则优先，
  会话会完整保存规则。隐藏路径不会进入结果或操作计划，复制可见深层项目时只补齐必要父目录，
  且启用规则时拒绝递归删除目录，避免扫描后新出现的隐藏子项被误删。Folder Merge 可完成
  三树分析、逐项冲突选择，并在 dry-run 预检、独立备份和确认后安全物化独立输出目录。
  Folder Compare 还支持多选后 Left→Right / Right→Left 复制、替换或安全删除：只生成
  选中子计划，自动补齐必要父目录，并复用 preflight、独立备份和失败回滚。用户还可显式
  开启有预算的移动/重命名候选检测：仅在左右唯一文件的尺寸与 SHA-256 内容都一致时提示，
  重复内容只报告歧义。用户可选中候选，在目标侧父目录已存在时直接执行同侧 `old → new`：
  整单预检后再次验证 proof，以 no-clobber move、显式确认、operation journal 和事务回滚保护；
  需要先创建目标父目录的候选会拒绝并提示改用 Folder Sync。对任意一个当前可见、无问题的本地
  普通文件，还可在 Left 或 Right 上显式输入同一父目录内的新 leaf 名：Riffa 会捕获 inode、
  size、mtime、ctime 与 SHA-256 授权快照，经 dry-run 和二次确认后只允许 no-clobber 原子 rename，
  不做复制退化，且 journal/取消/后续故障都能恢复原名。仅大小写重命名会经有界、descriptor-backed
  的精确目录项拼写检查，再使用不可猜测的同目录隐藏中间名和两次排他原子 rename；journal 只记录
  公开旧名/新名，正常故障或取消会回滚原拼写。若进程恰好在隐藏中间阶段终止，恢复分析会要求人工
  检查，不会猜测或自动修改用户文件。目录、链接及跨目录任意重命名仍不支持。
  结果还可按左右较新及“较新 + 独有”筛选。
- Folder Sync 可生成 Update Left/Right/Both 与双向 Mirror 计划，并在显式确认后安全执行：
  整单 preflight、独立备份目录、高风险门控、符号链接/路径防护及失败回滚。Mirror 模式可
  显式开启移动检测，把严格一对一的候选折叠为目标侧内部移动；应用时会重新校验两侧大小与
  SHA-256，使用不覆盖目标的 descriptor 操作，同卷原子重命名，且仅在真实 `EXDEV` 时退化为
  保留 mode/mtime/xattr 的验证复制后删源。取消或后续动作失败会恢复已完成移动。
- Folder Compare/Merge/Sync 的正式写事务都会逐步写入持久 operation journal；Resource
  Tools 中的 Operation History 可扫描活动/归档记录、查看步骤状态和清理已完成日志；移动步骤
  会同时记录并显示旧/新路径及源、目标两端的前后状态。对跨启动遗留的非终态记录，History
  会通过 no-follow descriptor 只读观察 source/target/backup，区分可认定完成、可认定回滚、
  需人工判断、现场矛盾和无法安全观察；证据不足时不会猜测。仅对前两种全事务一致结论，用户可
  经二次确认把日志元数据终态化：store 会在跨进程锁内重验 ID/status/revision 和全部现场，再以一次
  原子 JSON 替换写回；此操作不会复制、移动、删除、恢复或修改任何用户文件，归档仍是独立动作。
- Hex Compare 通过 descriptor 分块比较最高 128 GiB 的本地普通文件，只在 UI 持有当前
  8 KiB 页面；差异位置/范围总数精确，导航范围前缀有界。Image Compare 提供 RGBA 容差、
  Alpha、整数偏移、并排/混合/热图、透明度棋盘，以及两侧共享缩放和同步平移；Table
  Compare 提供有界 RFC 4180 风格 parser/serializer、常见分隔符、行号或复合 key 对齐、
  匹配行单元格编辑、双向行复制和追加；候选编辑会在提交前阻止重复复合 key，Save As 保留
  UTF-8/BOM 或 UTF-16 LE/BE 及末尾 record terminator，并禁止覆盖任一原输入。仍不支持工作簿、
  多工作表和类型化列；Workspace 切换标签会卸载视图，未保存的表格 UI 草稿不会跨切换保留。
- Media Compare 使用 AVFoundation 提取时长、轨道、文件属性与嵌入元数据，并通过类型化值、
  数值/日期容差和 SHA-256 数据摘要比较。
- PDF Compare 使用 PDFKit 有界提取页面文本、页面几何、旋转、标签和公开文档元数据，并提供
  经 SHA-256 复核的有界页面预览；Visual 页签只对当前选中页按需、串行渲染到最长边 1,200 的
  共同白底 RGBA8 画布，以可调容差显示左右页和差异热图。该视觉结果不会改变页面/文本状态，
  也不进入整本文档的结构化报告。Metadata Compare 以 `O_EVTONLY | O_SYMLINK` descriptor
  绑定所选目录项，比较类型、大小、创建/修改时间、权限、所有者、BSD flags，以及有界 xattr
  与 macOS ACL 摘要；结束前还会重验 descriptor 和路径 inode。ACL 主体、xattr 值和绝对路径
  不进入结果。Version Compare 检查 bundle 版本、Mach-O 架构/部署目标、可执行摘要和签名状态。
- Office Compare 从包内声明识别不含宏的 DOCX/XLSX/PPTX，以及 ODS 的 `mimetype`、manifest
  和 `content.xml`（扩展名不作为信任依据）。输入先经过 ZIP、路径、XML expanded-name 命名空间、
  ODF 层级、DTD/实体和反炸弹校验，再比较核心属性、有界逻辑文本/单元格/幻灯片及 package-part
  SHA-256 摘要。ODS 解析、repeat 展开和分块摘要可协作取消，所有发布字符串计入字符与 UTF-8
  展开预算；它会保留工作表、重复行列展开结果、类型值、显示值、原始公式与合并跨度元数据，
  合法的单元格内嵌套表、covered cell 负载及其它非单元格文本只作为有界原始 XML 处理，不会
  污染顶层工作表单元格；其中的变化仍会反映在 `content.xml` part 摘要中。它不执行公式、脚本、
  宏、外部链接或外部实体，也不渲染布局、图片或图表。
  Archive Compare 从内容识别 ZIP/TAR，
  只读比较规范化成员路径、类型、大小、链接目标和可选内容/时间/权限/压缩属性；不会解压到
  磁盘或跟随成员链接，且不支持写入、嵌套归档、7z、RAR 或 ISO。
- Session Library 可保存十五类桌面会话，支持分组、搜索、重命名、锁定、删除、导入和导出；
  本地文件/目录资源可按保存的会话类型重新打开。Finder/“打开方式”传入的本地资源也会按
  目录、文本、十六进制、PDF、Office、Archive、图片、表格或媒体类型路由到相应会话；三个
  目录进入 Folder Merge，三个文本文件进入 Text Merge，超过三个输入会明确报错而不会静默
  丢弃。打包后的 App 另提供四个标准 macOS Finder Services：选择待配对左文件/文件夹，或
  用两项直接比较、用一项配对进程内 pending 左侧；它们严格区分真实普通文件与真实目录，
  不跟随符号链接，成功后前置比较窗口。这里使用的是 `NSServices`，不是 Finder Extension，
  pending 路径不会持久化。
- Session Library 还可编排基于已保存会话的多个 Workspace 窗口和有序标签，持久化窗口名称、
  标签顺序及活动标签。每个窗口只挂载当前标签，避免后台读取所有大文件；因此切换标签会卸载
  旧视图的瞬时选择、滚动和未保存 UI 状态。当前不捕获/恢复窗口 frame，也不提供原生跨窗口
  标签拖拽。
- Resource Tools 可创建文件夹元数据与 SHA-256 快照、比较“快照与实时目录”或两个快照，
  并可安全浏览只读 ZIP/TAR、预览或导出单个普通成员。它也提供只读 WebDAV 浏览与单资源
  导出；同一 WebDAV 连接内可把两个远程文本文件标为 Left/Right 并直接比较。读取使用 ETag
  `If-Match` 和前后元数据复核；只接受单个、transport-safe 的强 entity-tag，弱或异常标签执行
  第二次流式 SHA-256 复核。HEAD、GET 与复读还必须解析为同一最终相对路径。远程文本比较另有
  每边 8 MiB、100,000 行、单行和 200,000 发布行上限；diff、预览、网络与有界 HTML 报告均传播
  取消，离场会清除任务、连接和内存凭据。凭据可选择性存入 Keychain（默认不记住），但远程资源
  尚未接入十五类会话的通用资源选择器，也没有远程写入。
- 十一种双向比较会话——Text、Folder、Hex、Media、Image、Table、PDF、Office、Archive、
  Metadata、Version——可生成自包含 HTML、纯文本和稳定 JSON 报告；合并、同步和补丁会话
  不计入该报告数量。图片报告只包含统计摘要，媒体及格式专用报告不泄露原始 Data 或绝对
  资源定位。
- `riffa` CLI 支持 `text`、`folder`、`sync`、`hex`、`pdf`、`metadata`、`version`、`merge`、`table`、
  `office`、`archive-compare`、`patch`、`patch-apply`，以及 `snapshot-create`、
  `snapshot-compare`、`snapshot-diff`、`archive-list`、`archive-read`。
  比较命令采用 0（相同）/1（不同或冲突）/2（错误）退出码；补丁应用默认只写标准输出，
  归档读取只输出一个经校验的普通成员且不会跟随链接。
  `sync` 默认只输出相对路径的 dry-run 计划；落盘必须同时提供 `--apply`、独立 `--backup` 和
  与模式逐字相同的 `--confirm`，高风险计划还必须显式 `--allow-high-risk`，并复用 journal、
  整单 preflight、取消传播与回滚执行器。
- Unified Patch 已接入文本比较的创建/严格应用流程；版本化、actor 隔离、原子写入的
  `SessionCatalog` 已接入 Session Library。所有用户选择的本地资源通过 App Sandbox 的
  security-scoped bookmark 恢复；通用本地读取器与目录枚举器具备字节、条目、深度、路径、
  TOCTOU 和特殊文件防护。Folder 内容比较使用 `O_NOFOLLOW` descriptor、枚举 identity 校验及
  路径重绑定复核；PDF 在 PDFKit 解析前通过单 descriptor 有界读取普通文件，并核对读取前后
  device/inode/size/mtime/ctime，页面预览再用 SHA-256 确认输入版本。
- 自动化测试覆盖比较、合并、同步/输出执行、编码保真、补丁、报告、会话存储、操作日志、
  Workspace、文件夹快照及重命名候选、Office、归档、PDF、元数据、版本、Keychain 身份和
  WebDAV 资源提供器；主题与本地化另有格式、持久化和打包验证。

精确状态和剩余缺口见
[Documentation/FEATURE_PARITY.md](Documentation/FEATURE_PARITY.md)。

## 环境与运行

- Apple Silicon Mac
- macOS 14 或更新版本
- Xcode 16.2 或更新版本

本机默认 `xcode-select` 可以继续指向 Command Line Tools；命令显式指定 Xcode：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --disable-sandbox
zsh ./Scripts/check-localization.sh
swift run RiffaDesktop
swift run riffa --help
```

构建可双击的本地应用和 arm64 CLI：

```bash
RIFFA_DISABLE_SWIFTPM_SANDBOX=1 ./Scripts/build-app.sh
open dist/Riffa.app
dist/riffa --help
```

产物只包含 `arm64`。脚本先验证 English/简体中文 String Catalog，编译 UI、Info.plist 与
Finder Services 的 `en.lproj`/`zh-Hans.lproj` 资源，再在隔离目录完成 plist 同一性、纯 arm64
与严格签名验证，最后原子替换 App 和 CLI；它使用带 App Sandbox entitlement 的 ad-hoc 签名
并启用 Hardened Runtime，适合本地开发。正式分发仍需 Developer ID 签名和 Apple 公证。

## 项目结构

```text
Sources/
├── RiffaCore/   # 无 UI 依赖的比较、合并、资源与持久化核心
├── RiffaApp/    # SwiftUI/AppKit macOS 应用
└── RiffaCLI/    # 自动化与脚本入口
Tests/
├── RiffaCoreTests/
└── RiffaAppTests/
Documentation/  # 产品边界、兼容性账本与架构决策
```

模块保持“UI → 应用服务 → 领域模型 → ResourceProvider”的单向依赖，避免把远程资源或
归档成员伪装成普通本地 `URL`。本地 ZIP/TAR 已有专用 Archive Compare 会话；归档成员仍不能
作为其他会话的通用比较侧。WebDAV 当前可在只读 Resource Tools 内比较两个远程文本文件，
但尚未接入十五类会话的通用资源选择器。

## 平台边界

Riffa 只支持 macOS arm64，不规划 Intel Mac、Windows 或 Linux 版本。因此不会实现
Windows Registry、Explorer Shell 扩展、COM、Windows 专用版本资源，也不会实现
Beyond Compare 的注册、试用绕过、许可证密钥或任何授权兼容逻辑。
