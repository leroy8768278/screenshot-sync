# 截图同步

把手机上保存到系统相册的截图自动传到同一局域网里的 Mac。Mac 接收时保留原始图片字节，可以修改保存位置、查看最近接收记录和暂停接收。手机默认从启用时开始同步，首次配对时可以选择补传已有截图。

## 使用方式

1. 打开 Mac 上的「截图同步」，保持应用运行。关闭窗口后，仍可从菜单栏打开接收端。
2. 让手机和 Mac 连接到同一局域网。在手机端填入 Mac 显示的地址和配对码。
3. 在手机端授予相册读取权限。iOS 还需要授权访问本地网络。自动读取新截图需要完整相册权限。
4. 拍一张截图并把它保存到系统相册。初次联调可以回到手机端触发同步，然后在 Mac 的「最近接收」查看。默认保存到 `~/Pictures/截图同步`。
5. 如果 Mac 换了网络或 IP，在手机端更新地址。只要 Mac 配对码未变，手机可继续当前配对的传输记录。

首版面向可信的家庭或办公局域网，通过带配对码的明文 HTTP 传输。配对码和截图内容在传输过程中可被监听。截图库的同步目标是填写的 Mac 地址，应用无需账号或云端中转。

## 工程

| 平台 | 工程 | 构建与运行 |
| --- | --- | --- |
| macOS 13+ | [macOS](macOS) | 安装 Swift 6 工具链，执行 `./macOS/build-app.sh`。双击 `macOS/dist/截图同步.app`。脚本默认按构建机器的架构生成本机临时签名包。 |
| iOS 17+ | [ios/ShotSync.xcodeproj](ios/ShotSync.xcodeproj) | 用 Xcode 打开项目，选择模拟器。安装到真机需要开发团队签名和设备配对。 |
| Android 10+ | [android](android) | 在 Android Studio 打开项目，或使用 JDK 17 和 Android SDK 36，在 `android` 目录运行 `./gradlew assembleDebug`。 |
| HarmonyOS NEXT（API 23+） | [harmonyos](harmonyos) | 将工程放在纯 ASCII 路径下，用 DevEco Studio 配置 SDK 和签名。自动读图库需要有 `ohos.permission.READ_IMAGEVIDEO` 的签名 Profile。[构建和授权步骤](harmonyos/README.md) |

## 自动同步的实际表现

- **iOS** 使用系统照片库的截图标记识别截图。应用在前台时会监听相册变化，返回应用时会补传。后台刷新由系统调度。截图从系统预览界面保存到「照片」后才可同步。[照片库截图类型](https://developer.apple.com/documentation/photos/phassetmediasubtype/photoscreenshot) · [后台任务](https://developer.apple.com/documentation/backgroundtasks/)
- **Android** 在前台监听媒体库，通过常见截图目录和文件名识别。特殊厂商的图库命名可能需要补充适配。WorkManager 按 15 分钟的最短周期安排后台扫描，实际时点受系统省电策略影响。[WorkManager 调度](https://developer.android.com/develop/background-work/background-tasks/persistent/getting-started/define-work)
- **HarmonyOS NEXT** 按系统公布的路径读取截图相册。后台通过 Work Scheduler 补传，触发时机受系统约束，受限图库权限也需要华为签名授权。[相册路径](https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-apis-photoaccesshelper-e/) · [后台延迟任务](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/work-scheduler/) · [受限权限](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/restricted-permissions/)

要在同一网络接收截图，Mac 必须保持唤醒、接收端保持运行。若使用访客 Wi‑Fi 或开启了局域网设备隔离，手机和 Mac 可能无法互访。

## 验证状态

- **Mac** 已生成本机试用包。实际接收端通过配对校验、原始字节保留、并发去重和中断清理测试。
- **iOS** 模拟器和真机目标均已编译。在 iOS 模拟器上通过界面完成配对和相册授权。应用自动识别配对后新增的截图样本，Mac 收到字节一致的 PNG，并验证了普通照片和配对前截图默认跳过。真机安装和后台实际执行时机仍需验证。
- **Android** 已生成调试 APK。在 Android 15 模拟器上验证了系统截图自动上传、新截图过滤、原始字节保留和重扫去重。后台实际执行时机仍需真机验证。
- **HarmonyOS NEXT** 已用 OpenHarmony API 23 工具链做静态检查，华为专有的网络组件使用接口替身，并验证了协议与真实 Mac 接收端兼容。当前机器缺少华为 HarmonyOS SDK，仍需构建 HAP 并用有图库权限的签名 Profile 在真机验证。

## 局域网接口

Mac 默认使用 TCP 端口 `43871`。手机可用 `GET /v1/health` 检查连接并附加 `Authorization: Bearer <配对码>` 校验配对码。

手机上传时发送 `POST /v1/screenshots`，使用原始图片字节作为请求体。包含以下请求头。

| 请求头 | 用途 |
| --- | --- |
| `Authorization` | `Bearer <配对码>` |
| `X-Screenshot-ID` | 每张截图的稳定标识，1–256 个可见 ASCII 字符 |
| `Content-Type` | `image/*` 对应的 MIME 类型 |
| `Content-Length` | 原始文件长度，上限 64 MiB |
| `X-Filename` | 手机客户端可附带的文件名 |

首次保存返回 HTTP 201，同一 ID 已保存在当前目录时返回 HTTP 200。Mac 根据图片内容选择文件扩展名，用截图 ID 的散列作为文件名后缀。
