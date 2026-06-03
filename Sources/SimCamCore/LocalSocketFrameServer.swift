import Foundation
import CoreMedia
import CoreVideo
import os.log

/// LocalSocketFrameServer
///
/// host (SimCamApp) ↔ iOS Simulator 进程的零拷贝帧通道。
///
/// 协议 v2（little-endian，packed，48 字节 header）：
/// ```
/// struct SimCamFrameHeader {       offset
///     uint32 magic                  0   // 'SIMC' = 0x434D4953
///     uint32 version                4   // 2
///     uint32 width                  8
///     uint32 height                12
///     uint32 bytesPerRow           16
///     uint32 pixelFormat           20   // kCVPixelFormatType_32BGRA = 'BGRA'
///     uint64 hostTimeNs            24
///     uint32 payloadLen            32   // = bytesPerRow * height
///     uint32 qrPayloadLen          36   // optional UTF-8 QR payload
///     uint8  cameraSlot            40   // 0 = back, 1 = front
///     uint8  reserved[7]           41
/// };  // 总长 48 字节，__attribute__((packed))
/// // 然后是 payloadLen 字节 BGRA + qrPayloadLen 字节 UTF-8
/// ```
///
/// 选 unix domain socket 而不是 HTTP 的原因：
/// 1. CoreSimulator 把 host 的 `/tmp` 直接桥接进 simulator 进程的 `/tmp`，
///    所以 simulator 内的 SimCamHook.dylib 直接 connect("/tmp/...")
///    就能连上 host —— 完全无网络栈。
/// 2. 没有 JPEG 编码 / multipart 解析，host 一次 write，hook 一次 read，
///    1080p BGRA 帧约 8MB，30fps 在本机 sock 上完全无压力。
/// 3. 二进制对齐 SimCam 真实做法（DYLD_INSERT 注入 + 共享内存帧）。
///
/// v2 把单路扩成 back/front 双 slot，被测 app 切前/后摄就拿到不同帧。
///
/// 注：CMIO Camera Extension 的 host↔extension 通道已迁移到 Apple 官方推荐的
/// `CMIOExtensionStream(direction: .sink)` + `CMSimpleQueueEnqueue`（见
/// `CMIOSinkClient.swift`），所以本类只剩 simulator dylib 一条路径。
public final class LocalSocketFrameServer {

    /// iOS Simulator dylib 走的路径。CoreSimulator 把 host 的 `/tmp` 桥接进
    /// simulator 进程的 `/tmp`，所以保持绝对路径不变。
    public static let socketPath = "/tmp/com.simcam.frames.sock"

    private let log = OSLog(subsystem: "dev.simcam", category: "framesock")
    private let queue = DispatchQueue(label: "dev.simcam.framesock", qos: .userInteractive)
    private var serverFD: Int32 = -1
    private var clientFDs: [Int32] = []
    private let clientsLock = NSLock()
    private var isRunning = false

    private let stateLock = NSLock()
    private var qrPayloads: [String?] = [nil, nil]   // index = CameraSlot.rawValue

    public init() {}

    public func start() {
        queue.async { self.listenLoop(path: LocalSocketFrameServer.socketPath) }
    }

    public func stop() {
        isRunning = false
        clientsLock.lock()
        clientFDs.forEach { Darwin.close($0) }
        clientFDs.removeAll()
        clientsLock.unlock()
        if serverFD >= 0 { Darwin.close(serverFD); serverFD = -1 }
    }

    /// 给指定槽位（back/front）设置当前 QR payload。
    public func setQRPayload(_ payload: String?, slot: CameraSlot) {
        stateLock.lock()
        qrPayloads[slot.rawValue] = payload
        stateLock.unlock()
    }

    public var clientCount: Int {
        clientsLock.lock(); defer { clientsLock.unlock() }
        return clientFDs.count
    }

    /// SimCamEngine 每收到一帧就调一次。把 BGRA 像素直接写到所有连上来的
    /// simulator 进程，slot 决定 hook 端把帧路由给 back 还是 front。
    /// 任何 client 写失败就把它从列表里踢掉。
    public func push(_ sample: CMSampleBuffer, slot: CameraSlot) {
        guard let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else {
            return  // engine 用的是 32BGRA；其它格式先忽略
        }
        clientsLock.lock()
        let snapshot = clientFDs
        clientsLock.unlock()
        if snapshot.isEmpty { return }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let width  = UInt32(CVPixelBufferGetWidth(pb))
        let height = UInt32(CVPixelBufferGetHeight(pb))
        let bpr    = UInt32(CVPixelBufferGetBytesPerRow(pb))
        let payloadLen = bpr * height
        let hostTimeNs = UInt64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
        stateLock.lock()
        let qr = qrPayloads[slot.rawValue] ?? ""
        stateLock.unlock()
        let qrBytes = qr.data(using: .utf8) ?? Data()

        let header = SimCamFrameHeader.serialize(
            magic: 0x434D4953,
            version: 2,
            width: width,
            height: height,
            bytesPerRow: bpr,
            pixelFormat: 0x42475241,  // 'BGRA' = kCVPixelFormatType_32BGRA
            hostTimeNs: hostTimeNs,
            payloadLen: payloadLen,
            qrPayloadLen: UInt32(qrBytes.count),
            cameraSlot: UInt8(slot.rawValue)
        )

        var deadFDs: [Int32] = []
        for fd in snapshot {
            // header
            let okHeader = header.withUnsafeBytes { ptr -> Bool in
                writeAll(fd, ptr.baseAddress!, ptr.count)
            }
            if !okHeader { deadFDs.append(fd); continue }
            // BGRA payload
            if !writeAll(fd, base, Int(payloadLen)) { deadFDs.append(fd); continue }
            // QR payload (optional)
            if !qrBytes.isEmpty {
                let okQR = qrBytes.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Bool in
                    writeAll(fd, ptr.baseAddress!, ptr.count)
                }
                if !okQR { deadFDs.append(fd); continue }
            }
        }
        if !deadFDs.isEmpty {
            clientsLock.lock()
            clientFDs.removeAll { deadFDs.contains($0) }
            clientsLock.unlock()
            for fd in deadFDs { Darwin.close(fd) }
            os_log("dropped %{public}d dead client(s); now=%{public}d",
                   log: log, deadFDs.count, clientCount)
        }
    }

    // MARK: - private

    private func listenLoop(path: String) {
        // 起 server，listen，一直 accept。
        unlink(path)
        // 父目录可能不存在 —— 先建好。
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            os_log("socket(%{public}s) failed: %{public}d", log: log, path, errno); return
        }
        // 不要 SIGPIPE
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path 在 macOS 上 104 字节上限。
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
            path.withCString { src in
                strlcpy(dst, src, sunPathSize)
            }
        }
        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa -> Int32 in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if bindRes != 0 {
            os_log("bind(%{public}s) failed: %{public}d", log: log, path, errno)
            Darwin.close(fd); return
        }
        // unix sock 受 fs perms 控制；/tmp 路径需要 0666 让 simulator 进程
        // (uid=guoshuyu) 也能 connect。
        chmod(path, 0o666)

        if listen(fd, 8) != 0 {
            os_log("listen(%{public}s) failed: %{public}d", log: log, path, errno)
            Darwin.close(fd); return
        }
        serverFD = fd
        isRunning = true
        os_log("listening on %{public}s", log: log, path)

        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                os_log("accept(%{public}s) failed: %{public}d", log: log, path, errno); break
            }
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // 大帧需要 send buffer 够大
            var sndbuf: Int32 = 8 * 1024 * 1024
            setsockopt(client, SOL_SOCKET, SO_SNDBUF, &sndbuf, socklen_t(MemoryLayout<Int32>.size))
            clientsLock.lock()
            clientFDs.append(client)
            clientsLock.unlock()
            os_log("client connected fd=%{public}d (total=%{public}d)",
                   log: log, client, clientCount)
        }
    }

    /// 写完整缓冲；任一字节失败即返回 false（让 caller 把这个 fd 踢掉）。
    @inline(__always)
    private func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ n: Int) -> Bool {
        var sent = 0
        while sent < n {
            let r = Darwin.write(fd, ptr.advanced(by: sent), n - sent)
            if r <= 0 {
                if r < 0 && errno == EINTR { continue }
                return false
            }
            sent += r
        }
        return true
    }
}

// MARK: - Wire-format header serializer (must match SimCamHook.h)
//
// The dylib reads a 48-byte __attribute__((packed)) little-endian struct (v2):
//
//     0:  uint32  magic         ('SIMC' = 0x434D4953)
//     4:  uint32  version       (2)
//     8:  uint32  width
//    12:  uint32  height
//    16:  uint32  bytesPerRow
//    20:  uint32  pixelFormat   ('BGRA' = 0x42475241)
//    24:  uint64  hostTimeNs
//    32:  uint32  payloadLen
//    36:  uint32  qrPayloadLen
//    40:  uint8   cameraSlot
//    41:  uint8[7] reserved
//   ─── total = 48 bytes
//
// A Swift struct mirroring this layout fights with Swift's natural
// 8-byte alignment of UInt64 (it inserts 4 bytes of padding before
// hostTimeNs). To guarantee wire compatibility with the C
// `__attribute__((packed))` struct in SimCamHook.h we hand-serialize
// into a 48-byte Data buffer below.
private enum SimCamFrameHeader {
    static let byteCount = 48

    static func serialize(magic: UInt32,
                          version: UInt32,
                          width: UInt32,
                          height: UInt32,
                          bytesPerRow: UInt32,
                          pixelFormat: UInt32,
                          hostTimeNs: UInt64,
                          payloadLen: UInt32,
                          qrPayloadLen: UInt32,
                          cameraSlot: UInt8) -> Data {
        var buf = Data(count: byteCount)
        buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.baseAddress!
            var u32: UInt32 = 0
            var u64: UInt64 = 0
            u32 = magic.littleEndian;        memcpy(p.advanced(by: 0),  &u32, 4)
            u32 = version.littleEndian;      memcpy(p.advanced(by: 4),  &u32, 4)
            u32 = width.littleEndian;        memcpy(p.advanced(by: 8),  &u32, 4)
            u32 = height.littleEndian;       memcpy(p.advanced(by: 12), &u32, 4)
            u32 = bytesPerRow.littleEndian;  memcpy(p.advanced(by: 16), &u32, 4)
            u32 = pixelFormat.littleEndian;  memcpy(p.advanced(by: 20), &u32, 4)
            u64 = hostTimeNs.littleEndian;   memcpy(p.advanced(by: 24), &u64, 8)
            u32 = payloadLen.littleEndian;   memcpy(p.advanced(by: 32), &u32, 4)
            u32 = qrPayloadLen.littleEndian; memcpy(p.advanced(by: 36), &u32, 4)
            var slot: UInt8 = cameraSlot;    memcpy(p.advanced(by: 40), &slot, 1)
            // reserved[7] left as zero by Data(count:)
        }
        return buf
    }
}
