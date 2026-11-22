# 台铃/极核官方 App（EasyConn 车联）解包笔记

分析对象：`base.apk`（313 MB，17 个 dex，51 个 `.so`），SHA-256 前缀 `cda063e9…`。
宿主包为 `net.easyconn.carman`（易网 EasyConn 车联 SDK），台铃、极核共用这套 PXC 协议。

方法：DEX 头解析 → 字符串池 → `class_data_item` / `code_item` 级扫描（无 jadx，未做 Java 反编译）。
结论均为常量与调用点级别的事实，未逐条读字节码语义。

## 1. 手机端监听端口（官方实现）

| 端口 | 监听方 | 类 / 方法 | 说明 |
| --- | --- | --- | --- |
| 10922 | 手机 | `PXCService.startListener` | PXC 会话控制（对应本仓库 control 通道） |
| 10920 / 10921 | 手机 | `MediaProjectService.startListener` | **新媒体通道**（控制 + 数据） |
| 10710 / 10711 | 手机 | `MediaProjectService.startOldRVStartListen` | 旧 RV 通道，由 RV info 回调触发 |
| 10923 / 10924 | 手机 | `SocksService.startSocksServerThread` | SOCKS 代理 |
| 10925 | 手机 | `MICDataService$SendThread` | 麦克风 / 语音数据 |
| 10930 | **仪表** | `WiFiDirectReceiver.tryConnectToServer`、`PxcUtils.connectFormerCar`、`WifiNetworkOwner.tryConnectToServer`、`ParallelConnect.tryConnectDevice`、`MDNSClient$ConnectHandler` | 手机主动连仪表 |

本仓库当前只监听 `10922 + 10711 + 10710`，缺少 `10920 / 10921`。

## 2. 新旧通道的切换点

- `PXCService.<init>` 的 lambda 同时启动 `PXCService.startListener`（10922）与 `MediaProjectService.startListener`（10920/10921）——新媒体通道默认就开。
- `PxcServiceCallBack.onReceiveRvInfo` → `MediaProjectService.startOldRVStartListen`（10710/10711）——旧通道要等仪表发来 RV info 才开。

也就是说：新媒体通道是默认路径，旧 RV 是兼容路径。

## 3. 握手字段差异

`net.easyconn.carman.sdk_communication.C2P.ECP_C2P_CLIENT_INFO`：

- `process`（解析仪表的 0x10010 等价命令）：`HUID`、`HUName`、`pxcVersion`、`supportFunction`、**`supportFunctionEx`**
- `reply`（手机回应）：`encryptedHUID`、`phoneUUID`、`pubkey`、`pxcVersion`、`supportFunction`、**`supportFunctionEx`**、`supportH264IFrame`、`versionCode`

本仓库的回应里没有 `supportFunctionEx`；`pxcVersion` 固定写 `"1.0.2"`；官方存在 `comparePxcVersion` 做版本比较。

## 4. 命令号对照（抽样）

| 值 | 官方枚举 | 备注 |
| --- | --- | --- |
| 0x70000010 | `ECP_PXC_MDNS_RESPOND` | payload 为 `packageName` / `phoneType`，与本仓库 announce 一致 |
| 0x70000020 | `ECP_PXC_AUTH_PENDING` | 认证等待 |
| 0x70000030 | `ECP_C2P_INPUT_SELECTION` / `ECP_P2C_INPUT_SELECTION` | 输入源选择 |
| 0x70000000 | `ECP_SEND_HEART_BEAT` / `ECP_RECEIVE_HEART_BEAT` | 保活，与本仓库一致 |

`ECP_*` 枚举共 529 个，本仓库实现约十余个。

## 5. mDNS

官方 Android 使用 `_EasyConn._tcp.local.`；本仓库发布 `_tds-carkit._tcp.`（来自 iOS 样本）。若仪表侧靠 mDNS 找手机，服务类型不一致会直接找不到。

## 6. 与现场两个现象的对应关系

- **未开仪表投屏时超时**：若苍穹 II 走新媒体通道，它会回连 10920/10921；本仓库没有监听 → 连接被拒或一直不成立 → 只看到「媒体会话未就绪」的超时。另一种解释是"投屏开关还没打开就超时了"，两者需要靠"仪表实际连哪个端口"来区分。
- **官方投屏时 10930 被拒（ECONNREFUSED）**：官方 App 已与仪表建立 PXC 会话，仪表侧 10930 对新客户端关闭（单会话）。这个现象本身不涉及端口猜测。

## 7. 待办

> 第 1-4 项已由第 9 节（jadx 全量反编译）回答，保留原始假设以便对照。

1. 监听端口补齐 10920/10921，并在日志里打印"仪表实际连到哪组端口"——一次实机即可区分"端口不对"与"时序不对"。
2. 握手补 `supportFunctionEx`；`pxcVersion` 不要写死，至少把仪表上报值写进日志。
3. 继续逆向 `MediaProjectService$ServerCtrlThread` / `ServerDataThread`（10920/10921 的帧格式）与 `onReceiveRvInfo` 的触发命令。
4. 有 jadx 的机器上重跑一遍：`jadx -d out base.apk`，优先看 `sdk_communication`、`common.base`、`ble_net` 三个包。

## 8. jadx 反编译后的确认（2026-11-22 追加）

环境：`D:\Program Files\Java\jdk-17`（Temurin 17.0.21.1）、`D:\Program Files\jadx`（1.5.7）。
产物：`D:\apitools\out8`（sdk_communication，615 个类）、`D:\apitools\out5`（MediaProjectService 等，1247 个类）。

### 8.1 端口对是两套，帧格式相同

| 用途 | 新（默认启动） | 旧（RV info ≥ 5000 才启动） |
| --- | --- | --- |
| 控制 | 10921 `MediaProjectService.startListener` | 10711 `startOldRVStartListen` |
| 数据 | 10920 同上 | 10710 同上 |

触发旧通道的代码：`PxcServiceCallBack.onReceiveRvInfo(version, controlType)` → `if (version >= 5000) startOldRVStartListen()`。

控制通道帧：`Protocol.ReqBase`（cmdType + cmdLength + body），命令号与仓库 aux 通道完全对应：
`0x10` 配置采集（`ReqConfigCapture`：encryptedHUID、deviceVideoSize、displayId、wantFps）→ 回 `0x11`；
`0x40` → `0x41`；`0x30` → `0x31`；`0x60` → `0x61`；`0x70` 启动（回 0x71 / 异常回 0x7F02）。

### 8.2 命令号对照（官方 P2C/C2P）

| 仓库里的值 | 官方枚举 |
| --- | --- |
| 0x10010 | `ECP_C2P_CLIENT_INFO` |
| 0x10450 | `ECP_C2P_QUERY_TIME` |
| 0x20020 | `ECP_P2C_APPSTATUS_FOREGROUND` |
| 0x20030 | `ECP_P2C_APPSTATUS_BACKGROUND` |
| 0x20050 | `ECP_P2C_APPSTATUS_SCREEN_UNLOCKED` |
| 0x204c0 | `ECP_P2C_HARDWARE_PERMISSION_STATE` |
| 0x205a0 | `ECP_P2C_DRIVING_MASK_STATUS` |
| 0x70000000 | `ECP_SEND/RECEIVE_HEART_BEAT` |
| 0x70000010 | `ECP_PXC_MDNS_RESPOND` |

### 8.3 握手字段

`ECP_C2P_CLIENT_INFO` 还携带 `supportFunctionEx`（long 能力位）与 `carConfig` / `carModel` / `carBrand` / `dpi` / `screenShape` / `mirrorMode` 等；仓库只实现了其中一小部分。

### 8.4 对苍穹 II 的意义

仓库监听 `10711/10710`（旧通道），官方默认监听 `10921/10920`。若苍穹 II 属于新通道，它会连 `10921/10920`，而仓库没有监听 → 仪表回连失败 → 表现为「媒体会话未就绪」超时（与现场第一段日志一致）。
帧格式已确认相同，因此补齐监听即可验证，不需要先重写协议。

## 9. 方案 B：全量反编译后的结论（2026-11-22 追加）

产物：`jadx -d /d/apitools/all --no-res --no-imports -j 8 base.apk`，44,921 个 `.java`，266 个反编译失败（不影响关键类）。

### 9.1 两套端口共用同一套处理线程

`MediaProjectService.startListener`（新，10921/10920）与 `startOldRVStartListen`（旧，10711/10710）都构造 `ServerCtrlThread(new NetServerSocket(...))` 与 `ServerDataThread(...)`，
而 `ServerCtrlThread.run()` 里 accepted socket 一律交给 `MediaProjectServerCtrlExecuteThread`。

因此新旧的差别**只有端口号**，帧格式、命令集、状态机完全相同：仓库现有 `TailingConnection` 的 aux 处理逻辑可以原样搬到 10921/10920，不需要另写协议。

### 9.2 官方媒体控制通道的命令分派（`MediaProjectServerCtrlExecuteThread.processRequest`，第 642-680 行）

| 命令 | 官方动作 | 仓库现状 |
| --- | --- | --- |
| `0x10` (16) | `handleConfigCapture`：解析 `ReqConfigCapture`，建 ImageReader | 一致（回 `0x11`） |
| `0x20` (32) | `handleScreenEvent`：只处理，不回包 | 一致（`continue`） |
| `0x30` (48) | 回 `0x31` + LE `{5002, 1}` | 一致 |
| `0x40` (64) | 回 `0x41`（空体） | 一致 |
| `0x60` (96) | `handleConfigCaptureExtend`：把**仪表下发的** `supportFunction` 原值回塞，并 `setMovieMode((v & 1) == 1)`；若下发含 `viewAreaConfig` 则回 `{"viewAreaConfig":{"state":0},"supportFunction":v}` | **不同**：仓库固定回 `{"supportFunction":0}` |
| `0x70` (112) | 启动推流 | 一致（回 `0x71`） |
| `0x110` (272) | `handleExecuteShell` | 仓库回 `0x7F02` |
| 其它 | 回 `RLY_UN_SUPPORT`（0x7F02），**不断链** | 一致 |

`0x60` 的差异值得注意：官方是「回显 + 记住 movieMode」，仓库回 0 等于告诉仪表"手机侧没有电影模式/扩展能力"，布局型仪表（横屏、宽屏）可能因此不进入推流。

### 9.3 加密通道：`ECP_C2P_ENABLE_ENC`

`ECP_C2P_ENABLE_ENC.CMD = 67520 = 0x107C0`（仪表 → 手机，走 10922 控制通道）：

```java
setTLSEnable(true);
tokenTls = new Random().nextInt(Integer.MAX_VALUE);
// 回 4 字节：{0x00,0x00,0x00,0x02}
```

此后 `PXCService.isTLSEnable()` 为真，`ServerCtrlThread`（第 923 行）、`ReverseServerCtrlExecuteConnection`（第 62 行）、`TLSSocket` 都会把 socket `wrap(true)` 成 TLS。

仓库完全没有这条命令的实现；如果苍穹 II 按新固件流程先发 `0x107C0`，后续所有媒体 socket 都会按 TLS 握手，明文解析会一路失败。

### 9.4 `CLIENT_INFO` 的接受/拒绝判定（`ECP_C2P_CLIENT_INFO.verifyFlavor`，第 899-916 行）

1. `flavor == Integer.MIN_VALUE`（`ECP_FLAVOR_APP_SDK_TEST`）→ 直接通过；
2. `BuildConfigBridge.isVivo()` → 通过；
3. `isPipeSdk()` → `ProjectConfigUtil.requestConfig(channel, flavor)`，取值 `ALLOW` / `REFUSE` / 其它（`ERROR_AUTH_PENDING`）；
4. 否则 `checkFlavor(flavor, channel)`：一张 flavor ↔ `package_name` 白名单（第 1100-1180 行）。

失败路径 `verifyFlavorFailure()`：回调 `onVerifyFlavorFailure` + `dispatchConnectError(24576)` = `ERROR_CONNECT_FLAVOR_NOT_MATCH`。

`ProjectConfigUtil.requestConfig`（第 33-71 行）会校验本机 project 包名，未知渠道时走 HTTP `project-connect-config`
（`HttpUrlConnectionApi.request(environment.getUrl(), "project-connect-config", buildBody(project, channel, flavor))`），
默认支持集 `isDefaultSupport(int)` = flavour ∈ {0, 3, 4}，HTTP 3042 → `DEFAULT`、3043 → `REFUSE`。

结论：**flavor 校验发生在手机侧**（官方 App 用它拦住未授权渠道），不是仪表强制的。第三方实现不触发它；但也说明仪表把 `flavor` / `package_name` / `supportFunction` 当作识别手机的依据，仓库这些字段要么缺、要么写死，属于"仪表眼里身份不明的手机"。

### 9.5 `CLIENT_INFO` 回复的完整字段（`reply()`，第 972-1005 行）

```
pxcVersion="1.0.2"  phoneUUID  phoneBrand  phoneModel  phoneOsVersion  phoneOs
package  versionCode  token  pubkey  encryptedHUID  bluetoothName
supportH264IFrame=true
supportFunction（或 supportFunctionEx，二选一：仪表带 Ex 就只回 Ex，值与 getAllSupportFunctionEx() 求交）
appVersionFingerPrint
rvPath（仅 transportType == 0）
haveSysScreenInSetting（可选）
```

仓库当前缺 `package` / `phoneBrand` / `supportH264IFrame` / `supportFunctionEx` / `token` 中的多数项，且 `supportFunction` 固定 128。

### 9.6 其它确认

- 台铃专用 flavor 不存在于 `ECP_FLAVOR_APP_SDK_*` 表里；`Constant.PACKAGE_NAME_*` 57 个包名中也没有 `com.tailg.run.intelligence`。台铃走的是通用渠道（`checkFlavor` 里 flavor 0/3/4 一类的默认分支）。
- 台铃 App 侧没有任何 `setFlavor` 调用，投屏入口只有 `EcManager.getManager().startPXC()`（`ControlFragment.java:8170`、`SplashActivity.java:99`、`DemoMainActivity.java:153/157`）。
- `ECP_R2A_RVINFO`（CMD `0x60000010`，8 字节 LE：version、controlType）是触发旧 RV 通道的报文，只在 RV 反向通道上出现。

### 9.7 对苍穹 II 的最终判断与动作

按事实排序，最可能的成因是前两条：

1. **端口对不匹配**：官方默认路径是 10921/10920，仓库只开 10711/10710。仪表回连的端口没人听 → 「媒体会话未就绪」超时。
2. **`0x60` 回 0**：即使连上了控制通道，扩展配置回 `supportFunction:0` 也可能让仪表判定手机不支持当前布局而不启动推流。
3. **身份字段缺失**：`package` / `supportH264IFrame` / `supportFunctionEx` 缺失，部分固件会据此降级或不推流。
4. **`0x107C0` TLS**：新固件开启后，明文媒体通道会握手失败。
5. 旧代码对未知命令直接致命（`App/TailingConnection.swift` 的 control 分支），仪表多送一条命令就断链。

落地顺序：先补 10921/10920 监听（复用 aux handler）→ 修 `0x60` 回显 → 补身份字段 → 未知命令降级为记录 → 再考虑 TLS。
