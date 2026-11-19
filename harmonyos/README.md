# 即图 SnapRelay · HarmonyOS NEXT 客户端

需要 HarmonyOS 6.1（API 23）或更新版本。应用使用图库提供的「截图」相册自动同步，也支持从系统相册手动选择图片。

## 构建和真机调试

1. 使用 DevEco Studio 6.1 或兼容工具链，打开这个目录。Hvigor 要求工程路径不含中文。若当前项目位于含中文的路径，可用 `ditto harmonyos ~/Developer/screenshotsync-harmony` 复制到开发目录，再打开副本。[Hvigor 路径要求](https://developer.huawei.com/consumer/cn/doc/doccenter-deveco-studio/ide-hvigor-errorcode-00306/)
2. 在 DevEco Studio 的 **File → Project Structure → Signing Configs** 配置真机调试签名。可用自动签名申请调试 Profile，并检查其中包含 `ohos.permission.READ_IMAGEVIDEO`。发布包需要通过 AppGallery Connect 配置已批准该权限的发布 Profile。[调试签名](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/ide-signing-auto/) · [受限权限申请](https://developer.huawei.com/consumer/cn/doc/HarmonyOS-Guides/declare-permissions-in-acl/)
3. 连接已启用调试的鸿蒙手机并点击 **Run**。也可在已配置的命令行环境中从工程目录运行 `hvigorw assembleHap --mode module -p product=default -p module=entry@default`。[Hvigor 命令行](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/ide-hvigor-commandline/)
4. 在同一局域网打开 Mac 上的「即图」，在手机填写 Mac 地址和配对码并连接。配对验证成功后，即图会记下自动同步起点。允许访问完整相册后，起点之后截取并保存到相册的新截图会自动同步。
5. 点「手动选图」可多选历史截图或普通照片，确认目标 Mac 后发送。手动选图也可在自动同步暂停或未授予完整相册权限时使用。

手机返回应用时会检查待同步截图。在后台，应用以两小时周期请求 Wi‑Fi 条件下的系统延迟任务。执行时机由系统决定，较少使用的应用可能更久才获调度。[HarmonyOS 延迟任务](https://developer.huawei.com/consumer/en/doc/HarmonyOS-Guides/work-scheduler/)
