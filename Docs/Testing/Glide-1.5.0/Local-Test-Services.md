# 当前 Mac 的局域网测试服务

2026-10-19，按用户“直接创建服务测试”的要求启动。只使用原创测试片、项目演示素材和生成的目录，不共享个人文件。

| 协议 | 地址 | 共享／账号 |
| --- | --- | --- |
| SMB 2/3 | `192.168.0.75:1449` | 共享 `media`，账号 `glide`，测试密码 `glide150-fixture` |
| WebDAV | `http://192.168.0.75:8769/dav/` | 账号 `demo`，测试密码 `demo` |

这些是专门创建的假账号。Mac 的局域网 IP 改变后需重新绑定并更新来源地址。iPhone 与 Mac 要能互相访问；应用须获准访问本地网络。用户确认「Glide NAS 验证」的本地网络和 WLAN 权限并手动重试后，iPhone 13 Pro Max／iOS 27.0 已通过 WebDAV 浏览、原生播放和定位，以及 SMB 目录、范围读取、1080p／MKV／4K HEVC／特殊文件名播放与暂停定位。见 [真机原始报告](SMB-WebDAV-LAN-iPhone-2026-10-19.json)。此前的系统权限拒绝已解除，未确定其具体成因。

SMB 容器 `glide150-lan-samba` 只绑定上述局域网地址，`/tmp/Glide150/share` 以只读方式挂载。可通过 Docker Desktop 启停，或执行：

```sh
docker start glide150-lan-samba
docker stop glide150-lan-samba
```

WebDAV 使用独立的 `Scripts/fixture_server.py` 进程，只提供项目内置演示资源。启动方式：

```sh
GLIDE_FIXTURE_BIND=192.168.0.75 GLIDE_FIXTURE_PORT=8769 \
  python3 -u Scripts/fixture_server.py
```

在前台运行时按 Ctrl-C 停止。当前后台实例的日志位于 `/tmp/Glide150/lan-webdav.log`。压力测试另使用仅绑定 127.0.0.1 的容器，停止上面的局域网实例不会中断模拟器长播。

已在 Mac 本机确认 SMB TCP 可连接、WebDAV PROPFIND 返回 207，系统应用防火墙关闭。真实 iPhone 网络结果见 [当前状态](Physical-LAN-Status-2026-10-19.json)。

本轮自动化结束后，四个仅监听回环地址的压力测试容器及回环 HTTP／阻塞 TCP 辅助进程已停止。上表中的局域网 SMB 和 WebDAV 继续运行，供手机手动测试；「Glide NAS 验证」已切回正常片库，两个测试源均已保存。
