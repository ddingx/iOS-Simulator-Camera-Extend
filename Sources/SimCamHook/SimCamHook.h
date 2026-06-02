// SimCamHook
//
// iOS-Simulator-only dylib that, when DYLD_INSERT_LIBRARIES'd into a target
// process, swizzles AVFoundation so the host SimCamApp's frames appear as
// regular back / front cameras. The target app uses STANDARD AVFoundation
// APIs (AVCaptureDevice / AVCaptureSession / AVCaptureVideoPreviewLayer /
// AVCaptureMetadataOutput) with zero source modifications — just like SimCam.
//
// Wire protocol v2 vs host SimCamApp's LocalSocketFrameServer
// (/tmp/com.simcam.frames.sock, AF_UNIX SOCK_STREAM, little-endian):
//
//   struct SimCamFrameHeader {
//       uint32_t magic;          // 'SIMC' = 0x434D4953 (read as LE)
//       uint32_t version;        // 2
//       uint32_t width;
//       uint32_t height;
//       uint32_t bytesPerRow;
//       uint32_t pixelFormat;    // kCVPixelFormatType_32BGRA = 'BGRA'
//       uint64_t hostTimeNs;
//       uint32_t payloadLen;     // = bytesPerRow * height
//       uint32_t qrPayloadLen;   // optional QR payload (UTF-8) following BGRA
//       uint8_t  cameraSlot;     // v2: 0 = back, 1 = front
//       uint8_t  reserved[7];    // v2: padding to 8-byte align, write 0
//   } __attribute__((packed));   // total = 48 bytes
//
// Loaded automatically via __attribute__((constructor)) — no public API.

#ifndef SIMCAM_HOOK_H
#define SIMCAM_HOOK_H

#import <Foundation/Foundation.h>

#define SIMCAM_FRAME_MAGIC      0x434D4953u   // 'SIMC' little-endian on disk
#define SIMCAM_FRAME_VERSION    2u
#define SIMCAM_DEFAULT_SOCK     "/tmp/com.simcam.frames.sock"

// Camera slots, matching CameraSlot in Swift.
#define SIMCAM_SLOT_BACK        0u
#define SIMCAM_SLOT_FRONT       1u
#define SIMCAM_SLOT_COUNT       2

#endif
