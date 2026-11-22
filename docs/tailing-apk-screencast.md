# 台铃（EasyConn PXC）投屏链路：APK 协议全解与 iOS 实现逐条对照

> 分析对象：`com.tailg.run.intelligence`（jadx 全量反编译，`/d/apitools/all/sources`），内嵌 `net.easyconn.carman` SDK。
> 对照对象：本仓库 `App/Tailing*.swift`（版本以仓库当前 HEAD 为准）。
> 本文所有结论都带 `路径:行号`。凡写「代码中未见」的地方，都是把整个反编译树 grep 过（44921 个 `.java`）确认不存在，不是没找到。

## 0. 读法约定与反编译噪声

1. **路径**：APK 侧路径相对 `/d/apitools/all/sources`；iOS 侧相对仓库根。
2. **端口常量被反编译成资源名**：EasyConn 把端口写成 `R.drawable` 常量，jadx 不会还原 `values/*.xml`，所以代码里看到的是
   `com.eryanet.ite.R2.drawable.bnav_service_icon_charge` 之类的名字。数值在 `com/eryanet/ite/R2.java` 里：
   - `:10945` `bnav_service_dyna_warn_white` = **10921**（新媒体控制）
   - `:10944` `bnav_service_dyna_warn_orange` = **10920**（新媒体数据）
   - `bnav_service_icon_charge` = **10922**（会话控制，见 `PXCService.java:140`）

   `net/easyconn/carman/system/R.java:11771-11773` 里的 `0x7f0806cd..cf` 是**资源 id**，不是端口，别混。
3. **`com.eryanet.ite.R2.color.res_*`** 这类名字是 SDK 混淆后残留的常量类，语义与名字无关，只能按数值反查。
4. **`BuildConfigBridge.getImpl()`** 是 SDK 与宿主 App 的桥，`isSdk()/isFord()` 之类的分支决定默认能力值；台铃走 SDK 分支。

---

## 1. 角色与端口总览

### 1.1 端口表

| 端口 | 谁监听 | 谁连 | 何时开始监听 | 首帧要求 | 读超时 | 出处 |
| --- | --- | --- | --- | --- | --- | --- |
| **10922** | 手机 | 仪表（车机） | `startPXC()` 一开始 | `0x10000`（其它首帧走 `0x20000/0x30000/0x33000` 分支） | `startPXC` 传 `-1` → **无超时**（阻塞） | `PXCService.java:130-150`、`:218-289`、`EcManager.java:1638-1649` |
| **10921** | 手机 | 仪表 | 与 10922 **同一时刻**（`startListen` 里先起 10922，成功后立刻起 10921/10920） | 必须是 `0x10`(16) 或 `0x30`(48) | `SoTimeout` 传 `null`；`clientInfo==null` 时线程内改成 **11000 ms** | `PXCService.java:110-114`、`MediaProjectService.java:565-588`、`MediaProjectServerCtrlExecuteThread.java:42-53`、`:425-441` |
| **10920** | 手机 | 仪表 | 同上 | 必须是 `0x72`(114) | `clientInfo==null && !isMCULite` → **9000 ms**（USB 5000） | `MediaProjectService.java:582-588`、`MediaProjectServerDataExecuteThread.java:63-70`、`:170-200` |
| **10711** | 手机 | 仪表 | **只在仪表发过 `0x30000` 且 `version>=5000` 后** | 同 10921（共用线程） | `null`（无超时） | `MediaProjectService.java:590-610`、`PxcServiceCallBack.java:428-447` |
| **10710** | 手机 | 仪表 | 同上 | 同 10920 | 同上 | 同上 |
| **10930** | 仪表 | 手机（一次性短连接） | 不监听 | 手机发 `0x70000010` | connect/read 各 **3000 ms**，收完即 close | `MDNSClient.java:323-400` |
| 10923/10924 | 手机 | — | 网络共享（SOCKS5） | — | — | `DisplayService.java:2020-2075` 分支内 `Socks5Manager.startSocksServer` |
| 10925 | 手机 | — | 车机麦克风 | — | — | 本次投屏链路不涉及 |

**关键结论（与实车故障直接相关）**：`startPXC()` 一次性把 10922、10921、10920 三个监听全部拉起（`PXCService.java:110-114` + `DisplayService.java:3329-3359`），**不等**仪表说任何话。也就是说「仪表没回连 10921/10920」不会是「我们没准备好」造成的，官方在手机侧从不主动探测这两个端口。

`DisplayService.startListen(true, -1L)` 的 `-1` 让 `SoTimeout` 变成 `null`（`DisplayService.java:3329-3343`：`j<10000||j>60000 ? null : new SoTimeout(...)`），因此 10922 这条连接在官方实现里**永远不因为空闲超时断开**，只在读到错误或对端关闭时结束（`ServerCtrlExecuteThread.java:44-124`）。

### 1.2 监听启动顺序（手机视角）

1. `EcManager.startPXC()`（`EcManager.java:1638-1649`）→ `DisplayService.startListen(true, -1L)`。
2. `startListen(boolean,long)`（`DisplayService.java:939-948`）调用两个私有重载：
   - `a(j, z, wifiEnable)`（`:3329-3343`）→ `PXCService.startListener(anyAddr=true, null)`；**只有这一路带 `z` 标志**，成功后若 `z==true` 才 `MDNSClient.init()` + `executeDiscoverDelay()`。
   - `a(j, z)`（`:3346-3359`）→ `MediaProjectService.startListener(true, null)` → 10921 + 10920。
3. 收到 mDNS 回执 `onMdnsFindEntry()`（`DisplayService.java:1509-1511`）→ `startListen(false)`，即以「只绑本机单播地址」重开一遍监听。
4. 仪表发 `0x30000`（旧 RV 通道协商，`PxcServiceCallBack.onReceiveRvInfo`，`PxcServiceCallBack.java:428-447`）且 `version>=5000` → 追加监听 10711/10710。

顺序上有个坑：`PXCService.startListener` 里 10922 建好后**立刻** `new ServerCtrlThread(...).start()`，而 10921/10920 是在 10922 的 `startListener` 返回之后才起（`PXCService.java:110-114`）。台铃这里两者是同一个同步 lambda，间隔极小，但**如果 10922 先 accept 到 `0x10000` 并极快回完 `0x10011`，而 10921 还没 bind 完，仪表可能拿到 RST/ECONNREFUSED**。我们的实现是「先全部 listen，再 accept」（`App/TailingConnection.swift:132-151`），这点比官方更保守，不是故障源，但值得知道官方时序。

### 1.3 每条连接的生命周期与并发

| 连接 | 线程/实体 | 并发策略 | 结束条件 |
| --- | --- | --- | --- |
| 10922 | `ServerCtrlExecuteThread`（每连接一个线程），由 `PXCForCar` 持有并登记 | 同一时刻**只认一条**：`isSameClientAddress` 不通过就丢弃（`PXCService.java:218-289`、`NetSocket.java:92-106`） | 读头 `Status != OK` → 记录 panic、`removeControlExecuteThread`、`quit()`、回调 `onControlThreadQuit`、return（`ServerCtrlExecuteThread.java:44-124`） |
| 10921 | 机构同上：`MediaProjectService.ServerCtrlThread` → `MediaProjectServerCtrlExecuteThread`（线程名 `RV-Ctrl`） | 旧线程未 `onReleased` 时最多等 5×100 ms；`mPxcForCar.isConnecting()` 且同源地址、或与旧连接同源地址才允许接管，否则 `skip connect` 直接 close（`MediaProjectService.java:915-971`） | 首帧不是 16/48 → 立刻 close（`MediaProjectServerCtrlExecuteThread.java:419-445`）；`receiveData` 返回 -3/-4/-5 → 取消虚拟屏并退出（`:447-600`） |
| 10920 | `ServerDataThread` → `MediaProjectServerDataExecuteThread` | 同一 `displayId` 只保留一条：新连接进来先 `quitDataThread(displayId)`（`MediaProjectService.java:984-1035`） | 首帧不是 114 → 回 `RLY_UN_SUPPORT` 并退出 |
| 10711/10710 | 与 10921/10920 **完全相同**的两个类 | 同上 | 同上 |
| 10930 | `MDNSClient` 一次性 socket | 每次发现一个新仪表就新建一条 | 收到应答即 `close()`（`MDNSClient.java:323-400` finally） |

### 1.4 Socket 选项对照

| 选项 | 官方（APK） | 我们（Swift） |
| --- | --- | --- |
| `SO_TIMEOUT`（10922） | `null`（无限），除非 `startListen` 传了 10000..60000（`DisplayService.java:3329-3343`） | 空闲不限；**收到半个帧后限 10 s**（`App/TailingSocket.swift:108-134`，`App/TailingConnection.swift:464-476`） |
| `SO_TIMEOUT`（10921） | `null`；`clientInfo==null` 时 **11000 ms**（`MediaProjectServerCtrlExecuteThread.java:42-53`） | 同 10922（10 s 半帧保护） |
| `SO_TIMEOUT`（10920） | **9000 ms**（USB 5000），`clientInfo==null` 时生效（`MediaProjectServerDataExecuteThread.java:63-70`） | 同 10922 |
| `TCP_NODELAY` | 三条连接都设 `setTcpNoDelay(true)`（`PXCService.java:219`、`MediaProjectService.java:915-971`、`:984-1035`） | 全局设了（`App/TailingSocket.swift:204-212`）✅ |
| `SO_KEEPALIVE` | 媒体两条连接设 `setKeepAlive(true)`（`MediaProjectService.java:915-971`、`:984-1035`） | **未设** |
| `SO_LINGER` | **代码中未见**（全库无 `setSoLinger`） | 未设（`close()` 先 `shutdown(SHUT_RDWR)` 再 `close`，`App/TailingSocket.swift:156-167`） |
| `listen` backlog | **1000**（`PXCService.java:140`、`MediaProjectService.java:565-588`） | **4**（`App/TailingSocket.swift:53`） |
| 绑定地址 | `anyAddr ? null : InetAddress.getLocalHost()`，**不做 0.0.0.0 回落**（`PXCService.java:140`） | 先绑指定 IP，失败回落 `0.0.0.0`（`App/TailingConnection.swift:138-147`） |

---

## 2. 完整握手时序

### 2.1 前提

投屏要成立，仪表必须能**主动连回手机**：官方用 mDNS 发现 + 10930 回执确认，之后仪表从自己的地址连手机的 10922。跨网段必然失败——这一条在我们的实现里有提示但无补救（`App/TailingConnection.swift:154-158`）。

### 2.2 手机侧时序（代码可证）

```
startPXC()
 ├─ PXCService.startListener(true, null)      → bind :10922, backlog 1000        [PXCService.java:130-150]
 │   └─ ServerCtrlThread.accept()              → 首帧分派 handleConnect            [PXCService.java:218-289]
 ├─ MediaProjectService.startListener(true,null) → bind :10921 + :10920            [MediaProjectService.java:565-588]
 └─ MDNSClient.init() + executeDiscoverDelay()  → 周期向 :10930 发 0x70000010      [DisplayService.java:3329-3343]
```

### 2.3 mDNS 回执（手机主动发，`0x70000010`）

| 项 | 值/行为 | 出处 |
| --- | --- | --- |
| 命令 | `0x70000010`（`ECP_PXC_MDNS_RESPOND`，CMD=1879048208） | `ECP_PXC_MDNS_RESPOND.java:967-1027` |
| payload | `{"phoneType":<平台标识>, "packageName":"<包名>"}` | 同上 |
| 连接方式 | `bind(local,0)` → `connect(car:10930, 3000ms)` → `setSoTimeout(3000)` | `MDNSClient.java:323-400` |
| 判定成功 | 收到 `0x70000011` **且** `status == "true"`（忽略大小写） | 同上 `onResponse()` |
| 收完动作 | 立刻 `close()`；回调 `onMdnsFindEntry()` → `startListen(false)` | 同上 |
| 失败 | 超时/连不上 → 3 s 后由 `executeDiscoverDelay` 再试 | 同上 |

### 2.4 仪表回连 10922 与 `0x10000` 分支

`PXCService.handleConnect`（`PXCService.java:218-289`）先 `setTcpNoDelay(true)`，再按首帧 `cmdType` 分派：

| 首帧 | 处理 | 应答 | 后续 |
| --- | --- | --- | --- |
| `0x10000`(65536) | `mPXCForCar.isSameClientAddress(socket)` 必须通过（否则 `return false`，连接被丢） | **立即回 `0x10001`，16 字节纯头、无 payload**（`:231-232`，`setCmdType(getCmdType()+1)` + `write()`） | `setTLSEnable(false)`、`tokenTls = 0`，起 `ServerCtrlExecuteThread` 进入读循环 |
| `0x20000` | `startNewReverseControlThread(socket)`（P2C 反向控制） | `0x20001` | `onConnect()`，关闭 MCULite 的 C2P/P2C |
| `0x30000` | PXCForRV | `0x30001` | 记 version；`version>=5000` 触发 10711/10710 监听 |
| `0x33000` | PXCForAutoTest | `0x33001` | — |

**两个容易忽略的点**：

1. `0x10001` 是**收到 `0x10000` 就回**，不等 `0x10010`（`PXCService.java:231-232`）。我们一致（`App/TailingConnection.swift:493-495`）。
2. `0x10001` 是「纯头」——`CmdBaseHead.write()` 在 `dataLen<=0` 时 `length=16`，`12..15` 保持缓冲区初始值 0（`CmdBaseHead.java:99-113`）。**第 4 字段恒 0，不回显**。我们这里回显了 `request.identifier`（`App/TailingConnection.swift:495`），见第 9 节。

### 2.5 `0x10010` CLIENT_INFO：仪表发来的字段逐个说明

解析入口 `ECP_C2P_CLIENT_INFO.process()`（`ECP_C2P_CLIENT_INFO.java:641-888`），`payload` 是 UTF-8 JSON 字符串（原始 `request.payload` 就是 JSON 文本，无额外封包）。

| 字段 | 代码类型 | 必需 | 缺省 | 手机侧怎么用 | 出处 |
| --- | --- | --- | --- | --- | --- |
| `flavor` | int | **必需**（`getInt`，缺失抛 `JSONException`） | — | 进 `checkFlavor` 白名单/服务器校验 | `:641-660`、`:1033-1047` |
| `channel` | String | 否 | "" | 渠道判定（如 `13934` 特判屏幕形态、`XF06` 影响语音引擎值） | `:672-683`、`:880-888` |
| `sdkVersion` | String | 否 | "" | 仅记录 | `:641-700` |
| `HUID` | String | 否 | "" | 身份校验主键（`ClientVerify.checkHUID`），并用于 `encryptHUID` 回签 | `:700-760`、`ClientVerify.java:28-73` |
| `HUName` | String | 否 | "" | 与 SP 缓存的 `mUUName` 比较，相等直接放行 | `ClientVerify.java:40-52` |
| `uuid` | String | 否 | "" | 与缓存 `mUUID` 相等直接放行 | `ClientVerify.java:60-66` |
| `supportFunction` | int | 否 | `PXCForCar.getDefaultSupportFunction()`（非 Ford/非 SDK 时 **0**，`PXCForCar.java:1199-1208`） | 能力位；参与 `mSupportFunction` 合并 | `:787-794` |
| `supportFunctionEx` | **long** | 否 | 无 | 存在即 `isNewSupportFunction=true`，`mSupportFunction = Ex | supportFunction` | `:789-794` |
| `transport_type` | int | 否 | 0（读 SP `Constant.SP_TRANSPORT_TYPE`） | `==2` 且远端是 P2P → 记 6；`==0` 时回包里必须带 `rvPath` | `:687`、`:992-994` |
| `screenType` | int | 否 | 1 | 与 `screenShape` 一起决定投屏屏幕形态 | `:672-683` |
| `screenShape` | int | 否 | 1 | 4 → 竖屏方形；3 → 特殊 | `:672-683` |
| `supportSpeechEngine` | int | 否 | **2** | 2002 时若不是 `channel==XF06` 则降为 2001；最终作为 `speechEngineType` **必发**回包 | `:566-594`、`:880-890`、`DisplayService.java:2114-2115` |
| `socketTimeoutPeriodWifi` | int | 否 | **-1** | 非 -1 时覆盖反向控制连接超时（秒） | `:576-590`、`ReverseServerCtrlExecuteConnection.java:40-56` |
| `supportHID`/`supportScreenTouch`/`supportMic`/`dpi`/`enableDPI`/`mirrorMode`/`supportBTCall`/`btAddress`/… | bool/int/String | 否 | 见构造器 | 影响 UI/语音/触摸，不影响握手是否通过 | `:566-594` |
| `enableSockServerAuth` | bool | 否 | false | 是否要求 socket 级鉴权 | `:566-594` |
| `appCheckLicense` | String | 否 | "" | 记录 + 埋点 | `DisplayService.java:2040-2060` |

屏幕形态规则（`:672-683`）：

```
channel=="13934"      → screenType=2, screenShape=1
screenType==3         → screenShape=1? 取 1/2
screenShape==4        → 2 / 2（竖屏方形）
其余                  → screenShape=1
```

**校验失败返回什么**（`ECP_C2P_CLIENT_INFO.java:898-917`、`DisplayService.java:1990-2127`）：

| 情况 | 返回值 | 线上表现 |
| --- | --- | --- |
| `flavor==Integer.MIN_VALUE`、vivo、或 `checkFlavor` 通过 | `0` | 正常回 `0x10011` |
| Pipe SDK 且服务器判 REFUSE | `ERROR_CONNECT_FLAVOR_NOT_MATCH`(0x80000006) | 发 `0x80000030`(AUTH_FAIL) 后**主动断链**，且 `Thread.sleep(1000)` |
| Pipe SDK 且服务器没给结论 | `ERROR_AUTH_PENDING`(0x80000005) | 发 `0x70000020`(AUTH_PENDING)，链路保持，等用户授权 |
| `checkHUID` 返回 -1（`isRefuse` 或 HUID 空） | `ERROR_CONNECT_AUTH_FAIL` | `0x80000030`，断链 |
| `checkHUID` 返回 0（需要用户在手机上点「同意」） | `ERROR_AUTH_PENDING` | `0x70000020`，弹授权框，**不断链** |
| 回调里抛异常 | `ERROR_INVALID_JSON_FORMAT`(-2147483647) | `0x80000020`(CMD_ERR)，带 errorCode/errMsg |

`ClientVerify.checkHUID` 的判定顺序（`ClientVerify.java:28-73`）：`isLHU()`→放行；`isRefuse(HUID)`→拒；`HUName` 等于缓存名→放行；`HUID` 空→拒；SP 已配对列表含该 HUID→放行；缓存 `uuid` 相等→放行；否则若开了「配对校验」→ 0（等用户点），关闭 → 直接 `agree()` 记住并放行。

> **对台铃的含义**：`HUName` **不参与型号白名单校验**，只用于「同一个设备第二次连」的快速放行。想拒它就写进 `isRefuse` 列表。所以「我们的 HUName 不是 `TL-DASH-V2`」在官方逻辑里完全不影响握手，我们实现里对 HUName 的强校验反而是**额外风险**（见第 9 节）。

### 2.6 `0x10011` 回包：字段逐个说明（官方）

`ECP_C2P_CLIENT_INFO.reply(Map)`（`:962-1032`）+ `DisplayService` 注入（`:2113-2123`）：

| 键 | 类型 | 何时发 | 值 | 出处 |
| --- | --- | --- | --- | --- |
| `pxcVersion` | String | **恒发** | `"1.0.2"` | `:972` |
| `phoneUUID` | String | 恒发 | IMEI/自生成 | `:973` |
| `phoneBrand` | String | 恒发 | `Build.BRAND` | `:974` |
| `phoneModel` | String | 恒发 | `Build.MODEL` | `:975` |
| `phoneOsVersion` | **String（纯数字）** | 恒发 | `Integer.toString(SDK_INT)`，例 `"31"` | `:976` |
| `phoneOs` | String | 恒发 | `getFormatOsName()` | `:977` |
| `package` | String | 恒发 | 宿主包名 | `:978` |
| `versionCode` | int | 恒发 | 宿主编号 | `:979` |
| `token` | int | 恒发 | `PXCService.tokenTls`（`0x10000` 刚到时被清 0） | `:980`、`PXCService.java:226-227` |
| `pubkey` | String | 恒发 | RSA**1024** 公钥 `getEncoded()` 的 Base64（NO_WRAP） | `:981`、`RSAUtil.java:11-30` |
| `encryptedHUID` | String | 恒发 | 私钥 + `RSA/ECB/PKCS1Padding` 加密 HUID 再 Base64（type 1 填充） | `:982`、`RSAUtil.java:47-65` |
| `bluetoothName` | String | 恒发 | 蓝牙适配器名 | `:983` |
| `supportH264IFrame` | bool | **恒发** | `true` | `:984` |
| `supportFunction` | int | 仅当 `!isNewSupportFunction` | 仪表请求值（或默认值）经 `map` 覆盖后 | `:985-987` |
| `supportFunctionEx` | long | 仅当 `isNewSupportFunction` | `4290772959 & 仪表请求值`（`0xFFBFFFDF`） | `:988-990`、`:218-220` |
| `appVersionFingerPrint` | String | 恒发 | 版本指纹 | `:991` |
| `rvPath` | String | **`transport_type==0` 时必发** | `FileStorageManager.getRvDir()/pxc_rv.zip` 的绝对路径（x86 上为空串） | `:992-994` |
| `haveSysScreenInSetting` | bool | 仅当 SP `CLIENT_SETTINGS_SWITCH_ADB` ∈ {0,1} | `i==1` | `:995-998` |
| `speechEngineType` | int | **恒发**（`DisplayService` 注入） | `getSupportSpeechEngine()`，默认 **2** | `DisplayService.java:2114-2115` |
| `supportFunction`（覆盖） | int | 仅在「双屏空间」机型且非 VM 时 | 原值 `^ 4096` | `DisplayService.java:2100-2112` |

两条硬约束：

- **`supportFunction` 与 `supportFunctionEx` 互斥**：`isNewSupportFunction` 一个分支只走一条（`:985-990`）。同时发两个会让按 int/long 解析同一语义的固件行为不确定。
- `supportFunctionEx` 回的是**交集**而不是原值（`:989`，`getAllSupportFunctionEx() & mSupportFunctionEx`），其中 `getAllSupportFunctionEx()==4290772959==0xFFBFFFDF`（`:218-220`）。注意这张表里 **bit23（`ECP_SUPPORT_FUNCTION_MAX_FPS60=8388608`，`:110`）是 0**，即官方默认**不宣告 60 fps 能力**。

### 2.7 `0x10011` 发出之后，仪表期待什么？

把 `0x10010` 的成功链走完（`ECP_C2P_CLIENT_INFO.java:919-943` → `DisplayService.java:1990-2127`）：

```
process() → verifyFlavor() → verifyFlavorSuccess()
  → SplitMirrorManager.setClientSupportOverlay(...)
  → mPxcCallback.onReceiveClientInfo(this)     // DisplayService:1990-2127
      ├─ checkHUID 通过 → 存 flavor/version/HUID/appCheckLicense
      ├─ 需要时启 SOCKS5 / 语音引擎
      ├─ map.put("speechEngineType", 2)
      ├─ ecp_c2p_client_info.reply(map)          // ← 这里才真正写 0x10011
      └─ return 0
  → ChannelUtil.initLinkChannel / pXCForCar.setClientInfo / SpUtil.putSupportFunction
  → mPxcCallback.onReceiveClientInfoEnd(this)   // DisplayService:2130-2148 —— 只做 BLE/地图/导航/埋点
  → ConnectBridge.onConnectSuccess(...) / PXCService.setPXCType(1) / saveRemoteAddress
```

**结论（这是本次最要紧的一条）**：在 10922 这条连接上，官方发完 `0x10011` 之后**不再向仪表发送任何帧**，也不会去连/探测 10921、10920、10711、10710，更不会回发 `0x10011` 的补充包。`onReceiveClientInfoEnd`（`DisplayService.java:2130-2148`）与后续 `a(...)`（`:2677-2790`）全是 App/主题/语音/埋点逻辑，**零 socket 操作**。

因此「仪表下一步做什么」只能从手机侧反推：它应当**自己**发起对手机 10921/10920 的连接（或先发 `0x30000` 再连 10711/10710），首帧必须是 `0x10`/`0x30`（`MediaProjectServerCtrlExecuteThread.java:419-445`）。实车从没连过这些端口，说明仪表在读完 `0x10011` 就判定会话失败——问题在**回包内容**，不在我们少做了什么动作。

---

## 3. 帧格式细节

### 3.1 两种帧头

| 通道 | 头长 | 布局（小端） | 出处 |
| --- | --- | --- | --- |
| 10922（会话控制） | **16 B** | `cmdType int32 @0`、`length int32 @4`（**含 16 字节头**）、`magic int32 @8 = length ^ cmdType`、`@12..15` 官方恒 0 | `CmdBaseHead.java:41-113` |
| 10921/10711（媒体控制） | **8 B**（`ReqBase`） | `cmdType int16 @0`、`cmdLength int16 @2`（**仅载荷长度**）、`cmdToken int32 @4` | `Protocol.java:90-169` |
| 10920/10710（媒体数据） | 无头 | 每帧 `[int32 LE 长度][负载]` | `MediaProjectServerDataExecuteThread.java:431-432`、`:638-643` |

媒体控制帧的 `ReqBase` 只接受恰好 8 字节（`byteArrayToFields` 判 `length==8`，`Protocol.java:148-152`），扩展位在 `extData`：`extData[0]=displayId`、`extData[1]=ackFrames`（`:154-168`）。

### 3.2 校验与错误

`CmdBaseHead.read()`（`:65-97`）顺序：

1. 读满 16 字节，否则 `ReadHeadError(-2)`；`SocketTimeoutException` → `TimeOut(-1)`。
2. `(length ^ cmdType) != magic` → `MagicError(-3)`（**不做任何容错，直接判定坏帧**）。
3. `length - 16 < 0` → `LengthError(-5)`；随后读 `length-16` 字节，失败 `ReadDataError(-4)`。

`Status` 枚举（`Status.java:5-11`）：`OK(0) / TimeOut(-1) / ReadHeadError(-2) / MagicError(-3) / ReadDataError(-4) / LengthError(-5) / NullReference(-6)`。

任何非 `OK` 都会让 `ServerCtrlExecuteThread` **关掉整条连接**（`:44-124`），没有「跳过坏帧继续」的分支。我们把长度限制在 `16..65536`（`App/TailingProtocol.swift:31`），官方**没有上限**（只判 ≥16）。

### 3.3 identifier（第 12..15 字节）语义

- 写：`CmdBaseHead.write()` 从不写 `12..15`，缓冲区初始化为 0（`CmdBaseHead.java:99-113`）→ **官方所有回包该字段恒 0**。
- 读：官方**完全不读**这 4 个字节。
- 所以它是保留位/未实现字段。我们的实现在读的时候保存、在基础应答里回显（`App/TailingProtocol.swift:34-37`、`App/TailingConnection.swift:495-499`），在 `0x10011` 等回包里固定 0（`App/TailingConnection.swift:612-617`）。回显本身不违反协议，但**与官方行为不一致**，属于「多出来的自由度」。

### 3.4 错误码全表

| 名称 | 值 | 方向 | 用途 | 出处 |
| --- | --- | --- | --- | --- |
| `ECP_PXC_CMD_ERR` | `0x80000020`(-2147483616) | P2C | payload `{errorCode, errMsg}` | `ECP_PXC_CMD_ERR.java:5`、`:34-46` |
| `ECP_PXC_AUTH_FAIL` | `0x80000030`(-2147483600) | P2C | 鉴权/型号校验失败，随后断链 | `ECP_PXC_AUTH_FAIL.java`、`ServerCtrlExecuteThread.java:170-190` |
| `ECP_PXC_AUTH_PENDING` | `0x70000020`(1879048224) | P2C | 等用户在手机侧点同意 | `ECP_PXC_AUTH_PENDING.java` |
| `ECP_P2C_UNSUPPORT` | `0x80000010`(-2147483632) | P2C | 未注册命令的通用应答 | `ServerCtrlExecuteThread.java:235` |
| `ERROR_CONNECT_AUTH_FAIL` | `-2147483644` | 内部返回值 | 映射成 `0x80000030` | `ErrorCode.java:5-10` |
| `ERROR_AUTH_PENDING` | `-2147483643` | 内部返回值 | 映射成 `0x70000020` | 同上 |
| `ERROR_CONNECT_FLAVOR_NOT_MATCH` | `-2147483642` | 内部返回值 | 型号/flavor 不匹配 | 同上 |
| `ERROR_INVALID_JSON_FORMAT` | `-2147483647` | 内部返回值 | 进 `CMD_ERR` | 同上 |
| `ERROR_INVALID_LOCAL_JSON_FORMAT` | `-2147483646` | 内部 | — | 同上 |
| `ERROR_UNZIP_RV_EXCEPTION` | `-2147483645` | 内部 | RV 包解压失败 | 同上 |
| `RLY_ERROR_CMD` | `32513`(`0x7F01`) | 媒体 | 编解码器初始化失败 | `Protocol.java:23-74` |
| `RLY_UN_SUPPORT` | `32514`(`0x7F02`) | 媒体 | 未知命令，**不断链** | 同上 |
| `RLY_UN_AUTH` | `32515`(`0x7F03`) | 媒体 | 身份校验失败（`VerifyFail`/`NeedChangeOrientation`/`LOGOUT`） | 同上 |
| `RLY_INVALID_CFG` | `32516`(`0x7F04`) | 媒体 | 配置无效 | 同上 |
| `RLY_INIT_FAILED` | `32517`(`0x7F05`) | 媒体 | 启动镜像失败 | 同上 |
| `RLY_CANCEL` | `32518`(`0x7F06`) | 媒体 | 仪表取消 | 同上 |

心跳：`ECP_SEND_HEART_BEAT` = `ECP_RECEIVE_HEART_BEAT` = `0x70000000`（两个同名常量，发送/接收各一个）。

**注意**：10922 上收到**奇数** `cmdType`（即「应答型」命令）会被当成协议错误——`handleRequest` 直接 `return false` 并断链（`ServerCtrlExecuteThread.java:144-160`）。台铃仪表如果在握手期误发 `0x10011`/`0x10001` 过来，官方也是断链，所以我们「收到奇怪命令就断」不算 bug。

---

## 4. 媒体协商（10921/10711 控制通道）

分发入口 `MediaProjectServerCtrlExecuteThread.processRequest`（`MediaProjectServerCtrlExecuteThread.java:642-734`）。**回包一律 `cmd+1`，`token` 写 0**（`AbstractSocket.java:101-111`）。

| 请求 | 应答 | 应答 payload | 校验/前置 | 出处 |
| --- | --- | --- | --- | --- |
| `0x10`(16) 配置采集 | `0x11`(17) | `[int32 encoder][int16 w][int16 h]`（`supportExtendProtocol!=0` 时**多 1 字节**） | 读 `cmdLength` 字节解析 `ReqConfigCapture`；HUID 校验失败 → sleep 1000 + `0x7F03 "VerifyFail"`；读失败 → sleep 1000 + `0x7F01` | `:71-191`、`Protocol.java:171-369`、`:470-508` |
| `0x30`(48) 版本 | `0x31`(49) | `[int32 5002][int32 1]`（8 字节） | 无 | `:650-657` |
| `0x40`(64) 心跳 | `0x41`(65) | 空 | 无 | `:658-661` |
| `0x60`(96) 扩展配置 | `0x61`(97) | JSON：`{"supportFunction":<仪表原值>, "viewAreaConfig":{"state":0}}` | `viewAreaConfig` 为空则不放该键；`movieMode = (supportFunction & 1)==1` | `:193-223`、`Protocol.java:576-621` |
| `0x70`(112) 启动镜像 | `0x71`(113) 或 `0x7Fxx` | `0x71` 空体；`0x7F03` 空体/`"LOGOUT"`；`0x7F05` 空体 | 必须已有 `0x10` 的配置（否则只打日志不回）；`initCodec` 失败 → sleep 1000 + `0x7F01` | `:663-720` |
| `0x72`(114) 拉帧 | **数据通道**逐帧写 | `[len][payload]` | 只在 10920/10710 上有效 | `MediaProjectServerDataExecuteThread.java:78-90` |
| `0x110`(272) shell | `0x111`(273) | `"<值>\u0000"` | 仅支持 `getprop ro.build.version.release` / `ro.product.model`，其它回 `"OK"` | `:55-69` |
| `0x107C0`(67520) 开加密 | `0x107C1` | `[0,0,0,2]`（LE int = 33554432） | `setTLSEnable(true)`、`tokenTls = Random().nextInt(MAX_INT)`，**回包后整条 socket 切 TLS** | `ECP_C2P_ENABLE_ENC.java`、`ServerCtrlExecuteThread.java:206-209` |
| 其它 | `0x7F02` | 空 | **不断链** | `:671-676` |
| `0x20`(32) 屏幕事件 | **不回** | — | `eventType` 1/2/3/4 = UP/DOWN/MOVE/KEY | `:647-650`、`Protocol.java:515-557` |

### 4.1 `ReqConfigCapture` 二进制布局（0x10 的载荷）

固定 32 字节 + 可选尾串（`Protocol.java:171-369`，LE）：

| 偏移 | 字段 | 类型 | 说明 |
| --- | --- | --- | --- |
| 0 | `deviceWidth` | int16 | 仪表请求宽 |
| 2 | `deviceHeight` | int16 | 仪表请求高 |
| 4 | `wantFps` | int32 | 0 = 「按手机默认」 |
| 8 | `wantEncoder` | int32 | 0→按 1 处理；1=JPEG、2=H.264 硬编、4=MP4 |
| 12 | `supportCodec` | int32 | 位掩码 1/2/4，同上 |
| 16 | `minQuality` | int16 | JPEG 质量下限 |
| 18 | `maxQuality` | int16 | JPEG 质量上限 |
| 20 | `bitRate` | int32 | 0 → 3 000 000 |
| 24 | `capScreenMode` | byte | bit1=禁用多线程编码、bit2=强制软编、bit3=固定码率（`:202-273`） |
| 25 | `touchMode` | byte | — |
| 26 | `orientation` | byte | 3→竖屏默认、4→竖屏方形，二者都置 `screenShape=2` |
| 27 | `displayId` | byte | 虚拟屏编号 |
| 28 | `videoType` | byte | 0=JPEG、1=流、2=软编流 |
| 29 | `supportExtendProtocol` | byte | **≠0 时 `0x11` 回包要多 1 字节** |
| 30-31 | `reserved` | 2×byte | — |
| 32.. | `encryptedHUID` | UTF-8 文本 | 长度 >32 时存在，是 `0x10011` 里那个 Base64 串的**原样回显**；手机解密校验 |

### 4.2 `0x11` 应答

`RlyConfigCapture.toByteArray()`（`Protocol.java:470-508`）：`[int32 encoder][int16 captureWidth][int16 captureHeight]`，若请求里 `supportExtendProtocol != 0` **再追加 1 字节**，总长 8 或 9。`captureWidth/Height` 是 `(请求值 & -16)`，即向下取 16 的倍数（`MediaProjectServerCtrlExecuteThread.java:128-129`）。

### 4.3 `0x60` 扩展配置

请求是 JSON（`Protocol.java:576-621`）：`{"viewAreaConfig":{...}, "supportFunction":<int>}`，解析失败只 `printStackTrace`，`supportFunction` 取默认 0。应答（`:193-223`）：`supportFunction` **原值回显**，`viewAreaConfig` 存在时补 `{"state":0}`。`movieMode` 就是 `supportFunction & 1`（`MIRROR_SUPPORT_FUNCTION_MOVIE_MODE=1`）。

---

## 5. 视频/音频通路

### 5.1 编码器初始化

`initCodec`（`MediaProjectServerCtrlExecuteThread.java:807-863`）：

- `wantEncoder == 2` → 硬编：`HardCodec.initCodec("video/avc", w & -16, h & -16, bitRate, finalFps, useFixBitrate)`。
- 否则 → `JNICodec.initEncoder(kind, w & -16, h & -16, w & -16, 1, fps, bitRate(0→3_000_000), encodeThreadCnt, displayId)`；`encodeThreadCnt = disableMultiThreadEncode() ? 1 : 0`（`Protocol.java:465-467`），0 表示让编码器自己决定。
- 宽高**统一向下对齐到 16**。

### 5.2 帧率

`calculateFinalFps`（`:793-805`）：

1. 还没连上 → **25**。
2. `movieMode==false` 且仪表宣告 `supportMaxFps60` 且 `getOutFps()>0` → 用 `outFps`。
3. `wantFps==0` → `outFps>0 ? outFps : SpUtil.getEcFps().value()`。
4. 否则 `wantFps`。
5. `finalFps>=60` 且（PipeSDK 或 vivo）时把编码输入缓存压到 1 帧（`:860-863`）。

`ECP_SUPPORT_FUNCTION_MAX_FPS60 = 8388608`（bit23，`ECP_C2P_CLIENT_INFO.java:110`），而默认能力表 `0xFFBFFFDF` **不含**该位（`:218-220`）→ 默认不宣告 60 fps。

### 5.3 分辨率/DPI 映射

- `ReqConfigCapture.getDeviceVideoSize()`（`Protocol.java:364-369`）：OPPO 包名走 `useMaxCalculate()`（上限 1920×1080 与硬件编码器上限取交集），其它走 `useAreaCalculate(displayId, deviceWidth, deviceHeight, true)`——按**面积最接近**在候选尺寸里挑一个。
- 最终宽高再 `& -16` 落到编码器（`MediaProjectServerCtrlExecuteThread.java:810-830`）。
- DPI 不走这条链路：`dpi`/`enableDPI` 只在 `0x10010` 里被读（`ECP_C2P_CLIENT_INFO.java:700-760`），用于 App UI，不影响镜像尺寸。

### 5.4 JPEG 与 H.264 的选择条件

`MediaProjectServerDataExecuteThread.handleNextCmd`（`:78-90`）：

| 条件 | 分支 | 帧封包 |
| --- | --- | --- |
| `wantEncoder == 1`（或 `videoType==0`） | `replyJEPData` JPEG | `[int32 len][JPEG]`，无时间戳；无数据写 `int32 0`（`:431-432`、`:448`） |
| `useSoftEncode()` | `replyFFMPEGStreamData` | 同上，Annex-B |
| 否则（硬编 H.264） | `replyMediaCodecStreamData` | `[int32 len][H.264]`（`:638-643`） |

只有调试开关（`isEnableSaveH264ToFile`/`isEnableTestDelay`）才会写 `len+8` 并把 8 字节时间戳**追加在数据之后**（`:595-603`、`:608-619`）——线上协议没有时间戳字段。

### 5.5 逐帧拉取（0x72）

- 数据通道首帧必须是 `0x72`(114)，否则回 `0x7F02` 并退出（`:170-200`）。
- `extData[1] = ackFrames`：仪表已收到的帧数，手机据此补帧（`Protocol.java:154-168`、`:300-400`）。
- `wantFps == 0` 时是**严格请求-响应**：每收到一个 `0x72` 才发一帧（`:300-400`）。
- 超时（`-2`）且 `!isConnecting` → `onProjectionDataStopTransfer(TIMEOUT_DATA)`。

### 5.6 TLS 下的帧加密

`needTls(n)`（`:1030-1032`）= `n >= 4 && PXCService.tokenTls != 0`；`writeTLS`（`:1034-1056`）把**每帧前 4 字节长度**与 `tokenTls` 异或。注意：只有 `0x107C0` 之后 `tokenTls` 才非 0（`ECP_C2P_ENABLE_ENC.process()`）。

### 5.7 关键帧

`0x10011` 里 `supportH264IFrame` 恒 `true`（`ECP_C2P_CLIENT_INFO.java:984`），语义是「手机支持按需给关键帧」。**代码中未见**任何独立的关键帧请求命令；仪表侧只能通过 `0x72` 的 `ackFrames`（丢掉 N 帧后要求补发）间接影响编码输出。全库 grep `keyFrame|IFrame|syncFrame` 在数据线程/`HardCodec`/`MediaProjectService` 中均无命中。

### 5.8 音频

投屏链路里**没有音频数据通道**：`0x60000000` 系列（TTS/VR/Talkie/Music）走 10922 的控制通道做「播放状态与音量」语义，`MICRECORD_DATA=0x10060` 与 `0x200F0 START_CAR_MICRECORD` 是车机麦克风上行。台铃仪表上报 `supportFunction=12`（bit2、bit3）不含音频相关位，代码里也没有为它开音频通道的分支。

---

## 6. 新旧通道差异（10921/10920 vs 10711/10710）

**结论：完全共用同一套线程与命令集，只是端口、绑定地址、超时不同。**

证据：

| 项 | 新通道 | 旧通道 | 证据 |
| --- | --- | --- | --- |
| 监听 | `startListener(anyAddr, soTimeout)` → 10921 + 10920 | `startOldRVStartListen()` → 10711 + 10710 | `MediaProjectService.java:565-588` / `:590-610` |
| 控制线程 | `ServerCtrlThread` → `MediaProjectServerCtrlExecuteThread` | **同一个** `ServerCtrlThread` → **同一个** `MediaProjectServerCtrlExecuteThread` | `:915-971`（两者共用同一个内部类，仅 `ServerSocket` 实例不同） |
| 数据线程 | `ServerDataThread` → `MediaProjectServerDataExecuteThread` | **同一个** | `:984-1035` |
| 命令集 | 0x10/0x11、0x30/0x31、0x40/0x41、0x60/0x61、0x70/0x71、0x72、0x110、0x7F0x | 完全相同（分发逻辑里没有任何「端口/新老」分支） | `MediaProjectServerCtrlExecuteThread.java:642-734` |
| 绑定地址 | `anyAddr ? null : getLocalHost()` | 恒 `InetAddress.getLocalHost()` | `:565-588` / `:590-610` |
| `SO_TIMEOUT` | 由 `startListener` 参数决定（`startPXC` 传 null） | 恒 `null` | 同上 |
| 启动条件 | `startPXC()` 无条件 | 仪表发 `0x30000` 且 `version>=5000` | `PxcServiceCallBack.java:428-447` |
| 释放 | 随会话关闭 | `releaseOldRVListen()` 单独关 | `:612-643` |

所以「新老通道」在协议层是**同一条协议的两个端口组**，唯一实质区别是「谁先说话」：仪表想走旧通道必须先发 `0x30000` 触发监听，否则 10711 根本没在 listen。

---

## 7. 超时与重连规则

| 位置 | 值 | 行为 | 出处 |
| --- | --- | --- | --- |
| 10922 读 | `null`（`startPXC` 传 -1） | 永不因空闲超时；任何读错误即断链 | `DisplayService.java:3329-3343`、`ServerCtrlExecuteThread.java:44-124` |
| 10921 首帧 | `clientInfo==null` → **11000 ms** | 超时 → `Status.TimeOut` → 线程退出、连接关闭 | `MediaProjectServerCtrlExecuteThread.java:42-53`、`:447-600` |
| 10920 读 | **9000 ms**（USB 5000） | 超时且未在连接中 → 报 `TIMEOUT_DATA` 停止投屏 | `MediaProjectServerDataExecuteThread.java:63-70` |
| 10930（mDNS） | connect 3000 / read 3000 | 失败即 close，按发现周期重试 | `MDNSClient.java:323-400` |
| 反向控制（手机→仪表） | `socketTimeoutPeriodWifi*1000`，否则 USB 6000 / 其它 **9000** | 单命令超时 → 断链 | `ReverseServerCtrlExecuteConnection.java:40-56` |
| 单命令耗时 | **>2000 ms** | `ConnectBridge.onTimeout` + `dispatchConnectError(32768)` | `:146-149` |
| 心跳频率 | `mPXCNode.getHeartBeatFrequency()` 秒（默认由节点配置），队列空时发 `0x70000000` 并等应答 | 只在**反向控制连接**上 | `:58-169` |
| 媒体控制重连 | 旧线程未释放 → 最多等 `5×100 ms` | 超时仍占用则 `skip connect` + close | `MediaProjectService.java:915-971` |
| 启动失败 | `initCodec` 失败 → `sleep(1000)` 后回 `0x7F01` | 不重试 | `MediaProjectServerCtrlExecuteThread.java:700-720` |
| 校验失败 | `checkHUID != 1` → `sleep(1000)` 后回 `0x7F03` | 不重试 | `:71-191` |

**10922 上不主动发心跳**：`ServerCtrlExecuteThread` 只有读循环（`:44-124`），官方在仪表连进来的这条连接上**从不主动写**除「请求的应答」以外的任何帧。心跳是反方向（手机连仪表）那条连接的事。

---

## 8. 台铃专属逻辑

### 8.1 `flavor = 65572`

- SDK 内建的 flavor 常量表在 `ECP_C2P_CLIENT_INFO.java:20-74`，最大值到 `65585 CFMOTO_RIDESYNC`，**没有 65572**。
- 全库 grep `65572`：只命中 `org/spongycastle/crypto/digests/LongDigest.java:6`（SHA-512 常量数组），与 flavor 无关。
- 因此 `verifyFlavor()` 走 `checkFlavor(65572, "56701")` 的兜底分支（`:1033-1047`、`:1049-1100`）：字符串重载在「空/NaN」时直接 true；int 重载对 `null/MIN_VALUE/vivo/pipeSdk/motoTool` 直接 true，否则按**包名白名单**判（`PACKAGE_NAME_QR`、SDK+DEMO 包、服务器分支、debug 模式，最后才查 per-flavor 表）。
- **台铃不在任何白名单里** → 官方 App 对台铃仪表只有在「服务器判定通过 / debug 模式」时才握手成功。这说明台铃仪表本来就不是官方 SDK 的「已知型号」，我们不必也不该在本地复刻这张表。

### 8.2 `channel = "56701"` / `HUName = "YYTX01-P1AK"`

- `channel` 只用于三处特殊分支：`"13934"`（屏幕形态，`:672-683`）、`ChannelUtil.XF06`（语音引擎 2002→2001）、以及 `ProjectConfigUtil.requestConfig(channel, flavor)`（PipeSDK 分支）。`"56701"` 不在任何特判里。
- `HUName` 只用于 `ClientVerify.checkHUID` 与 SP 缓存名比较（`ClientVerify.java:40-52`），**不做型号白名单**。
- 全库 grep `TL-DASH`：**0 处命中**。grep `linux_no_package`：**0 处命中**。

### 8.3 `package_name = "linux_no_package"`

这是**仪表侧**（Linux 车机）自报的包名，用于 `checkFlavor` 的包名白名单判定（`ECP_C2P_CLIENT_INFO.java:1049-1100`）。SDK 里对它没有任何特判——它既不是 `PACKAGE_NAME_QR` 也不是 `PACKAGE_NAME_GWM` 之类，走了「默认拒绝/需服务端放行」的路径。这也解释了为什么官方 App 连台铃也要靠 `flavor==MIN_VALUE`、服务器判定或 debug 模式才放行。

### 8.4 `supportFunction = 12`

`12 = 0b1100`（bit2、bit3）。SDK 里与 `supportFunction` 相关的位很多（`ECP_C2P_CLIENT_INFO.java:222-360` 一批 `supportXxx(int)` 工具方法），但台铃只置了这两位，`0x60` 的 `movieMode = supportFunction & 1 = 0` —— 即**电影模式关闭**。

### 8.5 台铃对自己代码的调用

`com/tailg/run/intelligence/model/home/fragment/ControlFragment.java:8170` 只有一句 `EcManager.getManager().startPXC()`，之后台铃自有代码不再干预协议（不额外发命令、不改端口）。也就是说**投屏协议完全由 SDK 决定**，台铃没有私有扩展。

---

## 9. 对照表（APK 行为 / 我们的实现 / 差异 / 风险）

风险等级：🔴 高（可能直接导致 RST 或通道不可用）、🟠 中（协议语义偏差）、🟢 低（仅日志/风格）。

### 9.1 握手与回包

| # | APK 行为 | 我们的实现 | 差异 | 风险 |
| --- | --- | --- | --- | --- |
| 1 | `0x10011` 恒发 `speechEngineType`（`DisplayService.java:2114-2115`，值默认 2） | 回包字段表里没有这个键（`App/TailingConnection.swift:534-557`） | **官方每一条 Wi-Fi 回包都有，我们缺**。若车机用 `getInt` 强解析，会抛异常并断链 | 🔴 |
| 2 | `transport_type==0` 时恒发 `rvPath`（`ECP_C2P_CLIENT_INFO.java:992-994`） | 解析 `0x10010` 时根本没读 `transport_type`，也不发 `rvPath`（`App/TailingConnection.swift:508-568`） | 缺一个「Wi-Fi 场景官方必发」的键 | 🔴 |
| 3 | `haveSysScreenInSetting` 在 SP 为 0/1 时发（`:995-998`） | 不发 | 条件字段，官方也常常不发 | 🟢 |
| 4 | `phoneOsVersion` 是**纯数字字符串**（`:976`，如 `"31"`） | 发 `phone.systemVersion`，形如 `"17.4"`（`App/TailingConnection.swift:537`） | 若车机按数字解析 → 失败 | 🟠 |
| 5 | `phoneOs` = `getFormatOsName()`（"Android"/"Android 12"） | `"iOS"` | 语义等价，风险低 | 🟢 |
| 6 | `supportFunction` / `supportFunctionEx` **二选一**（`:985-990`） | 二选一，且 `Ex` 取交集 `0xFFBFFFDF & 请求值`（`App/TailingConnection.swift:545-557`） | ✅ 已对齐（注释里记录了 1.0.9 同时发导致 RST 的历史） | ✅ |
| 7 | `supportFunctionEx` 是 **long** | Swift 里 `UInt64` 写进 JSON（`:551-552`） | JSON 数字，OK；注意不要出现负值 | 🟢 |
| 8 | `token` = `tokenTls`，`0x10000` 刚到时被清 0（`PXCService.java:226-227`） | 固定 `0`（`App/TailingConnection.swift:538`） | ✅ 等价 | ✅ |
| 9 | `pubkey` = RSA**1024** `getEncoded()` 的 Base64（`RSAUtil.java:11-30`） | RSA1024 + 手拼 X.509 SPKI（`App/TailingIdentity.swift:54-75`） | ✅ 位数与结构一致 | ✅ |
| 10 | `encryptedHUID` = 私钥 + PKCS#1 **type 1** 填充（`RSAUtil.java:47-65`） | `.rsaSignatureDigestPKCS1v15Raw`（`App/TailingIdentity.swift:85-95`），且每次自检 `pow` 回读 | ✅ 已对齐（注释记录了 1.0.10 用 type 2 的方向错误） | ✅ |
| 11 | `0x10001` 是 16 字节纯头，`12..15` = 0（`CmdBaseHead.java:99-113`） | 回显 `request.identifier`（`App/TailingConnection.swift:495-499`） | 多回显了保留字段；`0x10011` 那侧反而固定 0（`:612-617`），自相矛盾 | 🟠 |
| 12 | 收到 `0x10000` 先校验 `isSameClientAddress`，不同就丢（`PXCService.java:218-289`） | 只记对端地址，不校验（`App/TailingSocket.swift:80-106`、`App/TailingConnection.swift:418-456`） | 更宽松，不是故障源 | 🟢 |
| 13 | 10922 上**从不主动发**任何帧（`ServerCtrlExecuteThread.java:44-124`）；心跳只属于反向控制连接（`ReverseServerCtrlExecuteConnection.java:58-169`） | 收到 `0x20000` 后在同一条 socket 上先补 5 条状态帧，再每 **2 s** 发 `0x70000000`（`App/TailingConnection.swift:599-608`、`641-660`） | 官方 `0x20000` 是交给 `PXCForCar.startNewReverseControlThread` 接管（`PXCService.java:248-275`），语义不同；心跳本身不参与 `0x10011` 之后的判定，不是本次 RST 的原因 | 🟠 |
| 14 | 未注册命令 → 回 `0x80000010` 且**保持**连接（`:235`） | 记日志后 `continue`，不回包（`:590-596`） | 车机若在等应答会一直等到超时 | 🟠 |
| 15 | `0x107C0` → 回 `0x107C1` + `[0,0,0,2]`，随后整条 socket 切 TLS（`ECP_C2P_ENABLE_ENC.java`、`ServerCtrlExecuteThread.java:206-209`） | 只记日志、不回包、不切（`App/TailingConnection.swift:569-573`） | **仪表发过这条命令就会一直等应答**，最终超时断链 | 🔴 |
| 16 | 收到奇数 `cmdType` 直接断链（`:144-160`） | 未知命令按 default 处理，不断链 | 我们更宽容 | 🟢 |
| 17 | `0x10010` 解析不校验 `HUName` 是否为空，也不比对型号（`ECP_C2P_CLIENT_INFO.java:641-888`、`ClientVerify.java:28-73`） | `HUName`/`HUID` 缺一就抛异常并**关会话**（`App/TailingConnection.swift:510-513`），非 `TL-DASH-V2` 在 strict 模式下也抛（`:517-523`） | 我们比官方严；二代台铃报的不是 `TL-DASH-V2`，strict 模式会自杀 | 🟠 |
| 18 | 帧长无上限，只判 ≥16（`CmdBaseHead.java:65-97`） | 限 `16...65536`（`App/TailingProtocol.swift:31`） | 仪表 1496 B 远小于上限 | 🟢 |

### 9.2 媒体通道

| # | APK 行为 | 我们的实现 | 差异 | 风险 |
| --- | --- | --- | --- | --- |
| 19 | 10921/10920 在 10922 listen 成功后**立即**起（`PXCService.java:110-114`） | 全部端口先 listen 再 accept（`App/TailingConnection.swift:132-151`） | 我们更稳 | ✅ |
| 20 | 首帧必须是 `0x10` 或 `0x30`，否则 close（`MediaProjectServerCtrlExecuteThread.java:419-445`） | 任何 8 字节头都进 switch，未知回 `0x7F02`（`App/TailingConnection.swift:662-737`） | 更宽容 | 🟢 |
| 21 | `0x11` 长度取决于请求的 `supportExtendProtocol`（8 或 9 字节，`Protocol.java:470-508`） | 恒 8 字节（`App/TailingConnection.swift:699-701`） | 仪表设了该位 → 我们少 1 字节 → **后续帧全部错位** | 🔴 |
| 22 | `captureWidth/Height = 请求值 & -16`（`:128-129`） | 固定回 `profile.width/height`（480×272，`:700-701`） | 尺寸不一致时车机可能拒绝画面 | 🟠 |
| 23 | `encoder` 按 `wantEncoder` 镜像（1/2/4） | 台铃恒 1(JPEG)、极核恒 2(H.264)（`:699`） | 仪表若只想 H.264 会拿到自己没要的格式 | 🟠 |
| 24 | `0x10` 校验失败回 `0x7F03` + `"VerifyFail"`，**不断链**（`:71-191`） | 不符就抛异常 → `fail()` → **关整条会话**（`:695-697`） | 我们用断链代替错误码 | 🟠 |
| 25 | `0x30` → `0x31` + 8 字节 `{5002,1}`（`:650-657`） | 同（`:713-714`，两个 `UInt32`） | ✅ | ✅ |
| 26 | `0x40` → `0x41` 空体（`:658-661`） | 同（`:712`） | ✅ | ✅ |
| 27 | `0x60` → `0x61` JSON，`supportFunction` 原值 + `viewAreaConfig.state=0`（`:193-223`） | 同（`:715-732`） | ✅ | ✅ |
| 28 | `0x70` → `0x71` 空体，且要求已有 `0x10`（`:663-720`） | 同（`:705-711`） | ✅ | ✅ |
| 29 | `0x72` 才发帧；`wantFps==0` 时严格一问一答（`MediaProjectServerDataExecuteThread.java:300-400`） | 工具侧 `Tools/TailingMediaSmoke.swift` 有模拟，但**没有独立的数据通道实现**在 `TailingConnection` 里 | 我们只做控制面，数据面靠调用方（CarPlay 管线） | 🟠 |
| 30 | 帧封包 `[int32 len][payload]`（JPEG 与 H.264 相同） | `jpeg()` 一致（`App/TailingProtocol.swift:58-66`）；`h264()` 多一个「可选 8 字节前缀在长度**之前**」（`:68-77`） | 官方只把 8 字节时间戳追加在**数据之后**且仅调试用（`:595-603`） | 🟠 |
| 31 | `tokenTls != 0` 时每帧前 4 字节与 token 异或（`:1030-1056`） | 无 TLS 分支（`0x107c0` 被忽略） | 见 #15 | 🔴 |
| 32 | 媒体控制帧 `token` 恒写 0（`AbstractSocket.java:101-111`） | 回包回显 `request.token`（`App/TailingConnection.swift:738`） | 与官方不一致，风险低 | 🟢 |
| 33 | `listen` backlog **1000**（`MediaProjectService.java:572`） | backlog **4**（`App/TailingSocket.swift:53`） | 车机连一次够用；但配合「同时 5 个端口 listen」时 4 很小 | 🟠 |
| 34 | 媒体连接设 `SO_KEEPALIVE`（`:915-971`） | 未设（`App/TailingSocket.swift:204-212`） | 半开连接不会被系统清理 | 🟢 |

### 9.3 超时与日志

| # | APK 行为 | 我们的实现 | 差异 | 风险 |
| --- | --- | --- | --- | --- |
| 35 | 10922 无空闲超时（`SoTimeout=null`） | 空闲不限，半帧 10 s（`App/TailingSocket.swift:108-134`） | ✅ 语义接近，且多了半帧保护 | ✅ |
| 36 | 10921 首帧 11 s（`MediaProjectServerCtrlExecuteThread.java:42-53`） | 10 s 半帧（同一套） | 差 1 s | 🟢 |
| 37 | 10920 9 s（`MediaProjectServerDataExecuteThread.java:63-70`） | 10 s | 无实质差异 | 🟢 |
| 38 | mDNS connect/read 各 3 s，收完立即 close，失败按周期重试（`MDNSClient.java:323-400`） | `announce()` 每 6 s 重试，60 s 总超时（`App/TailingConnection.swift:116-126`、`:161-200`） | 重试间隔比官方长，但官方也是靠发现周期 | 🟢 |
| 39 | 单命令 >2000 ms → `onTimeout` + 错误码 32768（`ReverseServerCtrlExecuteConnection.java:146-149`） | 无此统计 | 仅诊断能力差异 | 🟢 |
| 40 | 日志 `receive <<<… rst 0x<hex> cost <ms>`（`ServerCtrlExecuteThread.java:44-124`） | 逐帧记录命令+字节数，`0x10010/0x10011` 全文入日志（`App/TailingConnection.swift:488-491`、`:560-567`） | 我们日志更细，**已记录「收到 0x10011 之后断开」的专门错误**（`:477-484`） | ✅ |

---

## 10. 下一版修改建议（按「最可能解决 RST」排序）

> 前提：实车日志已经证明「10922 收到 `0x10000` → 我们回 `0x10001` → 收到 `0x10010`(1496B) → 我们回 `0x10011`(753B) → 立刻 RST(errno 54)」。官方在 `0x10011` 之后没有任何后续动作（§2.7），所以**能改变结果的只有 `0x10011` 的内容与 `0x10001` 的帧头**。

1. **在 `TailingConnection.control(_:)` 的 `0x10010` 分支里补 `speechEngineType`**（`App/TailingConnection.swift:534-544` 的 `fields` 字典）。
   官方无条件注入，值取 `2`（`DisplayService.java:2114-2115`；默认值见 `ECP_C2P_CLIENT_INFO.java:566-594`）。这是官方每一条 Wi-Fi 回包都有的键里，我们唯一完全缺失的一个。
2. **补 `rvPath`，并先解析 `transport_type`**（同函数 `:508-568`）。
   从 `0x10010` JSON 里读 `transport_type`（缺省按 0，官方 `Constant.SP_TRANSPORT_TYPE` 默认 0）；`==0` 时在 `fields` 里加 `rvPath`，值用空字符串或 `"pxc_rv.zip"`（官方是绝对路径，见 `ECP_C2P_CLIENT_INFO.java:992-994` + `getRvZipFilePath`，x86 上官方自己就发空串）。
3. **让 `phoneOsVersion` 变成纯数字**（`:537`）。
   官方是 `Integer.toString(SDK_INT)`（`ECP_C2P_CLIENT_INFO.java:976`）。iOS 侧可发一个纯数字的等价物（例如 `"17"` 取主版本），或退一步发 `"31"` 这类「伪装成 Android SDK 级别」的值；同时在日志里标注这是兼容性取值，而不是真实系统版本。
4. **基础应答统一 `identifier = 0`**（`:495-499`，改为与 `replyControl` 一致）。
   官方 `CmdBaseHead.write()` 从不写 `12..15`（`CmdBaseHead.java:99-113`），回显没有协议依据，且与我们在 `0x10011` 上的行为自相矛盾。
5. **`0x107C0` 改为按官方处理**（`:569-573` 的 `case 0x107c0`）。
   至少回 `0x107C1` + 4 字节 `00 00 00 02`（`ECP_C2P_ENABLE_ENC.java`）；若暂不实现 TLS，就明确「回包但不切 TLS」并在日志里写明，避免车机在等应答时超时。**注意**：这条若在实车日志里从未出现，优先级低于 1–3。
6. **把 `0x20000` 的心跳从「复用仪表连进来的 socket」改成独立通道**（`:599-608`、`:641-660`）。
   官方收到 `0x20000` 是交给 `PXCForCar.startNewReverseControlThread(socket)` 接管（`PXCService.java:248-275`），心跳在反向控制连接上按 `HeartBeatFrequency` 发（`ReverseServerCtrlExecuteConnection.java:58-169`）。这条**不是本次 RST 的原因**（心跳在 `0x20000` 之后才启动，而 RST 发生在 `0x10011` 之后），但会让后续会话语义偏离官方。
7. **未知命令回 `0x80000010`**（`:590-596` 的 `default` 分支）。
   官方对未注册命令一定应答 `ECP_P2C_UNSUPPORT` 且不断链（`:235`），我们静默会让车机等待。保持连接语义不变，只是多写一帧。
8. **放宽 `HUName` 强校验**（`:510-523`）。
   官方不比对型号（`ClientVerify.java:28-73`），我们应在非 strict 模式（默认）下完全不因 `HUName` 断链；`strictNegotiation` 已存在，保持它作为唯一开关即可。
9. **媒体通道：`0x11` 按 `supportExtendProtocol` 决定长度**（`:699-701`）。
   从请求载荷偏移 **29** 取该字节（`Protocol.java:171-369`），非 0 时追加 1 字节 0。同时把 `captureWidth/Height` 改成 `请求值 & -16`（`:128-129`），`encoder` 按 `wantEncoder` 镜像，而不是按平台写死。
10. **媒体通道失败回错误码而不是断链**（`:695-697`）。
    身份回显不符时回 `0x7F03` + `"VerifyFail"`，让车机有机会重试（`MediaProjectServerCtrlExecuteThread.java:110-160`）；配置未完成时回 `0x7F01` 而不是抛 `protocolFailure`。
11. **把 `listen` backlog 提到 128 以上**（`App/TailingSocket.swift:53`），并给媒体连接加 `SO_KEEPALIVE`（对齐 `MediaProjectService.java:915-971`）。
12. **诊断增强**：在 `0x10011` 写完后记录时间戳，并在 `readControl` 抛错时记录「距上一次写包 N ms」，这样能区分「车机读完立刻 RST（内容问题）」与「车机等到超时才 RST（缺应答问题）」。当前日志（`App/TailingConnection.swift:477-484`）已有结论性文案，但缺时间差。

> 若第 1–3 条上线后仍 RST，下一批优先怀疑：车机对 `pubkey` 的 ASN.1 解析（我们手拼 SPKI，`App/TailingIdentity.swift:65-75`，与 Java `getEncoded()` 字节级同构但未在车机上验证过）、以及车机对 `supportFunction` 的具体位语义（`12` 的 bit2/bit3 在 SDK 里对应哪两个能力，见 `ECP_C2P_CLIENT_INFO.java:222-360` 的 `supportXxx(int)` 系列）。
