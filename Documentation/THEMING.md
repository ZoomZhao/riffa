# 主题与本地化

Riffa 的主题系统面向 macOS 14 及以上版本。它保持 `DESIGN.md` 的 surface、hairline、单一
accent 和语义状态层级，同时允许用户选择系统外观、内置预设、自定义强调色或经严格验证的
本地 JSON 主题。主题只改变表现层，不进入比较结果、会话资源或报告。

## 外观与内置预设

Settings 可即时切换三种外观：

- **System**：跟随 macOS 当前 Light/Dark 外观。
- **Light**：固定使用所选预设的浅色变体。
- **Dark**：固定使用所选预设的深色变体。

Riffa 提供四个同时包含 Light/Dark 变体的内置预设：

- **Midnight**：默认预设；深色变体延续 Riffa 的近黑 canvas 与 lavender accent。
- **Graphite**：更中性的灰阶 surface 与低彩度强调色。
- **Ocean**：蓝色强调色和冷色 surface。
- **Forest**：绿色强调色和克制的暖灰/绿色 surface。

外观、预设、自定义 accent 和导入主题身份都通过稳定的 UserDefaults key 持久化。重置主题会
恢复 System + Midnight，并清除自定义 accent 与当前导入主题。

## 解析顺序

当前颜色按以下顺序解析，后者覆盖前者：

1. 当前外观对应的内置预设变体。
2. 导入 JSON 主题中同一外观的语义 token。
3. Settings 中的自定义 accent。

自定义 accent 是最后一层，只替换 `accent`，并派生相应的 hover、focus 和可读前景色；它不会
重写 `success`、`warning`、`danger` 等比较语义。提高对比度、降低透明度、减少动态效果和
“不使用颜色区分”仍由系统辅助功能环境控制。状态必须继续包含文字、符号或图标，不能只靠颜色。

## JSON 主题格式

导入文件采用严格、版本化的 JSON。当前仅支持 `schemaVersion: 1`，最大编码大小为 64 KiB。
主题必须至少提供一个非空的 Light 或 Dark 变体；每个变体内部可以只列出需要覆盖的 token，
其余值继承当前内置预设。未提供的另一外观会完整回退到当前内置预设，因此同一文件可只定制
Light、只定制 Dark，或同时定制两者。

```json
{
  "schemaVersion": 1,
  "id": "com.example.cobalt",
  "name": "Cobalt",
  "light": {
    "accent": "#3659C9",
    "accentHover": "#2948AD",
    "accentFocus": "#304FBC",
    "onAccent": "#FFFFFF"
  },
  "dark": {
    "accent": "#7C91FF",
    "accentHover": "#98A7FF",
    "accentFocus": "#8799FF",
    "onAccent": "#080B14"
  }
}
```

约束如下：

- 顶层只允许 `schemaVersion`、`id`、`name`、`light` 和 `dark`。
- `id` 必须为 1–64 个 ASCII 字母、数字、点、下划线或连字符，并以字母或数字开头。
- `name` 必须为 1–80 个可见字符，不能包含控制字符。
- `light` 与 `dark` 至少提供一个；凡是提供的变体都必须为非空对象。
- 颜色只接受 `#RRGGBB` 或 `#RRGGBBAA`。
- 未知字段、拼错的 token、未知 schema、非法颜色、空变体和超限文件都会使整个导入失败；
  Riffa 不会静默应用一部分主题。

每个变体允许以下语义 token：

```text
canvas
surface1 surface2 surface3 surface4
ink inkMuted inkSubtle inkTertiary
hairline hairlineStrong hairlineTertiary
accent accentHover accentFocus onAccent
secure success warning danger
```

主题文件不能包含 CSS、字体、图片、脚本、远程 URL、文件引用或任意 SwiftUI/AppKit 类型。
导入成功后，Riffa 将规范化后的 JSON 原子保存到：

```text
~/Library/Application Support/Riffa/Themes/<id>.json
```

在 App Sandbox 构建中该路径位于应用容器内。目录和目标文件不允许使用符号链接；
UserDefaults 只保存所选主题的 ID、显示文件名和 revision，不保存任意外部路径。删除或重置
导入主题不会影响用户原始 JSON 文件。

## 运行时语言

Settings 提供 System、English 和简体中文。English 与简体中文可在运行时切换，不需要重启：

- SwiftUI 字面量通过窗口根节点的 `Locale` 环境刷新。
- `NSOpenPanel`、`NSAlert`、`LocalizedError` 等要求具体 `String` 的 AppKit/Foundation API
  通过 `RiffaLocalization` 使用同一语言偏好；显式语言会直接选择对应 `.lproj` bundle。
- Scene 标题和 Commands 观察同一 `AppStorage` 值，因此主页、窗口标题和应用菜单会同步刷新。
- System 使用 macOS 的自动更新 locale。
- macOS 自己提供的标准菜单、窗口按钮和系统面板继续使用系统语言；Riffa 自定义内容使用
  Settings 中选择的应用语言。

本地化资源分为三个 String Catalog：

- `Localizable.xcstrings`：SwiftUI、AppKit 和动态 UI 文案。
- `InfoPlist.xcstrings`：应用名称、文档类型和版权。
- `ServicesMenu.xcstrings`：四个 Finder Services 菜单项。

## 验证与打包

可单独运行本地化检查：

```bash
zsh ./Scripts/check-localization.sh
```

检查会验证：

- String Catalog 格式、英文 source language 和版本。
- 当前 UI catalog 的完整 key 基线。
- 每个 key 同时具有 English 与简体中文的 translated 值。
- 两种语言的格式占位符签名一致。
- Settings、十五类会话、Resource Tools、主题控件、Info.plist 和 Finder Services 的必需 key。
- 每个 `RiffaLocalization.string("…")` 字面量都已进入 UI catalog。
- `Scripts/dynamic-localization-keys.json` 中 enum/rawValue 等运行时 key 全部可翻译。

`Scripts/build-app.sh` 会在编译前自动执行该检查，再通过 `xcstringstool` 编译三个 catalog，并
要求最终 `Riffa.app` 同时包含：

```text
Contents/Resources/en.lproj/
Contents/Resources/zh-Hans.lproj/
```

两个目录都必须具备 `Localizable.strings`、`InfoPlist.strings` 和 `ServicesMenu.strings`；
任一缺失都会使打包失败。之后脚本才继续执行纯 arm64、plist、entitlement 和严格签名验证。
