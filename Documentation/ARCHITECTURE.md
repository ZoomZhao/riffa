# 架构与阶段路线

## 依赖方向

```text
RiffaApp / riffa CLI
        ↓
Application Services（会话、操作协调、持久化）
        ↓
RiffaCore（Diff、Merge、SyncPlan、领域模型）
        ↓
ResourceProvider（Local、Archive、Snapshot、WebDAV）
        ↓
Infrastructure（文件系统、Keychain、PDFKit、AVFoundation、Security、URLSession）
```

领域算法不能依赖 SwiftUI、AppKit 或具体协议。`ResourceLocator` 由 provider ID、路径和后续的
容器栈组成，最终要能表示“S3 对象中的 ZIP 里的文件”，而不是把所有资源都假装成 `URL`。

## 并发模型

- 桌面比较模型或专用 worker actor 为每次比较分配 generation；过期结果不得覆盖新结果。
- I/O 与 CPU 使用独立限流器；取消必须向枚举、解码、哈希和远程请求传播。
- 领域结果是不可变 `Sendable` 值；主线程只接收批量快照。
- 大文件输入使用 descriptor 分块或有界解码；桌面列表设置发布上限。百万文件树的惰性子树
  仍是后续目标，当前本地枚举有严格条目上限。

## 桌面设计系统与比较 chrome

`RiffaDesignSystem.swift` 是桌面视觉基础层：它把 `DESIGN.md` 的 surface、hairline、单一
accent、间距、圆角与系统字体映射为 SwiftUI token、主题环境、按钮、panel、status badge 和
focus ring。每个窗口根视图统一安装主题，支持跟随 macOS 的 System 外观或固定 Light/Dark；
Midnight 是默认预设，Graphite、Ocean、Forest 提供同样完整的双外观 palette。主题仍根据提高
对比度、无颜色区分、降低透明度和减少动态效果偏好调整边界、符号提示、透明度与动画。accent
只用于品牌、焦点和少量主动作；比较结果的 success/warning/danger 等语义不会被当成装饰色。

`RiffaComparisonChrome.swift` 提供可横向适配的 header、资源 path bar 和 control bar；
`RiffaWorkspaceComponents.swift` 补充 pane header、search/input、status bar、empty state 与
纯图标按钮，让比较视图共享同一 surface 与 hairline 层级，同时不侵入 Core 模型或差异语义。
主页、Settings、Session Library、Workspace、十五类会话和全部 Resource Tools 页面均复用这套
token 与可访问控件。对应的 ImageGen 实现参考覆盖 26 个页面/模式和一张主视觉系统，逐图完整
提示词保存在 `Documentation/DesignMockups/Prompts/`。原创品牌标记由 SwiftUI shape 绘制，打包脚本从
原创 1024px App Icon 主图生成全尺寸 `.icns`，视觉资源不来自 Beyond Compare。

## 主题、本地化与打包边界

`RiffaThemePreferences.swift` 定义稳定的外观、语言和预设 raw value，以及完整 palette、
自定义 accent、版本化 JSON 主题和容器内主题存储。各窗口根 modifier 通过 `@AppStorage`
观察相同 key，因此 Settings 的选择会即时传播到 Comparison、Session Library、Workspace、
Resource Tools、Settings 和 Finder Services 兜底窗口。颜色解析顺序固定为“内置预设 →
当前外观对应的导入主题变体 → 自定义 accent”；最后一层会派生 hover、focus 与可读前景色。

导入主题不是任意资源包。schema v1 最大 64 KiB，必须至少提供一个非空 `light` 或 `dark`
语义色对象；缺失的另一外观完整回退到当前 preset。每个对象可部分覆写 preset，但未知顶层
字段、未知 token、非法 hex、未知 schema 或空变体会拒绝整个文档。规范化副本以 ID 命名并原子写入 App Sandbox 的
`Application Support/Riffa/Themes/`，不接受符号链接或任意外部路径。完整格式见
`Documentation/THEMING.md`。

`RiffaLocalization.swift` 为必须取得具体 `String` 的 AppKit/Foundation API 提供和 SwiftUI
`Locale` 环境一致的解析；显式选择 English 或简体中文时，它会直接解析对应 `.lproj` bundle，
而不是依赖进程启动时确定的系统首选语言。Settings 可在 System、English 和简体中文之间运行时
切换，窗口根节点、Scene 标题和 Commands 同时观察同一偏好。当前 String Catalog 分离 UI、
Info.plist 与 Finder Services。`Scripts/check-localization.sh` 检查两种语言的 translated
状态、必需 key、占位符签名、所有 `RiffaLocalization.string` 字面量，以及编译器无法提取的
enum/rawValue 动态 key 清单；`Scripts/build-app.sh` 在 release 编译前强制执行该检查，使用
`xcstringstool` 生成 `en.lproj`/`zh-Hans.lproj` 的三个 strings table，并在发布前继续验证
纯 arm64、plist、entitlement 和签名。

## 会话目录与 Workspace

`SessionCatalog` 当前枚举十五类桌面会话，以版本 envelope、引用校验、actor 串行更新和原子
替换持久化；Session Library 对十五类会话提供分组、搜索、重命名、锁定、删除、导入、导出
和本地 security-scoped bookmark 恢复。Workspace 在同一 catalog 中保存命名窗口、有序标签和
活动会话，应用可同时打开多个 Workspace 窗口。桌面层的主题化 Session Library 与 Workspace
manager 明确区分空、加载、保存、选择、禁用和错误状态，并为纯图标动作提供可访问名称；这些
只是 presentation 优化，不改变 catalog 的事务或恢复边界。

Workspace 的标签条只挂载当前活动的比较视图，避免 SwiftUI 预先构造所有标签并读取后台大文件。
这是明确的资源边界，不是完整状态保活：切换标签会卸载旧视图，瞬时选择、滚动位置和未保存的
UI 状态不会保留。当前 schema 虽可表达可选 frame，桌面层尚未捕获或恢复窗口 frame，也没有
原生跨窗口标签拖拽。

## 文本

当前实现保留每行原始换行符，小区域在乘法成本预算内使用标准库
`CollectionDifference`；大区域使用唯一公共行/Patience 锚点、稳定 LIS 与有界工作队列，
锚点间只有在预算内才做精确 diff。无锚点或超预算区域产生稳定粗粒度替换，不会退回无界
算法；行内 token/字符也有独立预算。下一阶段的真正增量编辑缓冲仍需 piece table 或 rope，
并以滚动哈希分块和局部窗口重算。三方合并以 `base→left` 与 `base→right` 的变更区间合成，
只有重叠且结果不同才产生冲突。

Text Merge 的编辑状态由 Core `TextMergeDraft` 统一表示输出文本与全部冲突选择；手工编辑和
冲突选择都进入同一个 `TextMergeEditHistory`。历史条目只保存按 Unicode scalar 边界计算的
removed/inserted 文本差量和实际变化的冲突选择，不重复保存整份文档；Undo/Redo 原子恢复两部分。
额外历史默认受 100 条、16 MiB UTF-8 差量和 4,096 个冲突选择差量三重总预算约束，预算在 Undo
与 Redo 栈之间共享。新编辑清空 Redo；单条变更无法纳入预算时仍安装用户编辑，但清空两栈并在
界面提示，避免伪造可恢复性；输出 `NSTextView` 关闭自身未计预算的 `allowsUndo` 缓存，菜单与
快捷键只进入 Core 历史。成功重载、换文件或重新计算 merge 会建立新 generation 和 clean
baseline、清空旧历史；异步保存只在 generation 仍匹配时更新该 baseline，因此旧 I/O 不会污染
新文档。编码/BOM 仍由 `DecodedTextDocument` 路径独立保留。

## 文件夹与安全操作

本地文件夹比较默认通过 `DirectoryEnumerator` 流式枚举，按 provider 的 `PathSemantics`
规范化后配对，并统一施加条目、深度与 UTF-8 相对路径预算；默认不跟随链接，显式跟随模式
用 device+inode 环检测并共享同一预算。Folder Snapshot 使用独立的条目、深度、路径及总哈希
字节预算，FIFO 等特殊节点只记录元数据。Folder Compare 可选用 descriptor 分块内容验证。
路径规则在左右配对完成后按规范化相对路径执行有预算的确定性 glob 匹配；排除规则优先，
发布结果与操作支持节点分离。后者只保留可见叶节点所需的父目录，不携带被过滤的文件或兄弟节点；
规则启用时目录删除计划 fail closed，防止扫描后的隐藏子项被递归删除。用户还可显式开启
大小桶和 SHA-256 检测，以提示唯一的同内容移动/重命名候选；重复内容不会被
任意配对。Folder Compare 可把用户精确选中的候选直接执行为目标侧同根内部移动，但仅限目标
父目录已存在的场景；它在生成动作前和提交时都重验唯一性、类型、大小与 digest，不把普通独有项
猜成重命名，也不隐式创建父目录。Folder Sync 的 Mirror 模式可由用户显式开启同一检测，并只把
经过相同严格验证的一对 copy+delete 折叠为高风险目标侧移动。内容比较与候选哈希都以
`O_NOFOLLOW | O_NONBLOCK` 打开普通文件，核对枚举得到的 device/inode/size/permissions，
读取前后检查完整版本，并重新打开原路径防止 descriptor 有效期间发生路径重绑定。同步必须先产生
`SyncPlan` 并整单 preflight。移动 proof 在任何写入前以及提交时都会通过 descriptor 重新打开源、
对侧参考文件和目标父目录，拒绝路径中的链接及已存在目标；同卷使用 `RENAME_EXCL` 原子 rename，
只有精确 `EXDEV` 才采用 O_EXCL 临时文件、分块复制/复核 SHA-256、复制 mode/mtime/xattr、`fsync`
后安装并删源。取消、安装后故障或后续动作失败会用相同 proof 恢复，journal 同时保存源/目标前后态。
Folder Compare 的普通文件显式 rename 使用独立授权域，不借用 detector match：planner 只接收当前
可见、单选、无 issue 的本地普通文件，捕获 inode、size、permissions/flags、mtime、ctime 与 digest
快照；执行前重验根、父目录、source name 和 destination absence，只允许同父目录 `RENAME_EXCL`，
禁止 `EXDEV` 复制退化。普通 rename 直接排他安装；仅大小写 rename 另用 descriptor-backed、
有条目/文件名字节预算的精确拼写扫描，在同一父目录依次执行“公开旧名 → 不可猜测隐藏名 →
公开新名”两次排他原子 rename，并在各阶段复核 identity、精确名称和 destination absence 后同步
目录。隐藏名不会写入 journal 或错误信息。取消及正常阶段故障会按已安装 identity 恢复原拼写；
若进程终止在隐藏名阶段，recovery analyzer 只会给出需人工判断的专用原因，不猜测隐藏名，也不
自动终态化或修改用户文件。目录、链接和跨目录任意 rename 仍不在该纵切内。其它复制/替换仍采用
同目录临时文件和原子安装。
删除先进入独立备份区或废纸篓；Folder Compare/Merge/Sync 的正式写事务先写入可扫描的持久
journal，日志失败时不得把事务误报为成功；活动/归档记录通过 Operation History 查看。未完成
journal 会由只读 recovery analyzer 在重新绑定根目录和父目录 descriptor 后观察源、目标和备份
状态，并按“可认定完成、可认定回滚、需人工判断、现场矛盾、不可安全观察”分类。只有前两类形成
全事务一致结论时，History 才允许用户二次确认终态化日志：store 在跨进程锁内核对独立 journal ID、
kind、status、revision，重新执行完整 descriptor-safe 分析并要求 plan 完全相等，然后以一次原子
JSON replacement 同时写入 step 与 journal 终态。普通 copy/replace 没有内容身份证据时仍不会推断。
该流程不执行、继续或回滚任何文件动作；文件级自动恢复、继续执行和 recovery wizard 仍未实现。

所有需要把本地普通文件完整读入内存的会话都使用 `BoundedLocalFileReader`：descriptor 打开
时拒绝目录/FIFO 等非普通节点，读取前后比较 device、inode、size、mtime、ctime，并在每个
chunk 前执行总字节预算。需要真正支持大文件的会话应改为 descriptor 分页/流式算法，而不是
调高这个上限。

## 专用格式

- Hex：当前用 `pread` descriptor 分块完成同偏移精确统计，并按摘要版本 token 重读有界页面；
  差异范围只发布固定前缀以抵御交替字节输入。后续插入/删除重对齐需要内容定义分块和局部 diff。
- Picture：ImageIO 在尺寸和解码像素预算内归一为 RGBA；像素容差、偏移和热图由纯 Swift 核心
  计算，桌面视图使用一份缩放值与同步滚动位置，并可在透明区域显示棋盘。未来可在性能基准
  证明必要后引入 Accelerate/Metal；当前没有旋转/任意仿射配准或编辑。
- Table：CSV/TSV/分号/管道文本按复合 key 或行号配对；解析器对输入和发布行设置显式预算。
  XLSX 与 ODS 工作簿由 Office 比较器处理，不进入文本表格的编辑/保存流程。
- Metadata：以 `O_EVTONLY | O_SYMLINK` 打开所选 vnode，所有 xattr 与 extended ACL 读取均走
  descriptor API；快照后同时复核 descriptor 版本及最终路径 `lstat` 的 device/inode/metadata，
  符号链接目标还会双读。xattr 和按顺序生效的 ACL 都只保留有界字节数、条目数与 SHA-256，
  不持久化原值、principal、绝对 locator，也不会跟随链接或递归目录。
- Office package：DOCX/XLSX/PPTX 经 ZIP/OPC/XML 反炸弹与关系路径验证；ODS 必须同时具备匹配的
  精确 stored `mimetype`、`META-INF/manifest.xml` 和 `content.xml` 声明，并复用同一 ZIP provider。
  ODS 属性按 expanded name 解析，manifest entry 绑定直接父级且加密标记按 manifest namespace
  判定；结构状态严格绑定 body/spreadsheet/table/row/cell，同时兼容标准行列 group/header wrapper。
  合法的普通单元格内嵌套表、covered cell 负载和其它非单元格文本作为语义不透明子树，不改变
  顶层工作表模型，但仍计入 XML 节点/文本/命名空间预算，并通过 `content.xml` 摘要暴露变化。
  在分配前限制行、列、单元格、repeat、span 终点和所有发布字符串的字符/UTF-8 展开预算。
  XML 节点、repeat 循环、part 遍历与分块 SHA-256 均传播任务取消。
  快照保留类型值、显示值、原始公式及跨度元数据；所有部件只做有界 SHA-256 摘要。桌面与
  `riffa office` 共用该内容识别核心，不执行公式、脚本、
  宏、外部链接或实体，也不渲染页面/幻灯片布局、图片、图表或样式；不支持旧式 DOC/XLS/PPT、
  宏格式，以及 ODS 嵌入对象的视觉或语义解析。
- Archive：ZIP/TAR 只读 provider 与比较器从内容识别格式，验证规范化成员路径、CRC、展开率、
  单项和累计字节预算；桌面与 `riffa archive-compare` 可比较路径、类型、大小、链接目标和可选
  内容/mtime/权限/压缩元数据。不落盘解压，也不跟随成员符号链接；格式范围仅 ZIP/TAR，
  嵌套归档、写入、7z、RAR 和 ISO 尚未实现。
- Media/Version：AVFoundation 与有界 Mach-O/Info.plist/Security framework 原生解析。
- PDF：PDFKit 只接收一次单 descriptor 有界读取后的普通文件字节；读取前后核对
  device/inode/size/mtime/ctime（符号链接可在打开时解析一次，但特殊文件会被拒绝），随后按页
  比较几何、旋转、标签、公开元数据和提取文本。预览重读必须用 SHA-256 验证仍是同一内容，
  并渲染为有界位图。Visual 只在用户查看当前选中页时工作：共享串行 worker 分别重读和验证
  两侧原快照，在独立生命周期内依次渲染到最长边 1,200 的共同白底 RGBA8 画布，再复核两侧
  输入并调用 Core `ImageComparison`；页码或容差变化会取消旧任务并用 generation 阻止旧结果
  发布。便携视觉结果只含有界 raster、mask 和统计，不含 URL、PDF Data 或 AppKit 类型；现有
  整本文档报告仍仅描述页面结构、文本与元数据。
- 高风险旧格式和外部转换器尚未接入；若未来支持，应放入限制时间、内存和写权限的独立 XPC
  worker，而不是在主应用进程直接解析。

## 报告边界

十五类会话中，十一个双向比较会话（Text、Folder、Hex、Image、Table、Media、PDF、Office、
Archive、Metadata、Version）可由桌面导出自包含 HTML、纯文本和稳定 JSON。Folder Merge、
Folder Sync、Text Merge 和 Text Patch 不计入这十一类。报告模型只保留可移植标签、统计、
有界行和摘要；图片 mask、媒体原始 Data、文件 identity token 与绝对本地 locator 不进入报告。

## 远程

按 WebDAV → SFTP/FTP/FTPS → S3 → Dropbox/OneDrive → SVN 的顺序交付。WebDAV 当前已有
只读浏览、预览、单资源导出，以及同一连接内两份远程文本的直接比较。文本加载执行
HEAD→GET→HEAD：只有一个符合可传输强 entity-tag 字节语法的 ETag 才通过 `If-Match` 约束 GET，
弱、列表或异常标签会再流式读取一次并比较 SHA-256；每次 HEAD/GET/复读还必须解析为同一最终规范
相对路径。任一身份、版本、长度或内容不一致都会失败关闭。`WebDAVResourceLimits` 不可变、自定义
解码并在 provider 边界重建，防止零/负 chunk 或容量绕过。远程文本进入 diff 前再施加每边 8 MiB、
100,000 逻辑行、单行 UTF-8/字符和 200,000 发布行上限；取消可进入 line key、Patience、token、
hunk、预览、网络与最多 16 MiB 的有界 HTML 报告。结果只保存相对显示路径、内容版本和 diff，
不继续持有两份 decoded snapshot，也不保存 base URL 或凭据；视图离场会结束任务并清空连接与
内存 secret。Basic/Bearer secret 默认只驻留内存，显式记住时按规范化 HTTPS 身份存入 Keychain。
当前远程文本入口仍局限于 Resource Tools 和同一 WebDAV 连接，并未把 WebDAV locator 接入十五类
会话的通用资源选择器，也没有远程写入。后续 provider 必须按各自能力提供分页、取消、限流、缓存、
幂等重试与乐观并发控制；当前 WebDAV 纵切不代表这些远程后端已实现。密码、OAuth refresh token
和云密钥只进入 Keychain；日志使用隐私标记。

## CLI 自动化

`riffa sync` 与桌面 Folder Sync 共用比较、逻辑计划和 journal 执行器。默认 dry-run 只进行有界
内容比较并输出稳定的逻辑计划，不触碰文件系统；实际文件系统 preflight 只在所有 apply 门控通过后
执行。写入必须同时提供 `--apply`、独立 `--backup` 和与方向一致的 `--confirm`，Mirror 等高风险
模式还必须显式 `--allow-high-risk`。SIGINT/SIGTERM 会转为协作取消，让执行器走既有回滚路径。
当前 CLI 不启用重命名检测，也没有计划文件、定时任务或稳定的跨版本自动化 API。

## 阶段门槛

1. **基础切片**：本地文本/文件夹比较、CLI、SwiftUI、测试与打包。
2. **可用本地工具**：编辑、会话、规则、过滤、报告和安全文件操作。
3. **合并与同步**：文本/文件夹三方合并、同步预览、undo journal、监听器。
4. **丰富格式**：Hex、Picture、Table、Archive、Snapshot、Media、Version。
5. **远程与集成**：远程 providers、Finder Extension、脚本与批处理；标准 Finder Services
   已作为较小的 AppKit 集成切片交付，不等同于 Finder Extension。
6. **完整性收尾**：长尾格式、完整无障碍验收、更多语言、故障注入、fuzz、性能和发布签名。

每一阶段只有在测试、性能、安全失败行为和兼容性账本同时更新后才视为完成。
