# 即图 · SnapRelay

把手机与 Mac 配对成功后新截取的截图自动传到同一局域网里的 Mac，也可以手动选择历史截图和普通照片发送。Mac 接收时保留上传的图片字节。

## 使用方式

1. 打开 Mac 上的「即图」（SnapRelay），保持应用运行。关闭窗口后，仍可从菜单栏打开接收端。
2. 让手机和 Mac 连接到同一局域网。点 Mac 窗口右上角的「连接」，在手机端填入显示的地址和配对码。验证成功时会记下自动同步的起点。iOS 需要授权访问本地网络。
3. 授予完整相册权限后，App 可自动发现起点之后截取并保存到相册的新截图。短暂断网、重开手机 App 或更新同一配对的地址会沿用起点。断开后重新配对或改用新配对码时，验证成功会建立新的起点。
4. 点「手动选图」，用系统相册多选截图或照片。确认目标 Mac 和图片数量后发送。手动选图使用系统为本次选择授予的图片访问权限，自动同步暂停时也可使用。
5. 暂停自动同步可中断正在进行的自动传输。继续后，App 会检查配对起点之后尚未发送的截图。Mac 已收的图片会保留，重试时会按传输 ID 去重。
6. Mac 画廊按 iOS、Android、鸿蒙分类。首次收到带设备标识的图片后会显示对应手机的子标签，可在「管理手机」中重命名。点缩略图可预览，用两侧按钮或 `←` / `→` 浏览当前筛选里的图片。点「复制图片」或按 `⌘C` 可复制当前图片。图片默认保存到 `~/Pictures/截图同步`。

从旧版升级时，现有配对会在新版首次成功验证 Mac 后建立同步起点。此前截取的图片可通过「手动选图」发送。

首版面向可信的家庭或办公局域网，通过带配对码的明文 HTTP 传输。配对码和截图内容在传输过程中可被监听。截图库的同步目标是填写的 Mac 地址，应用无需账号或云端中转。

## 工程

| 平台 | 工程 | 构建与运行 |
| --- | --- | --- |
| macOS 13+ | [macOS](macOS) | 安装 Swift 6 工具链，执行 `./macOS/build-app.sh`。双击 `macOS/dist/即图.app`。脚本默认按构建机器的架构生成本机临时签名包。 |
| iOS 17+ | [ios/ShotSync.xcodeproj](ios/ShotSync.xcodeproj) | 用 Xcode 打开项目，选择模拟器。安装到真机需要开发团队签名和设备配对。 |
| Android 10+ | [android](android) | 在 Android Studio 打开项目，或使用 JDK 17 和 Android SDK 36，在 `android` 目录运行 `./gradlew assembleDebug`。 |
| HarmonyOS NEXT（API 23+） | [harmonyos](harmonyos) | 将工程放在纯 ASCII 路径下，用 DevEco Studio 配置 SDK 和签名。自动读图库需要有 `ohos.permission.READ_IMAGEVIDEO` 的签名 Profile。[构建和授权步骤](harmonyos/README.md) |

## 自动同步的实际表现

- **iOS** 使用系统照片库的截图标记识别截图。应用在前台时会监听相册变化，返回应用时会补传。后台刷新由系统调度。截图从系统预览界面保存到「照片」后才可同步。[照片库截图类型](https://developer.apple.com/documentation/photos/phassetmediasubtype/photoscreenshot) · [后台任务](https://developer.apple.com/documentation/backgroundtasks/)
- **Android** 在前台监听媒体库，通过常见截图目录和文件名识别。特殊厂商的图库命名可能需要补充适配。WorkManager 按 15 分钟的最短周期安排后台扫描，实际时点受系统省电策略影响。[WorkManager 调度](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)
- **HarmonyOS NEXT** 按系统公布的路径读取截图相册。后台通过 Work Scheduler 补传，触发时机受系统约束，受限图库权限也需要华为签名授权。[相册路径](https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-apis-photoaccesshelper-e/) · [后台延迟任务](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/work-scheduler/) · [受限权限](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/restricted-permissions/)

要在同一网络接收截图，Mac 必须保持唤醒、接收端保持运行。若使用访客 Wi‑Fi 或开启了局域网设备隔离，手机和 Mac 可能无法互访。

## 验证状态

- **Mac** 已生成本机试用包。隔离接收端验证了三平台来源归类、配对校验、手动照片和自动截图的原始字节保留，以及重复请求去重。
- **iOS** 模拟器和未签名真机目标均已编译。模拟器验证了配对时无上传、配对起点和暂停状态跨重启保留，以及拒绝完整相册权限后多选、确认并发送原始图片。真机安装和后台实际执行时机仍需验证。
- **Android** 已生成调试 APK。Android 15 模拟器验证了配对时间筛选、暂停跨重启保留、恢复补传、无完整相册权限时多选发送，以及失败重试和去重。Android 10–12 的选图兼容路径和后台调度仍需设备验证。
- **HarmonyOS NEXT** 已用 OpenHarmony API 23 工具链做静态检查。使用系统接口的测试替身验证了配对时间筛选、同一 Mac 更换地址、手动选图发送、暂停、取消和重试。构建 HAP 和真机验证需要华为 HarmonyOS SDK、签名 Profile 和鸿蒙设备。

## 局域网接口

Mac 默认使用 TCP 端口 `43871`。手机可用 `GET /v1/health` 检查连接并附加 `Authorization: Bearer <配对码>` 校验配对码。

手机上传时发送 `POST /v1/screenshots`，使用原始图片字节作为请求体。包含以下请求头。

| 请求头 | 用途 |
| --- | --- |
| `Authorization` | `Bearer <配对码>` |
| `X-Screenshot-ID` | 每张截图的稳定标识，1–256 个可见 ASCII 字符 |
| `X-Device-ID` | 可选。手机 App 安装级标识，32 位小写十六进制字符，用于区分同一平台下的多部手机 |
| `Content-Type` | `image/*` 对应的 MIME 类型 |
| `Content-Length` | 原始文件长度，上限 64 MiB |
| `X-Filename` | 手机客户端可附带的文件名 |

首次保存返回 HTTP 201，同一 ID 已保存在当前目录时返回 HTTP 200。Mac 根据图片内容选择文件扩展名，用截图 ID 的散列作为文件名后缀。iOS、Android、鸿蒙客户端现有的 `ios-`、`android-`、`harmony-` ID 前缀用于记录来源。
