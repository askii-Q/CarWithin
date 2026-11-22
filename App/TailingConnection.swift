// Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingConnection.swift
struct TailingDisplayProfile {
    let width: Int
    let height: Int
    let isZeeho: Bool
    static let tailing43 = TailingDisplayProfile(width: 480, height: 272, isZeeho: false)
    static let zeeho62 = TailingDisplayProfile(width: 1024, height: 480, isZeeho: true)
}

import Foundation

struct TailingPhoneInfo {
    let package: String
    let versionCode: Int
    let model: String
    let systemVersion: String
    let width: Int
    let height: Int
    let rotation: Int

    func display(mode: Int) -> [String: Any] {
        ["displayRotation": mode == 2 ? 0 : rotation,
         "width": mode == 2 ? min(width, height) : width,
         "height": mode == 2 ? max(width, height) : height,
         "enableAccessibility": false, "enableAOAHid": false, "mode": mode]
    }
}

struct TailingPorts {
    let control: UInt16
    let auxiliary: UInt16
    let video: UInt16
    /// 未验证型号可能把投屏请求端口放在别处，协商期允许改写。
    var announcement: UInt16
    static let ios = TailingPorts(control: 10922, auxiliary: 10711, video: 10710, announcement: 10930)
    /// 首次请求被拒绝时用于诊断与回退的探测范围。
    static let announcementProbeRange: ClosedRange<UInt16> = 10_700...10_999
}

/// 台铃 JPEG 和极核 H.264 共用的 PXC 投屏会话。
final class TailingConnection: @unchecked Sendable {
    private let localIP: String
    private let targetIP: String
    private let profile: TailingDisplayProfile
    private let phone: TailingPhoneInfo
    private var ports: TailingPorts
    private let negotiationTimeout: TimeInterval
    private let announcementRetryInterval: TimeInterval
    private let strictNegotiation: Bool
    private var announcementAttempts = 0
    private var probedAnnouncementPorts = false
    private let identityProvider: () throws -> TailingIdentity
    private let log: (String) -> Void
    private let condition = NSCondition()
    private var resources: [TailingSocket] = []
    private var timers: [DispatchSourceTimer] = []
    private var closed = false
    private var closeComplete = false
    private var failure: Error?
    private var identity: TailingIdentity?
    private var huid: String?
    private var signedHUID: Data?
    private var video: TailingSocket?
    private var reverseControl: TailingSocket?
    private var sentH264Prefix = false
    private var mediaStarted = false
    private var configured = false
    private var isZeeho: Bool { profile.isZeeho }
    private var dashboard: String { profile.isZeeho ? "极核" : "台铃" }

    init(localIP: String, targetIP: String, profile: TailingDisplayProfile, phone: TailingPhoneInfo,
         ports: TailingPorts = .ios, identityProvider: @escaping () throws -> TailingIdentity = TailingIdentity.load,
         negotiationTimeout: TimeInterval = 60, announcementRetryInterval: TimeInterval = 6,
         strictNegotiation: Bool = UserDefaults.standard.bool(forKey: "tailingStrictNegotiation"),
         log: @escaping (String) -> Void) {
        self.localIP = localIP; self.targetIP = targetIP; self.profile = profile; self.phone = phone
        self.ports = ports; self.identityProvider = identityProvider; self.log = log
        self.negotiationTimeout = negotiationTimeout
        self.announcementRetryInterval = announcementRetryInterval
        self.strictNegotiation = strictNegotiation
    }

    func start() throws {
        let loaded = try identityProvider()
        condition.lock(); identity = loaded; condition.unlock()
        // 先全部监听，再请求仪表反向连接；不使用所有网卡的通配地址。
        var listeners: [(UInt16, TailingSocket)] = []
        for port in [ports.control, ports.auxiliary, ports.video] {
            let server = try tracked(TailingSocket.create())
            try server.listen(localIP: localIP, port: port)
            listeners.append((port, server))
        }
        for (port, server) in listeners {
            DispatchQueue.global(qos: .userInitiated).async { [self] in accept(server, port: port) }
        }
        log("\(dashboard) TCP 已监听 \(localIP):\(ports.control)/\(ports.auxiliary)/\(ports.video)，正在协商")
        // 仪表可能晚于本机进入投屏状态，也可能正被官方 App 占用而短暂拒绝连接。
        // 协商窗口内持续重发投屏请求，任意一次成功即可，而不是一次失败就结束会话。
        let deadline = Date().addingTimeInterval(negotiationTimeout)
        var nextAttempt = Date.distantPast
        var lastProgressLog = Date()
        while true {
            condition.lock()
            let stopped = closed
            let pendingFailure = failure
            let ready = isReadyLocked()
            condition.unlock()
            // 先报真正的失败原因：fail() 会先记录 failure 再关闭会话。
            if let pendingFailure { throw pendingFailure }
            if stopped { throw TailingError.closed }
            if ready { break }
            if Date() >= nextAttempt {
                nextAttempt = Date().addingTimeInterval(announcementRetryInterval)
                do { try announce() } catch { noteAnnouncementFailure(error) }
            }
            if Date() >= deadline {
                if !probedAnnouncementPorts {
                    probedAnnouncementPorts = true
                    probeAnnouncementPorts()
                }
                condition.lock()
                let progress = progressLocked()
                condition.unlock()
                throw TailingError.timeout("等待仪表回连超时（\(Int(negotiationTimeout)) 秒）：\(progress)。请先退出仪表上的官方投屏，再重新开启投屏，并保持本页不动")
            }
            condition.lock()
            _ = condition.wait(until: min(deadline, nextAttempt))
            let progress = progressLocked()
            condition.unlock()
            if Date().timeIntervalSince(lastProgressLog) >= 10 {
                lastProgressLog = Date()
                log("\(dashboard) 仍在等待仪表回连：\(progress)")
            }
        }
        log("\(dashboard) 媒体协商完成，等待仪表逐帧请求")
    }

    /// 向仪表请求一次 iOS 投屏；失败由调用方记录并重试。
    private func announce() throws {
        let socket = try tracked(TailingSocket.create())
        defer { socket.close() }
        do {
            try socket.connect(localIP: localIP, remoteIP: targetIP, port: ports.announcement)
        } catch {
            throw TailingError.channel("连接仪表投屏端口 TCP\(ports.announcement)", error)
        }
        try socket.write(TailingProtocol.control(0x70000010, payload: TailingProtocol.json([
            "phoneType": "iOS", "packageName": phone.package
        ])))
        let reply = try TailingProtocol.readControl { try socket.readExactly($0, timeout: 3) }
        guard reply.command == 0x70000011 else {
            throw TailingError.protocolFailure(String(format: "仪表回应 0x%08x，预期 0x70000011", reply.command))
        }
        announcementAttempts += 1
        var accepted = false
        if let object = try? TailingProtocol.object(reply.payload), let status = object["status"] as? Bool {
            accepted = status
        }
        if accepted {
            log("\(dashboard) 仪表已接受 iOS 投屏请求（第 \(announcementAttempts) 次），等待其回连 \(localIP)")
        } else {
            log("\(dashboard) 仪表暂未接受 iOS 投屏请求，\(Int(announcementRetryInterval)) 秒后重试")
        }
    }

    private func noteAnnouncementFailure(_ error: Error) {
        var hint = ""
        if let tailing = error as? TailingError, case .channel = tailing {
            hint = "（连接被拒绝通常是仪表正被官方 App 占用）"
        }
        log("\(dashboard) 投屏请求失败：\(error.localizedDescription)\(hint)，会继续重试")
        // 第一次被拒绝时探测仪表真正开放的端口，定位二代仪表改端口的情况。
        guard !probedAnnouncementPorts else { return }
        probedAnnouncementPorts = true
        probeAnnouncementPorts()
    }

    /// 只在首次请求失败后运行一次：记录仪表开放端口，并换端口尝试同样的请求。
    private func probeAnnouncementPorts() {
        let range = TailingPorts.announcementProbeRange
        let reserved: Set<UInt16> = [ports.control, ports.auxiliary, ports.video]
        let candidates = range.filter { !reserved.contains($0) }
        var found: [UInt16] = []
        let foundLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let port = candidates[index]
            guard let socket = try? TailingSocket.create() else { return }
            defer { socket.close() }
            guard (try? socket.connect(localIP: localIP, remoteIP: targetIP, port: port, timeout: 0.12)) != nil else { return }
            foundLock.lock(); found.append(port); foundLock.unlock()
        }
        let openPorts = found.sorted()
        guard !openPorts.isEmpty else {
            log("\(dashboard) 端口探测 \(range.lowerBound)–\(range.upperBound)：仪表没有开放任何 TCP 端口")
            return
        }
        log("\(dashboard) 端口探测 \(range.lowerBound)–\(range.upperBound)：开放 \(openPorts.map { String($0) }.joined(separator: ", "))")
        guard !openPorts.contains(ports.announcement) else { return }
        for port in openPorts where !reserved.contains(port) {
            guard let socket = try? TailingSocket.create() else { continue }
            defer { socket.close() }
            guard (try? socket.connect(localIP: localIP, remoteIP: targetIP, port: port, timeout: 0.5)) != nil,
                  (try? socket.write(TailingProtocol.control(0x70000010, payload: TailingProtocol.json([
                      "phoneType": "iOS", "packageName": phone.package
                  ])))) != nil,
                  let reply = try? TailingProtocol.readControl({ try socket.readExactly($0, timeout: 0.8) }),
                  reply.command == 0x70000011 else { continue }
            ports.announcement = port
            log("\(dashboard) 改用投屏请求端口 \(port)（探测确认可协商）")
            return
        }
    }

    private func isReadyLocked() -> Bool {
        signedHUID != nil && video != nil && mediaStarted && (!isZeeho || reverseControl != nil)
    }

    private func progressLocked() -> String {
        var parts: [String] = []
        parts.append(signedHUID == nil ? "会话控制未回连" : "会话控制已回连")
        parts.append(video == nil ? "视频通道未回连" : "视频通道已回连")
        parts.append(mediaStarted ? "媒体已启动" : "媒体未启动")
        if isZeeho { parts.append(reverseControl == nil ? "镜像通道未就绪" : "镜像通道已就绪") }
        return parts.joined(separator: "、")
    }

    @discardableResult
    func sendJPEG(_ jpeg: Data) throws -> (pullWait: TimeInterval, writeTime: TimeInterval) {
        let (socket, pullWait) = try readFrameRequest()
        let packet = try TailingProtocol.jpeg(jpeg)
        let writeStarted = ProcessInfo.processInfo.systemUptime
        do {
            try socket.write(packet)
        } catch {
            throw terminalError(or: TailingError.channel("发送 JPEG", error))
        }
        return (pullWait, ProcessInfo.processInfo.systemUptime - writeStarted)
    }

    func waitForH264Request() throws {
        _ = try readFrameRequest()
    }

    // 视频请求与发送由同一个会话任务顺序执行。
    func sendH264(_ accessUnit: Data) throws {
        let socket = try videoSocket()
        let packet = try TailingProtocol.h264(accessUnit, includePrefix: !sentH264Prefix)
        do {
            try socket.write(packet)
            sentH264Prefix = true
        } catch {
            throw terminalError(or: TailingError.channel("发送 H.264", error))
        }
    }

    private func videoSocket() throws -> TailingSocket {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
        guard let video else { throw TailingError.closed }
        return video
    }

    private func readFrameRequest() throws -> (TailingSocket, TimeInterval) {
        let socket = try videoSocket()
        let pullStarted = ProcessInfo.processInfo.systemUptime
        let request: TailingProtocol.Auxiliary
        do {
            request = try TailingProtocol.readAuxiliary { try socket.readExactly($0, timeout: 5) }
        } catch {
            throw terminalError(or: TailingError.channel("等待视频拉帧请求", error))
        }
        let pullWait = ProcessInfo.processInfo.systemUptime - pullStarted
        guard request.command == 0x72, request.payload.isEmpty else {
            throw TailingError.protocolFailure(String(format: "视频通道收到 0x%04x（%d 字节），预期空载荷 0x72",
                                                     Int(request.command), request.payload.count))
        }
        return (socket, pullWait)
    }

    func checkHealth() throws {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
    }

    private func terminalError(or fallback: Error) -> Error {
        do { try checkHealth() } catch { return error }
        return fallback
    }

    func close() {
        condition.lock()
        if closed {
            while !closeComplete { condition.wait() }
            condition.unlock()
            return
        }
        closed = true
        let sockets = resources
        let pendingTimers = timers
        let reverse = failure == nil ? reverseControl : nil
        resources.removeAll(); timers.removeAll()
        condition.broadcast()
        condition.unlock()
        pendingTimers.forEach { $0.cancel() }
        if let reverse {
            do {
                try sendMirrorControl(reverse, start: false, identifier: UInt32.max, timeout: 0.25)
                log("极核已发送停止投屏通知")
            } catch {
                log("极核停止通知发送失败：\(error.localizedDescription)")
            }
        }
        sockets.forEach { $0.close() }
        condition.lock()
        closeComplete = true
        condition.broadcast()
        condition.unlock()
    }

    private func tracked(_ socket: TailingSocket) throws -> TailingSocket {
        condition.lock()
        defer { condition.unlock() }
        if closed { socket.close(); throw TailingError.closed }
        resources.append(socket)
        return socket
    }

    private func accept(_ server: TailingSocket, port: UInt16) {
        do {
            while true {
                let socket = try tracked(server.accept(remoteIP: targetIP))
                if isZeeho { log("极核 TCP\(port) 已回连") }
                if port == ports.video {
                    condition.lock()
                    if video == nil && !closed { video = socket; condition.broadcast() }
                    else { socket.close() }
                    condition.unlock()
                } else {
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        do {
                            if port == ports.auxiliary { try auxiliary(socket) }
                            else { try control(socket) }
                        } catch {
                            let channel = port == ports.auxiliary ? "媒体控制 TCP\(port)" : "会话控制 TCP\(port)"
                            fail(TailingError.channel(channel, error))
                        }
                    }
                }
            }
        } catch { fail(error) }
    }

    private func control(_ socket: TailingSocket) throws {
        var reverseStarted = false
        var reportedUnsupported = false
        while true {
            // 连接在两条完整消息之间可以静默，收到半条消息后仍限制读取时间。
            var readingHeader = true
            let request = try TailingProtocol.readControl { count in
                defer { readingHeader = false }
                return try socket.readExactly(count, waitForFirstByte: readingHeader)
            }
            var payload = Data()
            switch request.command {
            case 0x10000, 0x20000, 0x10740, 0x10040, 0x70000000:
                break
            case 0x10690 where isZeeho, 0x10780 where isZeeho:
                // 极核上报 FTP 速率和运行日志，投屏会话只确认收到。
                break
            case 0x103e0 where isZeeho:
                // 0x103e1 是收件确认。序列号校验结果使用独立命令。
                log("极核收到序列号校验请求，等待仪表继续媒体协商")
            case 0x10010:
                let object = try TailingProtocol.object(request.payload)
                guard let name = object["HUName"] as? String, !name.isEmpty, name.utf8.count <= 128,
                      let huid = object["HUID"] as? String, !huid.isEmpty else {
                    throw TailingError.protocolFailure("仪表设备资料不完整")
                }
                if isZeeho && name == "TL-DASH-V2" {
                    throw TailingError.protocolFailure("目标报告台铃 TL-DASH-V2，请检查仪表配置")
                }
                if !isZeeho && name != "TL-DASH-V2" {
                    // 二代仪表会报告不同 HUName；继续协商并记录，便于后续适配。
                    log("\(dashboard) 仪表报告 HUName=\(name.debugDescription)，不是已验证的 TL-DASH-V2；继续协商")
                }
                condition.lock(); let identity = self.identity; condition.unlock()
                guard let identity else { throw TailingError.closed }
                let signature = try identity.sign(huid)
                payload = try TailingProtocol.json([
                    "pxcVersion": "1.0.2", "phoneUUID": identity.phoneID,
                    "phoneBrand": "iPhone", "phoneModel": phone.model,
                    "phoneOsVersion": phone.systemVersion, "phoneOs": "iOS",
                    "package": phone.package, "versionCode": phone.versionCode, "token": 0,
                    "pubkey": try identity.publicKey().base64EncodedString(),
                    "encryptedHUID": signature.base64EncodedString(), "bluetoothName": "",
                    "supportH264IFrame": isZeeho, "supportFunction": 128, "mirrorRequestReconnect": true
                ])
                try replyControl(socket, request, payload: payload)
                condition.lock()
                self.huid = huid; signedHUID = signature; condition.broadcast()
                condition.unlock()
                log("仪表报告 HUName=\(name.debugDescription)，已回应本机 RSA2048 身份")
                continue
            case 0x10450:
                let time = Int64(Date().timeIntervalSince1970 * 1_000)
                payload = try TailingProtocol.json([
                    "time": time, "currentTime": time + Int64(TimeZone.current.secondsFromGMT()) * 1_000,
                    "currentTimeZone": TimeZone.current.identifier
                ])
            case 0x80000010:
                // 与安卓修正一致：这是“不支持”回应，不是请求。可选状态不被支持时，
                // 仍等待身份、媒体配置与启动三个必要条件，不触发额外状态发送。
                if !reportedUnsupported {
                    reportedUnsupported = true
                    log("仪表报告不支持某项控制消息，继续核对必要媒体协商")
                }
                continue
            case 0x20021, 0x20031, 0x204c1, 0x20491, 0x20051, 0x20591, 0x205a1, 0x70000001:
                continue // 回应不再回应，避免往返循环。
            default:
                // 新固件可能新增协商命令；未知命令记录后继续，避免整场会话直接中断。
                log(String(format: "%@ 会话控制收到未支持的命令 0x%08x（%d 字节）", dashboard, request.command, request.payload.count))
                if strictNegotiation {
                    throw TailingError.protocolFailure(String(format: "未支持的协商命令 0x%08x", request.command))
                }
                continue
            }
            try replyControl(socket, request, payload: payload)
            if request.command == 0x20000 && !reverseStarted {
                reverseStarted = true
                try sendControl(socket, command: 0x204c0, identifier: 1, object: ["state": 0, "msg": ""])
                try sendControl(socket, command: 0x20020, identifier: 2, object: phone.display(mode: 2))
                try sendControl(socket, command: 0x20030, identifier: 3, object: phone.display(mode: 1))
                try socket.write(TailingProtocol.control(0x20050, identifier: 4))
                try sendControl(socket, command: 0x205a0, identifier: 5, object: ["isMaskVisible": false])
                if isZeeho { try startZeehoMirror(socket) }
                startHeartbeat(socket)
            }
        }
    }

    private func replyControl(_ socket: TailingSocket, _ request: TailingProtocol.Control, payload: Data) throws {
        try socket.write(TailingProtocol.control(request.command &+ 1, identifier: request.identifier, payload: payload))
    }

    private func sendControl(_ socket: TailingSocket, command: UInt32, identifier: UInt32,
                             object: [String: Any]) throws {
        try socket.write(TailingProtocol.control(command, identifier: identifier, payload: TailingProtocol.json(object)))
    }

    private func startZeehoMirror(_ socket: TailingSocket) throws {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
        guard reverseControl == nil else { return }
        try sendMirrorControl(socket, start: true, identifier: 6, timeout: 0.25)
        reverseControl = socket
        log("极核已发送开始投屏通知")
        condition.broadcast()
    }

    private func sendMirrorControl(_ socket: TailingSocket, start: Bool, identifier: UInt32,
                                   timeout: TimeInterval) throws {
        let payload = try TailingProtocol.json(["control": start ? 1 : 0])
        try socket.write(TailingProtocol.control(0x20590, identifier: identifier, payload: payload), timeout: timeout)
    }

    private func startHeartbeat(_ socket: TailingSocket) {
        // iOS 成功抓包中同屏状态只在启动时发送，反向连接随后用 0x70000000 保活。
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.hanlin.ninebotpro.tailing.status"))
        var identifier: UInt32 = isZeeho ? 7 : 6
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                try socket.write(TailingProtocol.control(0x70000000, identifier: identifier))
                identifier &+= 1
            } catch { self.fail(TailingError.channel("发送会话保活", error)) }
        }
        condition.lock()
        let stopped = closed
        if !stopped { timers.append(timer) }
        // 即便已经停止，也先激活再取消，避免释放未激活的 dispatch source。
        timer.resume()
        if stopped { timer.cancel() }
        condition.unlock()
    }

    private func auxiliary(_ socket: TailingSocket) throws {
        while true {
            // 此通道可能长时间空闲，停止通过 shutdown 唤醒。
            var readingHeader = true
            let request = try TailingProtocol.readAuxiliary { count in
                defer { readingHeader = false }
                return try socket.readExactly(count, waitForFirstByte: readingHeader)
            }
            var payload = Data()
            let response: UInt16
            switch request.command {
            case 0x10:
                guard request.payload.count >= 32 else {
                    throw TailingError.protocolFailure("媒体配置载荷不足 32 字节")
                }
                let width = request.payload.uint16LE(0)
                let height = request.payload.uint16LE(2)
                let validDimensions = isZeeho ? width == 1024 && (height == 480 || height == 488)
                    : width == 480 && height == 272
                if !validDimensions {
                    // 未验证型号（如二代仪表）可能请求其他尺寸；先按已验证尺寸回话并记录。
                    log("\(dashboard) 仪表请求媒体尺寸 \(width)×\(height)，与已验证的 \(profile.width)×\(profile.height) 不同；按已验证尺寸回话")
                    if strictNegotiation {
                        throw TailingError.protocolFailure("仪表媒体尺寸 \(width)×\(height) 与 \(dashboard) 配置不符")
                    }
                }
                let deadline = Date().addingTimeInterval(5)
                condition.lock()
                while signedHUID == nil && !closed {
                    if !condition.wait(until: deadline) { break }
                }
                let signature = signedHUID, huid = self.huid, identity = self.identity
                condition.unlock()
                guard let signature, let huid, let identity,
                      let echoed = Data(base64Encoded: request.payload.dropFirst(32), options: .ignoreUnknownCharacters),
                      echoed == signature else { throw TailingError.protocolFailure("媒体身份回显不匹配") }
                try identity.verify(echoed, huid: huid)
                payload.appendLE(UInt32(isZeeho ? 2 : 1))
                payload.appendLE(UInt16(profile.width))
                payload.appendLE(UInt16(profile.height))
                response = 0x11
                condition.lock(); configured = true; condition.unlock()
                log("媒体身份回显校验通过，仪表报告 \(width)×\(height)，回应 \(isZeeho ? "H.264" : "JPEG") / \(profile.width)×\(profile.height)")
            case 0x70:
                condition.lock(); let ready = configured; condition.unlock()
                guard ready else { throw TailingError.protocolFailure("仪表在配置完成前请求媒体启动") }
                try socket.write(TailingProtocol.auxiliary(0x71, token: request.token))
                condition.lock(); mediaStarted = true; condition.broadcast(); condition.unlock()
                continue
            case 0x40: response = 0x41
            case 0x30:
                response = 0x31; payload.appendLE(UInt32(5002)); payload.appendLE(UInt32(1))
            case 0x60:
                response = 0x61; payload = try TailingProtocol.json(["supportFunction": 0])
            case 0x20: continue // 不执行反控触摸。
            default:
                response = 0x7f02
                log(String(format: "媒体控制通道暂不支持 0x%04x", request.command))
            }
            try socket.write(TailingProtocol.auxiliary(response, token: request.token, payload: payload))
        }
    }

    private func checkLocked() throws {
        if let failure { throw failure }
        if closed { throw TailingError.closed }
    }

    private func fail(_ error: Error) {
        condition.lock()
        let shouldFail = !closed && failure == nil
        if shouldFail { failure = error }
        condition.unlock()
        if shouldFail { close() }
    }
}
