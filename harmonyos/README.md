# 即图 SnapRelay · HarmonyOS NEXT 客户端

需要 HarmonyOS 6.1（API 23）或更新版本。应用使用图库提供的「截图」相册自动同步，也支持从系统相册手动选择图片和视频。

## 构建和真机调试

1. 使用 DevEco Studio 6.1 或兼容工具链，打开这个目录。Hvigor 要求工程路径不含中文。若当前项目位于含中文的路径，可用 `ditto harmonyos ~/Developer/screenshotsync-harmony` 复制到开发目录，再打开副本。[Hvigor 路径要求](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hvigor-errorcode-00306/)
2. 在 DevEco Studio 的 **File → Project Structure → Signing Configs** 配置真机调试签名。可用自动签名申请调试 Profile，并检查其中包含 `ohos.permission.READ_IMAGEVIDEO`。发布包需要通过 AppGallery Connect 配置已批准该权限的发布 Profile。[调试签名](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/ide-signing-auto/) · [受限权限申请](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/declare-permissions-in-acl/)
3. 连接已启用调试的鸿蒙手机并点击 **Run**。也可在已配置的命令行环境中从工程目录运行 `hvigorw assembleHap --mode module -p product=default -p module=entry@default`。[Hvigor 命令行](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/ide-hvigor-commandline/)
4. 手机和 Mac 连入同一局域网。在 Mac 点「扫码配对」显示二维码，在手机点「扫一扫配对」扫描。换电脑时，在手机首页点「扫码更换 Mac」扫描新电脑上的二维码。验证成功后，手机会将新 Mac 设为唯一接收端。也可以手动输入 Mac 地址和配对码。允许访问完整相册后，即图会自动同步配对成功后截取的新截图。
5. 点「手动选图或视频」可多选历史截图、普通照片或视频，确认目标 Mac 后发送。单张图片上限 64 MiB，MP4、MOV 或 M4V 视频上限 512 MiB。手动选择也可在自动同步暂停或未授予完整相册权限时使用。

图库保存新截图并通知即图后，应用立即开始检查，优先发送最新截图。在前台开始发送时可申请短时后台运行，以便切到后台后完成当前批次。进程仍在运行时可处理图库通知。[图库变更通知](https://developer.huawei.com/consumer/en/doc/harmonyos-references/arkts-apis-photoaccesshelper-photoaccesshelper/) · [HarmonyOS 短时任务](https://developer.huawei.com/consumer/en/doc/harmonyos-guides-V13/transient-task-V13/)

鸿蒙挂起应用后，截图会在返回即图时补传，或由系统安排 Wi‑Fi 下的延迟任务补传。应用以两小时周期登记延迟任务，实际执行时机由系统决定。[HarmonyOS 延迟任务](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/work-scheduler/)
