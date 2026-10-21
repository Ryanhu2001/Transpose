<p align="center"><img src="docs/images/icon.png" width="72" alt="Transpose 图标"></p>

<h1 align="center">Transpose</h1>
<p align="center">划一下，圈一下，即刻翻译。</p>
<p align="center"><a href="https://github.com/Ryanhu2001/Transpose/releases/latest">下载 Mac / Windows 版</a> · <a href="README.md">English</a> · <a href="docs/installation.md">安装</a> · <a href="docs/privacy.md">隐私</a></p>

轻量的 macOS、Windows 翻译工具。选中文字后出现一个小翻译按钮；按 **⌥S / Alt+S** 可自由圈选。译文显示在原文旁，支持固定、复制和缩放。

## 功能

- 自动划词按钮、自由圈选 OCR，保留边框方便对照。
- 译文窗口支持固定、移动、缩放和复制。
- 中英文设置界面，单行侧栏。
- Apple 翻译、DeepSeek、OpenRouter、自定义 API 和本地 CLI。
- 个人词库、AI 表达偏好。
- 打开应用即显示设置，可自行开启开机自启动。
- 应用内检查更新、验签并安装。

跨 App 行为依赖系统权限和源应用。Windows 支持仍为实验阶段。

## 构建

Mac 构建需要 **Apple Silicon**、**Node.js 22.14+**、稳定版 **Rust**、**Swift 6 / macOS SDK 26.4+**。运行目标为 macOS 14+，Apple 翻译需要 macOS 15+。Windows 构建要求见 [开发说明](docs/development.md)。

```sh
git clone https://github.com/Ryanhu2001/Transpose.git
cd Transpose
npm ci
./verify.sh
./build.sh
open dist/Transpose.app
```

桌面开发使用 `npm run tauri dev`。`npm run build` 构建前端；`npm run tauri build -- --bundles app` 构建应用。`npm run dev` 仅启动浏览器前端，`?preview=1` 显式启用示例数据。

目录：`src/` 前端、`src-tauri/` Rust、`native/Sources/TransposeNative/` Swift 桥接、`tests/` 检查、`scripts/` 脚本、`assets/` 资源、`docs/` 文档。详见 [开发说明](docs/development.md) 和 [参与方式](CONTRIBUTING.md)。

## 权限与服务

Mac 划词需要「辅助功能」，圈选需要「屏幕录制」。截图在本机识别，翻译渠道只接收文字；API Key 保存在 macOS 钥匙串或 Windows 凭据管理器。

Apple 语言包单独下载，系统翻译不应用 AI 词库。其他渠道使用自己的账号和配额，OpenRouter 免费路由存在限制。详见 [服务说明](docs/services.md)。

下载包支持 **Apple Silicon / macOS 14+** 和 **Windows 10/11 x64**。Mac 包为临时签名，尚未公证；Windows 安装包尚无 Authenticode 签名。应用内更新另有签名验证。首次安装参照 [安装说明](docs/installation.md)。

## 许可证

[MIT](LICENSE) © Ryan。
