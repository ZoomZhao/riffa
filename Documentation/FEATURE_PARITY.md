# 功能兼容性账本

观察基线为本机 Beyond Compare 5.2.3（32296）。Riffa 是 clean-room 独立实现；本表用于
标明方向和缺口，**不表示已经与 Beyond Compare 完全等价**。

- `[x]` 当前范围内已落地并有测试或构建验证。
- `[~]` 有可用纵切，但缺少成熟产品中的重要能力。
- `[ ]` 尚未实现。

## 十五个桌面会话

| 会话 | 状态 | 当前实现与边界 |
| --- | --- | --- |
| Folder Compare | `[~]` | 本地流式递归枚举、稳定配对、元数据/可选内容比较，以及有预算的 `*`/`?`/`**` 包含与排除路径规则；规则可保存，排除优先，隐藏节点不会夹带进操作。支持按状态/左右较新/该侧较新加独有筛选，多选后安全双向复制/替换/删除、独立备份、operation journal 与失败回滚；规则开启时禁用递归目录删除以保护扫描后出现的隐藏子项。可选检测左右唯一、同尺寸且 SHA-256 相同的移动/重命名建议，重复内容只记为歧义；目标父目录已存在时可把精确选中的候选以二次 proof、no-clobber、确认、journal 和回滚保护直接执行为目标侧内部移动。任意单个当前可见、无问题的本地普通文件还可显式改为同父目录新 leaf，使用 inode/size/mtime/ctime/digest 授权快照、dry-run、原子 no-clobber rename、journal 和回滚。仅大小写 rename 使用有界的精确拼写扫描、不可猜测同目录中间名和两次排他原子 rename；journal 不持久化隐藏名，正常故障或取消恢复原拼写，进程若停在中间阶段则要求人工检查。仍缺跨目录任意移动、目录/链接重命名、属性编辑、大树虚拟化和远程资源。 |
| Folder Merge | `[~]` | Base/Left/Right 三树分析、冲突选择和独立输出计划；可经 dry-run、独立备份、确认、operation journal 及回滚保护创建或更新输出目录。已有历史查看、跨启动遗留现场评估，以及只在全事务证据一致时经二次确认终态化日志元数据；尚缺继续执行、文件级自动恢复和完整 recovery wizard。 |
| Folder Sync | `[~]` | Update Left/Right/Both、双向 Mirror，支持实际执行；执行前整单 preflight，要求独立备份目录和确认，具有高风险门控、路径/符号链接防护、operation journal 与失败回滚。Mirror 可将严格唯一、同内容的重命名候选折叠为经二次 SHA-256 证明的目标侧移动；使用 no-clobber 同卷 rename，只有 `EXDEV` 才进行保留基础元数据/xattr 的验证复制后删源，取消和后续失败均可逆向恢复。尚缺自动断点恢复和远程同步。 |
| Text Compare | `[~]` | 行级/行内差异、hunk 导航、逻辑行书签与 overview 跳转、双栏文字/正则搜索、捕获组替换、编辑缓冲区替换、按块双向复制、双栏内存编辑与另存、Unified Patch 创建/应用、大小写/空白/换行规则；UTF-8/BOM 与 UTF-16 LE/BE 会按原格式保存，持续监听外部修改/移动/删除并协调重载或保留草稿。大输入使用有预算 Patience diff。仍缺语法感知、手工对齐和真正增量编辑索引。 |
| Text Merge | `[~]` | 三方合并、结构化冲突、逐块 Left/Base/Right 选择和可编辑输出；冲突选择与手工输出编辑共享 Core 差量 Undo/Redo，提供 Edit 菜单、⌘Z/⇧⌘Z、可用状态按钮和 VoiceOver 标签，历史受条目、UTF-8 与选择差量三重总预算约束并在重载/换文件时重置。保存沿用输入的 UTF-8/BOM 或 UTF-16 LE/BE，持续监听三侧文件并在外部变化时协调重载。仍缺更多编码、编辑器选区恢复和更完整协调 UI。 |
| Text Patch | `[~]` | 有界读取、严格 Unified Diff 解析，多 file record 强制显式选择；逐 hunk 校验、可编辑内存输出、原编码 Save As，以及带确认/原子替换/外部指纹保护的原位应用。暂不处理 Git binary patch、rename/mode 元数据，单次应用一个 record。 |
| Hex Compare | `[~]` | descriptor-backed 分块比较最高 128 GiB 本地普通文件，精确统计差异位置与范围，仅发布前 4,096 个范围并显示 8 KiB 页面；支持分页、已发布差异导航、TOCTOU/特殊文件/取消保护及有界报告。仍缺插入/删除重对齐、编辑，以及范围前缀截断后的随机索引。 |
| Media Compare | `[~]` | AVFoundation 时长、轨道、文件属性与嵌入元数据；支持类型化字段、重复 key、容差和 SHA-256 数据摘要。缺少标签编辑和更多格式专用字段。 |
| Image Compare | `[~]` | 有界 ImageIO 解码、RGBA 像素比较、容差、Alpha、整数偏移、最小差异边界、mask 热图，以及并排/混合/差异视图；两侧共享缩放和同步平移，可显示透明度棋盘。仍缺编辑、旋转/任意仿射配准和更多图像指标。 |
| Table Compare | `[~]` | CSV/TSV/分号/管道文本、有界 RFC 4180 风格 parser/serializer、行号或复合 key 对齐、单元格状态与错误诊断；支持匹配行单元格编辑、双向行复制/追加，以及提交前的重复复合 key 事务保护。Save As 保留 UTF-8/BOM 或 UTF-16 LE/BE 与末尾 record terminator，并禁止覆盖任一原输入。仍缺工作簿、多工作表和类型化列；Workspace 标签切换会卸载视图，未保存表格 UI 状态不会跨切换保留。 |
| PDF Compare | `[~]` | PDFKit 有界提取页面文本、页面几何、旋转、标签和公开元数据；输入先经单 descriptor 普通文件/字节/TOCTOU 校验，提供 SHA-256 复核的有界页面预览。Visual 只对当前选中页按需串行渲染到共同白底 RGBA8 画布，支持容差、左右/热图和同步缩放平移；它不改变语义状态，也不进入三类整本结构化报告。尚缺自动整本视觉扫描、批注/表单比较和编辑。 |
| Office Compare | `[~]` | 桌面与 CLI 从包声明识别不含宏的 DOCX/XLSX/PPTX 与 ODS，扩展名仅用于文件选择/Finder 路由。先做 ZIP、OPC/ODF 声明、路径、关系、expanded-name 命名空间、ODF 层级、DTD/实体、加密标记与反炸弹校验，再比较核心属性、Word 段落/扁平表格行、Excel 单元格/公式文本、PowerPoint 幻灯片文本，以及 ODS 工作表、重复行列、类型/显示值、原始公式和合并跨度；所有 ODS 发布字符串均受字符/UTF-8 展开预算约束，解析、repeat 与分块摘要可取消。合法的单元格内嵌套表、covered cell 负载和其它非单元格文本不会进入顶层工作表语义，但仍计入原始 XML 预算并通过 `content.xml` part 摘要暴露变化。所有 part 仅生成有界 SHA-256 摘要。只做结构/逻辑内容比较，不渲染布局、图片或图表，不执行公式、脚本、宏、外部链接或实体。屏幕最多发布 20,000 行，完整结果仍可导出。不支持旧式 DOC/XLS/PPT、宏格式，以及 ODS 图表/图片的视觉或语义解析。 |
| Archive Compare | `[~]` | 桌面与 CLI 从内容识别 ZIP/TAR，可跨格式只读比较成员路径、类型、大小、链接目标和可选内容/mtime/权限/压缩属性；具备路径穿越、CRC、展开率、成员/总字节预算，不落盘解压或跟随链接。屏幕最多发布 20,000 行，完整结果仍可导出。仅支持 ZIP/TAR，缺少写入、嵌套归档、7z、RAR 和 ISO。 |
| Metadata Compare | `[~]` | 使用 `O_EVTONLY | O_SYMLINK` descriptor 绑定目录项，比较类型、大小、创建/修改时间、权限、uid/gid、BSD flags、符号链接本身，以及有界 xattr 和 macOS extended ACL SHA-256 摘要；结束前重验 descriptor 稳定性与路径 inode，不跟随链接。结果不含绝对路径、原始 xattr 值、ACL principal 或权限主体。尚缺 Finder 标签/ACL 编辑和属性复制。 |
| Version Compare | `[~]` | 比较普通文件、Mach-O、app/framework/bundle 的版本字段、架构、部署目标、可执行 SHA-256 与系统签名状态；支持 thin/fat 文件和三类报告。尚缺资源型无主可执行 bundle、版本资源编辑和更深签名证书链 UI。 |

## 共享工作流与核心

### 已落地

- [x] SwiftUI 原生应用壳、原创品牌与 App Icon、十五会话主页和 arm64 `.app` 打包。所有窗口
  使用基于 `DESIGN.md` 的 System/Light/Dark 自适应主题、四级 surface/hairline、单一 accent
  和可访问焦点状态；Midnight 为默认预设，另有 Graphite、Ocean、Forest、自定义 accent 与
  分离 Light/Dark 变体的严格 JSON 主题。打包时由原创 1024px 主图生成 `.icns`。
- [x] 主页、Settings、Session Library、Workspace、十五类会话，以及 Resource Tools 的快照、
  归档、WebDAV 和操作历史页均已接入共享 header/path/control/pane/status/empty-state 视觉语言，
  并按同一自适应主题完成布局与控件层级优化。差异、冲突、添加、删除和危险状态同时
  提供文字、符号或图标，不只依赖颜色。ImageGen 实现参考覆盖 26 个页面/模式和一张主视觉系统，
  每张参考图的完整提示词均随仓库归档。
- [x] Settings 可在 System、English 和简体中文之间运行时切换语言，并在所有窗口同步更新
  System/Light/Dark、四个预设、自定义 accent 和导入主题。UI、Info.plist 与 Finder Services
  String Catalog 都要求 English/简体中文译文和一致的格式占位符；release 打包会先运行验证，
  再编译并检查 `en.lproj` 与 `zh-Hans.lproj` 的三个 strings table。
- [x] 主题导入使用 64 KiB、schema v1、未知字段拒绝的本地 JSON；至少一个非空 Light/Dark
  变体为必填，缺失变体和 token 只继承当前 preset。规范化副本原子保存在 App Sandbox 的 Application
  Support 主题目录，不执行脚本、不加载远程资源，也不接受符号链接或任意外部路径。
- [x] 十一种双向会话（Text、Folder、Hex、Image、Table、Media、PDF、Office、Archive、Metadata、Version）
  提供自包含 HTML、纯文本与稳定 JSON 报告；合并、同步和补丁会话不计入该数量。图片 mask
  只报告摘要，默认不泄露资源 locator、绝对本地路径或原始 Data。
- [x] `riffa` CLI：`text`、`folder`、`sync`、`hex`、`pdf`、`metadata`、`version`、`office`、
  `archive-compare`、`merge`、`table`、`patch`、`patch-apply`；
  `snapshot-create`、`snapshot-compare`、`snapshot-diff`、`archive-list`、`archive-read`；
  补丁应用只写标准输出，比较命令支持 JSON 与 0/1/2 退出码，归档读取不会跟随链接。`sync`
  默认只读计划；apply 要求独立 backup、方向复述、高风险额外门控，并接入正式 journal 执行器。
- [x] Unified Patch：从文本 diff 生成、严格解析、上下文校验及原子应用，并已接入桌面
  Text Compare；保留 LF/CRLF/CR 和无末尾换行语义。
- [x] `SessionCatalog` 核心：Codable/Sendable 会话与 Workspace、版本 envelope、actor 串行更新、
  引用验证、稳定排序和原子文件替换；损坏、旧版和未知未来 schema 不会被静默覆盖。
- [x] Session Library：十五类会话均可保存，支持分组、搜索、重命名、锁定、删除、导入与导出；
  合法且仍存在的本地资源会按保存的准确会话类型重新打开。当前 UI 使用主题化搜索、分组列表、
  详情动作和明确的空/载入状态，纯图标动作具备可访问名称。
- [x] Finder/“打开方式”本地资源入口：按目录和受支持文件类型路由；三个目录/文本文件分别
  进入 Folder Merge/Text Merge，两份 Office 或 ZIP/TAR 文件进入对应专用会话，过量或不支持
  的三输入明确失败而不截断。打包 App 还声明四个标准 Finder Services，可选择进程内 pending
  左文件/文件夹，或以两项直接比较、一项配对；`lstat` 严格拒绝链接和特殊节点，错误不泄露路径。
- [x] 基于已保存会话的 Workspace 窗口/标签编排：可创建、重命名和删除窗口，添加、移除、
  排序标签并恢复活动标签；多个窗口共享串行 catalog 更新。主题化 manager 和 tab strip 提供
  明确选择、禁用、保存和错误状态及可访问图标动作；每个窗口仅挂载活动标签，避免后台读取
  全部资源。
- [x] Resource Tools 文件夹快照：版本化、原子保存，记录元数据与分块 SHA-256；支持比较
  快照与实时目录或两个快照，不保存文件内容和源目录绝对路径。
- [x] Resource Tools 只读 ZIP/TAR：安全列出、预览和导出单个普通成员，包含路径穿越、
  CRC、大小限制和链接防护；不会隐式“全部解压”。
- [x] Resource Tools 只读 WebDAV 浏览：PROPFIND/HEAD/GET、目录导航、文本/十六进制预览、
  单资源导出，以及同一连接内两个远程文本文件的直接只读比较。强 ETag 使用 `If-Match`；无强
  ETag 时双读并流式复核 SHA-256；仅接受单个 transport-safe 强标签，并绑定 HEAD/GET/复读的
  最终相对路径。远程文本另有限制字节、逻辑行、单行和发布行的派生内存预算，可取消 diff、预览、
  网络与有界原子 HTML 报告；离场清连接和内存 secret。支持显式 Basic/Bearer 凭据，默认不记住，
  也可精确保存/读取/忘记 Keychain 凭据，secret 与服务器绝对地址不进入比较报告。
- [x] `DecodedTextDocument`：严格、有界的 UTF-8/BOM 与 UTF-16 LE/BE 加载，保留编码、
  BOM 和路径无关指纹；乐观保存会拒绝外部内容冲突。
- [x] `OperationJournal`：版本化恢复元数据、严格 journal/step 状态机、原子写入、跨 actor
  并发保护、未完成扫描、终态归档与仅日志清理；Folder Compare/Merge/Sync 正式执行已接线，
  Resource Tools 提供活动/归档历史 UI。未完成记录会经 descriptor-safe 只读 recovery analyzer
  分类为可认定完成、可认定回滚、需人工判断、现场矛盾或不可安全观察；前两类全事务一致结论可在
  用户二次确认后，由 store 在跨进程锁内复核 revision 与全部证据并以一次 atomic replacement 只
  终态化 journal 元数据。它不触碰用户文件，也不会凭不足证据写入。
- [x] App Sandbox、用户选择 read-write entitlement、app-scope security bookmark、Keychain
  凭据和本地 ad-hoc Hardened Runtime 构建。
- [x] 通用有界本地文件读取；文件夹枚举具备条目、深度和 UTF-8 路径预算，Folder Snapshot
  另有总哈希字节预算，重命名检测另有候选/单文件/总哈希预算，特殊文件不阻塞。Folder 内容
  比较使用 no-follow descriptors、枚举 identity 和最终路径重绑定校验；PDF 在 PDFKit 前完成
  单 descriptor 有界读取和完整版本复核。Text Diff/Unified Patch 具备算法工作量和真实输入
  行数预算。
- [x] Swift 6/macOS 14 核心自动化测试，以及主题/本地化格式和打包前验证。

### 尚未形成完整产品闭环

- [~] Workspace 已支持基于保存会话的多窗口/标签、顺序和活动项恢复；尚不捕获/恢复窗口
  frame，也没有原生跨窗口标签拖拽。切换标签会卸载非活动比较视图，瞬时选择、滚动位置和
  未保存 UI 状态不会跨切换保留。Session Library 仍缺非本地资源恢复及完整会话内状态恢复。
- [~] Folder Compare/Merge/Sync 已逐步落盘并有操作历史；跨启动遗留现场已有逐步骤评估、History
  展示和安全结论的确认式 journal 终态写回。尚缺可证明的文件级自动恢复策略、继续执行及完整
  recovery wizard。
- [~] 安全书签、App Sandbox、Keychain 与四个 Finder Services 已落地；尚缺 Finder
  Extension。Services 只在用户显式选择本地项目时接收授权，不持久化 pending 左侧路径。

## 主要剩余差距

### 比较与编辑

- [~] Text Merge 已有覆盖冲突选择与手工输出的有界差量 Undo/Redo；跨其它可编辑会话的统一
  撤销/重做、编辑器书签、差异缩略图和一致文件监听仍未完成。文本正则替换及 Text
  Compare/Merge 外部修改协调已完成。
- [ ] 语法/注释/正则规则、“非重要差异”、手工对齐及大文件流式索引。
- [~] 文件夹比较已有选中项双向复制/替换/删除；唯一同内容移动/重命名建议可在 Folder Compare
  直接执行为父目录已存在的目标侧内部 move，Folder Sync Mirror 也可折叠并执行同类候选，两者都
  会重验 proof、确认并写 journal。单个普通文件另支持同父目录显式 rename，包括带两阶段原子
  安装、journal 和回滚保护的仅大小写 rename。跨目录任意移动、目录/链接重命名、属性操作、
  监听刷新和大目录虚拟树尚缺。
- [ ] 图片、十六进制和媒体的编辑与安全保存。Office/PDF/Archive 当前都是只读结构或内容
  比较；PDF 仅有当前选中页的按需有界视觉比较，未做自动整本视觉扫描，Office 未做视觉渲染。

### 资源与自动化

- [~] ZIP/TAR 已有安全只读提供器、Resource Tools 浏览器和专用 Archive Compare 会话；
  归档成员尚不能作为其他会话的通用比较侧，也缺少写入、嵌套归档、7z、RAR 和 ISO。
- [~] WebDAV 已有只读提供器、Resource Tools 浏览器及同一连接内的双远程文本比较；**尚未接入
  十五类比较会话的通用资源侧**，也没有远程写入。SFTP、FTP/FTPS、S3、Dropbox、OneDrive 和
  SVN 尚未实现。
- [~] `riffa sync` 已提供无界面 dry-run/apply、稳定 JSON、强门控、journal 与 0/1/2 退出码；
  尚缺批处理/脚本语言、计划文件、定时任务和稳定的跨版本自动化 API。

### 发布质量

- [ ] 大文件/大目录性能基准、属性测试、golden、故障注入和 XCUITest。
- [~] 当前 UI、Info.plist 与 Finder Services 已提供 English/简体中文 String Catalog、运行时
  切换、占位符一致性检查和打包资源检查；仍缺逐页人工语言校对，以及完整 VoiceOver、键盘和
  System/Light/Dark × 提高对比度组合验收。
- [ ] Developer ID、公证、自动更新和发布渠道验证；本地包已启用 Hardened Runtime 与 App
  Sandbox，正式签名仍需重新验证 entitlement 与公证票据。

## 明确不做

- [x] 不实现 Beyond Compare 的密钥、注册、试用绕过、许可证或授权兼容逻辑。
- [x] 不复制 Beyond Compare 的代码、图标、资源、商标或界面素材。
- [x] 不支持 Intel Mac、Windows 或 Linux；目标平台仅 macOS arm64。
- [x] 不实现 Windows Registry、Explorer Shell 扩展、COM 或其他 Windows 专用能力。
