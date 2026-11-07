# ADR-0011：单文件授权用会话内 bookmark 恢复外部重命名

日期：2026-10-26。关联 #140、P2-08、ACCESS-03、FOLDER-07。

## 决定

用户决定（2026-10-26）：“Sandbox stays on. For a File Grant, first try to follow the rename by resolving the file security-scoped bookmark (bookmarks track the file on the same volume; refresh a stale bookmark). Only if that fails, show the reconnect entry. Do not enumerate the parent directory.”

picsee 在单文件授权的有效 scope 内创建 security-scoped 文件 bookmark，仅保存在 `FileAccess` 会话内存中。外部重命名后解析 bookmark，并在 stale 时于新 URL 的 scope 内刷新；解析或取得 scope 失败时要求用户重新选择文件。绝不通过单文件授权枚举父目录，也不把它升级成 Access Root。单文件 bookmark 不写入 Access Root 存储或 Recent。

原路径仍有文件时先比较已观察的文件资源身份：若旧文件经 bookmark 到了新位置，继续跟随它；否则按原路径读取新文件以识别同路径替换。原路径消失时尝试 bookmark 追踪原文件。根授权内打开的单图使用既有 FolderBrowser/WatchHub 监听，纯 File Grant 使用文件描述符的 vnode 变化提示及回到前台核对。目录根 bookmark 改址时，静默重扫新位置并迁移 WatchHub；无法定位子目录时显示重连入口。

Apple 的 [NSURL bookmark 文档](https://developer.apple.com/documentation/foundation/nsurl)说明 bookmark 通常能跟随同卷的移动或重命名，但不是无条件保证；[沙盒访问指南](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)要求解析后取得并释放 security scope、刷新 stale bookmark。真机签名沙盒行为、跨卷移动、同名复用与事件时序尚未验证，账簿维持单元证据。

## 取舍

此机制维持 File Grant 的单文件边界及 ADR-008 的持久化边界。会话结束即失去追踪，重新打开由用户再次选择；bookmark 失效时不猜测目录中的同名文件。外部同路径替换仍以新修订和内容摘要区分旧像素。

使用“先跟随旧文件资源”的编辑器若把原图重命名为备份，再在原路径写入新图，picsee 会继续显示备份文件；这是保留所看文件身份的取舍。
若旧文件资源已进入系统废纸篓、原路径又有可读的新文件，picsee 改为显示原路径的新图。

注：Picsee 是 Mado 的旧名（#547、ADR-0017）。
