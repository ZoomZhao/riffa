# Riffa 产品基线

## 品牌

- 名称：**Riffa**
- 读音：`RIF-fa`，两个音节
- 含义：来自 `riff`（同一主题上的变化），强调理解变化，而不只是显示红绿行
- 图标：左右两张文件页在中央形成闪电状差异缝；蓝色代表左侧、珊瑚色代表右侧，
  午夜蓝代表可信、专注的本地工具
- 原创生成稿：`Sources/RiffaApp/Resources/AppIcon-1024-v2.png`

名称只做了互联网层面的初步同类产品排查，不构成商标法律意见；正式上架前仍需完成目标
市场的商标与 App Store 名称检索。

## 平台约束

- 仅支持 Apple Silicon (`arm64`)
- 最低 macOS 14
- Swift 6 / Xcode 16.2+
- 原生 SwiftUI + 必要的 AppKit/TextKit 2/Metal 重型视图
- 当前本地开发包采用 App Sandbox、Hardened Runtime，并用 security-scoped bookmark
  持久授权；仍为 ad-hoc 签名，正式发布还需要 Developer ID 与公证
- 打包 App 通过标准 AppKit `NSServices` 提供四个 Finder 比较入口；这是应用服务，不是
  Finder Extension。待配对左侧只驻留当前进程内存，不写入会话目录或偏好设置

## Clean-room 边界

Beyond Compare 5.2.3 只作为公开可观察行为的参考实现。允许记录会话类型、菜单、帮助主题、
输入输出和性能特征；禁止反编译或复制其实现、资源、文案、图标、配置文件和授权机制。
Riffa 不实现密钥输入、破解、试用绕过或任何兼容授权逻辑。

## 交付原则

每个阶段都必须形成可运行的垂直切片：有模型、有 UI 或 CLI 入口、有安全失败行为、
有自动化测试。危险文件操作先生成计划并预览，执行前重新校验源与目标指纹；删除先移动到
用户选择的独立备份区（适合 Finder 语义的单项删除才使用废纸篓），写入采用临时文件、校验
和原子替换，正式文件夹事务写入持久 operation journal。
