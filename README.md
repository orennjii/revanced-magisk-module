# Morphe APK Builder (Root)

专为已 Root 并配合官方 Google Play Services 的设备构建 **YouTube** 与 **YouTube Music** 的 Morphe `arm64-v8a` APK。

---

## 核心特性

- **固定目标**: 仅构建 YouTube 与 YouTube Music。
- **纯 APK 输出**: 仅生成直接安装的 APK，不生成任何 Magisk / KernelSU 模块。
- **保留官方包名**:
  - YouTube: `com.google.android.youtube`
  - YouTube Music: `com.google.android.apps.youtube.music`
- **无需 MicroG / GmsCore**: 构建时显式禁用 `GmsCore support`，原生依托 Google Play Services 运行。
- **架构专精**: 仅保留 `arm64-v8a` 原生库，减小体积并提升性能。
- **动态版本跟踪**: 自动基于当前 Morphe 官方发布的 Patches & CLI 确定最新稳定兼容版本。

---

## 前置环境要求

1. **Android 设备已 Root**。
2. **已解决系统的签名校验限制**（如通过 LSPosed 模块「核心破解 / Core Patch」或类似机制，允许覆盖安装官方包名或签名不一致的 APK）。
3. **已安装 Google Play 服务（GMS）**。
4. **无需安装 MicroG / GmsCore**。

---

## 构建方式

### 方式一：GitHub Actions 自动构建（推荐）

1. 进入仓库页面，点击 **Actions** 标签。
2. 在左侧选择 **Build Morphe APKs**。
3. 点击右侧 **Run workflow** -> 选择分支（`main`）-> 点击 **Run workflow**。
4. 构建完成后：
   - 可以在该次运行页面的 **Artifacts** 下载 `morphe-apks` 压缩包（包含两个 APK 及 `build-info.json`）。
   - 若勾选了发布 Release 或推送了 `v*` 标签，会自动在 Releases 页面发布成品。

### 方式二：本地运行构建

运行前确保系统已安装 Java 21+、curl、jq、unzip、zip、apksigner。

```bash
git clone https://github.com/orennjii/revanced-magisk-module.git
cd revanced-magisk-module
chmod +x build.sh scripts/*.sh
./build.sh
```

构建完成后产物位于 `build/` 目录：
- `youtube-morphe-vX.Y.Z-arm64-v8a.apk`
- `youtube-music-morphe-vX.Y.Z-arm64-v8a.apk`
- `build-info.json`

---

## 安装方法

由于 APK 保持了官方包名：
1. 确保系统核心破解（Core Patch）已启用“允许降级安装 / 覆盖安装签名不同的应用”。
2. 直接通过系统文件管理器或 `adb install -r <apk>` 安装对应的 APK 即可。
3. 直接使用系统自带的 Google 账号登录，无需任何 GmsCore。
