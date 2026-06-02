// SimCamHook.m
//
// Constructor + AVFoundation swizzle. Pulls frames from the host SimCamApp
// over /tmp/com.simcam.frames.sock and feeds them into:
//   • AVCaptureVideoDataOutput sample-buffer delegates
//   • AVCaptureMetadataOutput delegates (for QR)
//   • AVCaptureVideoPreviewLayer (rendered as a fake CALayer overlay)
//
// AVCaptureDevice.DiscoverySession is patched to expose 2 fake devices:
//   "SimCam Back Camera"  position=back
//   "SimCam Front Camera" position=front
//
// AVCaptureSession startRunning kicks our background frame puller; sample
// buffers built from the latest BGRA frame fan out to all known delegates.

#import "SimCamHook.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <fcntl.h>
#import <os/log.h>

#pragma pack(push, 1)
typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t width;
    uint32_t height;
    uint32_t bytesPerRow;
    uint32_t pixelFormat;
    uint64_t hostTimeNs;
    uint32_t payloadLen;
    uint32_t qrPayloadLen;
    uint8_t  cameraSlot;       // v2: 0=back, 1=front
    uint8_t  reserved[7];
} SimCamFrameHeader;
#pragma pack(pop)
_Static_assert(sizeof(SimCamFrameHeader) == 48, "v2 header must be 48 bytes");

#define HLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[SimCamHook] " fmt, ##__VA_ARGS__)

// ==================== fake device IDs ====================
static NSString * const kSimCamBackUID  = @"SIMCAM-BACK-CAMERA";
static NSString * const kSimCamFrontUID = @"SIMCAM-FRONT-CAMERA";

// ==================== global frame state ====================
//
// v2: per-camera-slot pixel buffers + per-slot QR payloads.
// Slot 0 = back, Slot 1 = front. Routed by SimCamFrameHeader.cameraSlot.
static pthread_mutex_t gFrameLock = PTHREAD_MUTEX_INITIALIZER;
static CVPixelBufferRef gLatestPixelBuffer[SIMCAM_SLOT_COUNT] = { NULL, NULL };
static uint64_t gLatestHostTime[SIMCAM_SLOT_COUNT] = { 0, 0 };
static NSString *gLatestQRPayload[SIMCAM_SLOT_COUNT] = { nil, nil };

static inline int simcam_slot_for_position(AVCaptureDevicePosition pos) {
    return (pos == AVCaptureDevicePositionFront) ? SIMCAM_SLOT_FRONT
                                                 : SIMCAM_SLOT_BACK;
}

// All sample-buffer delegates registered by the target app, plus the queue
// each one was registered on, plus the AVCaptureVideoDataOutput it belongs
// to (delegate API requires "from connection:").
@interface SimCamSBDelegateEntry : NSObject
@property(nonatomic, weak)   id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, weak)   AVCaptureVideoDataOutput *output;
@end
@implementation SimCamSBDelegateEntry @end

@interface SimCamMetaDelegateEntry : NSObject
@property(nonatomic, weak)   id<AVCaptureMetadataOutputObjectsDelegate> delegate;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, weak)   AVCaptureMetadataOutput *output;
@property(nonatomic, copy)   NSString *lastEmitted;
@end
@implementation SimCamMetaDelegateEntry @end

static NSMutableArray<SimCamSBDelegateEntry *> *gSBDelegates;
static NSMutableArray<SimCamMetaDelegateEntry *> *gMetaDelegates;

// AVCaptureVideoPreviewLayer sublayers we install (so we can set contents
// without breaking what AVFoundation thinks the layer is).
static NSHashTable<CALayer *> *gPreviewLayers;
// layer → AVCaptureSession (weak↔weak) so we can pick a slot at render time.
static NSMapTable<CALayer *, AVCaptureSession *> *gPreviewLayerSessions;

static dispatch_queue_t gPullerQueue;
static int gSocketFD = -1;
static BOOL gPullerRunning = NO;

// ==================== fake device singletons ====================
static AVCaptureDevice *gFakeBack;
static AVCaptureDevice *gFakeFront;

// ==================== forwards ====================
@interface SimCamFakeMetadata : AVMetadataMachineReadableCodeObject
+ (instancetype)withPayload:(NSString *)payload;
@end

static void simcam_install_swizzles(void);
static void simcam_start_puller(void);
static CVPixelBufferRef simcam_pixelbuffer_from_bgra(const uint8_t *bytes,
                                                    uint32_t width,
                                                    uint32_t height,
                                                    uint32_t bytesPerRow);
static void simcam_dispatch_sample(int slot, CVPixelBufferRef pb, uint64_t hostTimeNs);
static void simcam_dispatch_metadata(int slot, NSString *payload);
static void simcam_render_preview(int slot, CVPixelBufferRef pb);

// AVCaptureSession ↔ slot resolution: figure out which slot (back/front)
// a given session belongs to by inspecting our shadow input array. We
// deliberately do NOT call -[AVCaptureSession inputs] here — that selector
// is read by UIKit / AVFoundation internals (e.g. UIMenuSystem builder)
// in ways that don't tolerate a fully-swizzled override. Reading the
// `simcam.inputs` association directly keeps us out of those code paths.
//
// We iterate the shadow array in reverse so that the *most recently
// added* input wins. Apps like our demo do removeInput(old) +
// addInput(new) on the SAME session when the user toggles back/front;
// the back input is appended first and never removed (since we don't
// observe -removeInput: as faithfully as -addInput:). Reverse iteration
// makes the resolver always reflect the current "tail" input.
//
// Returns SIMCAM_SLOT_BACK / SIMCAM_SLOT_FRONT for a positively-resolved
// slot. Returns -1 ("unknown / transient") when the inputs array is
// momentarily empty — this happens during -removeInput: → -addInput:
// re-config in apps that swap input on the SAME session (our demo
// does this even when the position doesn't change, e.g. when SwiftUI
// re-runs updateUIView). Callers must skip -1 frames to avoid routing
// the wrong slot's pixels to the layer during that transient window;
// without this guard, host front-slot frames briefly land on a
// preview layer whose session momentarily has no input, default-routed
// to BACK, producing the "occasional flash of front in back" bug.
static int simcam_session_slot(AVCaptureSession *session) {
    if (!session) return -1;
    // Fast path: if we cached a slot from a previous successful
    // resolution on this session, prefer it whenever the live array
    // is empty. This way `removeInput → addInput` micro-windows
    // never route a frame to the wrong slot.
    NSArray *inputs;
    @synchronized(session) {
        inputs = [objc_getAssociatedObject(session, "simcam.inputs") copy];
    }
    for (AVCaptureInput *inp in inputs.reverseObjectEnumerator) {
        if ([inp isKindOfClass:[AVCaptureDeviceInput class]]) {
            AVCaptureDevice *d = ((AVCaptureDeviceInput *)inp).device;
            if (!d) d = objc_getAssociatedObject(inp, "simcam.device");
            if (d) {
                int slot = simcam_slot_for_position(d.position);
                // Cache the most recent positive resolution on the
                // session; we'll fall back to it during removeInput
                // micro-windows.
                NSNumber *cached = @(slot);
                objc_setAssociatedObject(session, "simcam.lastSlot",
                                         cached,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                return slot;
            }
        }
    }
    // Inputs array is empty (transient). Fall back to last known slot.
    NSNumber *cached = objc_getAssociatedObject(session, "simcam.lastSlot");
    if (cached) return cached.intValue;
    return -1;
}

// ============================================================
// MARK: - constructor
// ============================================================
__attribute__((constructor))
static void simcam_hook_init(void) {
#if !TARGET_OS_SIMULATOR
    HLOG("not running in simulator, hook disabled");
    return;
#else
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSBDelegates    = [NSMutableArray new];
        gMetaDelegates  = [NSMutableArray new];
        gPreviewLayers  = [NSHashTable weakObjectsHashTable];
        gPreviewLayerSessions =
            [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory
                                  valueOptions:NSPointerFunctionsWeakMemory];
        gPullerQueue    = dispatch_queue_create("dev.simcam.hook.puller",
                                                DISPATCH_QUEUE_SERIAL);
        simcam_install_swizzles();
        simcam_start_puller();
        HLOG("installed (sock=%s)", SIMCAM_DEFAULT_SOCK);
    });
#endif
}

// ============================================================
// MARK: - swizzle helpers
// ============================================================
static IMP simcam_swizzle_class_method(Class cls, SEL sel, id replacementBlock) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) { HLOG("missing class method %s on %s", sel_getName(sel), class_getName(cls)); return NULL; }
    IMP newImp = imp_implementationWithBlock(replacementBlock);
    return method_setImplementation(m, newImp);
}

static IMP simcam_swizzle_instance_method(Class cls, SEL sel, id replacementBlock) {
    Method m = class_getInstanceMethod(cls, sel);
    IMP newImp = imp_implementationWithBlock(replacementBlock);
    const char *types = m ? method_getTypeEncoding(m) : "v@:@";
    // Always install on `cls` itself so dispatch on an instance whose isa
    // is exactly `cls` hits us first, even if the SEL was previously only
    // resolved on a parent class or via +resolveInstanceMethod:.
    if (!class_addMethod(cls, sel, newImp, types)) {
        // Already exists on cls — replace it.
        class_replaceMethod(cls, sel, newImp, types);
    }
    return m ? method_getImplementation(m) : NULL;
}

// Force-install on a specific class with a specific Objective-C type
// encoding (use when the SEL might not be visible to class_getInstanceMethod
// at install time, e.g. dynamically-resolved property setters).
static void simcam_force_install(Class cls, SEL sel, id block, const char *types) {
    IMP newImp = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, newImp, types)) {
        class_replaceMethod(cls, sel, newImp, types);
    }
}

// ============================================================
// MARK: - fake AVCaptureDevice plumbing
// ============================================================
//
// We can't subclass AVCaptureDevice (its init is private). Instead we
// allocate one via the runtime, then swizzle property getters per-instance
// using associated objects + class_addMethod on a freshly minted subclass.
// To keep this simple and robust we build *one* tiny subclass at runtime
// (`SimCamFakeAVCaptureDevice`) that overrides just the getters we need.

@interface SimCamFakeAVCaptureDevice : AVCaptureDevice
@end

@implementation SimCamFakeAVCaptureDevice {
    NSString *_uid;
    NSString *_name;
    AVCaptureDevicePosition _position;
}
- (NSString *)uniqueID    { return _uid; }
- (NSString *)localizedName { return _name; }
- (NSString *)modelID     { return @"SimCamVirtual"; }
- (NSString *)manufacturer { return @"SimCam"; }
- (AVCaptureDevicePosition)position { return _position; }
- (BOOL)hasMediaType:(AVMediaType)mediaType { return [mediaType isEqualToString:AVMediaTypeVideo]; }
- (BOOL)supportsAVCaptureSessionPreset:(AVCaptureSessionPreset)preset { return YES; }
- (BOOL)isConnected { return YES; }
- (BOOL)isSuspended { return NO; }
- (NSArray<AVCaptureDeviceFormat *> *)formats { return @[]; }
- (BOOL)lockForConfiguration:(NSError **)outError { return YES; }
- (void)unlockForConfiguration {}

+ (instancetype)backCamera {
    SimCamFakeAVCaptureDevice *d = (SimCamFakeAVCaptureDevice *)
        class_createInstance([SimCamFakeAVCaptureDevice class], 0);
    d->_uid = kSimCamBackUID;
    d->_name = @"SimCam Back Camera";
    d->_position = AVCaptureDevicePositionBack;
    return d;
}
+ (instancetype)frontCamera {
    SimCamFakeAVCaptureDevice *d = (SimCamFakeAVCaptureDevice *)
        class_createInstance([SimCamFakeAVCaptureDevice class], 0);
    d->_uid = kSimCamFrontUID;
    d->_name = @"SimCam Front Camera";
    d->_position = AVCaptureDevicePositionFront;
    return d;
}
@end

static AVCaptureDevice *simcam_back(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gFakeBack  = [SimCamFakeAVCaptureDevice backCamera];  });
    return gFakeBack;
}
static AVCaptureDevice *simcam_front(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gFakeFront = [SimCamFakeAVCaptureDevice frontCamera]; });
    return gFakeFront;
}

// ============================================================
// MARK: - install swizzles
// ============================================================
static void simcam_install_swizzles(void) {
    // ---------- AVCaptureDevice.devicesWithMediaType: ----------
    simcam_swizzle_class_method([AVCaptureDevice class],
                                @selector(devicesWithMediaType:),
                                ^NSArray *(id self, AVMediaType type) {
        if ([type isEqualToString:AVMediaTypeVideo]) {
            return @[ simcam_back(), simcam_front() ];
        }
        return @[];
    });

    // ---------- AVCaptureDevice.defaultDeviceWithMediaType: ----------
    simcam_swizzle_class_method([AVCaptureDevice class],
                                @selector(defaultDeviceWithMediaType:),
                                ^AVCaptureDevice *(id self, AVMediaType type) {
        if ([type isEqualToString:AVMediaTypeVideo]) return simcam_back();
        return nil;
    });

    // ---------- AVCaptureDevice.deviceWithUniqueID: ----------
    simcam_swizzle_class_method([AVCaptureDevice class],
                                @selector(deviceWithUniqueID:),
                                ^AVCaptureDevice *(id self, NSString *uid) {
        if ([uid isEqualToString:kSimCamBackUID])  return simcam_back();
        if ([uid isEqualToString:kSimCamFrontUID]) return simcam_front();
        return nil;
    });

    // ---------- AVCaptureDevice.defaultDeviceWithDeviceType:mediaType:position: ----------
    // The demo (and many real apps) call this 3-arg variant to pick a
    // back/front camera by .position. Without this swizzle the call falls
    // through to the real impl on iOS Simulator (which has no hardware) and
    // returns nil — the app then often retries -defaultDeviceWithMediaType:
    // which we do hook, but that always yields simcam_back(). End result:
    // user toggles to front but session.input.device.position is still .back,
    // simcam_session_slot() resolves to BACK, and the preview layer keeps
    // showing back frames. Swizzling here lets us return the correct
    // simcam_front() / simcam_back() based on requested position.
    SEL defaultDevSel = NSSelectorFromString(@"defaultDeviceWithDeviceType:mediaType:position:");
    if ([AVCaptureDevice respondsToSelector:defaultDevSel]) {
        simcam_swizzle_class_method([AVCaptureDevice class],
                                    defaultDevSel,
                                    ^AVCaptureDevice *(id self,
                                                       AVCaptureDeviceType type,
                                                       AVMediaType mt,
                                                       AVCaptureDevicePosition pos) {
            if (mt && ![mt isEqualToString:AVMediaTypeVideo]) return nil;
            switch (pos) {
                case AVCaptureDevicePositionFront: return simcam_front();
                case AVCaptureDevicePositionBack:  return simcam_back();
                case AVCaptureDevicePositionUnspecified:
                default:                           return simcam_back();
            }
        });
    }

    // ---------- AVCaptureDeviceDiscoverySession.discoverySessionWithDeviceTypes:mediaType:position: ----------
    simcam_swizzle_class_method([AVCaptureDeviceDiscoverySession class],
                                @selector(discoverySessionWithDeviceTypes:mediaType:position:),
                                ^AVCaptureDeviceDiscoverySession *(id self,
                                                                    NSArray *types,
                                                                    AVMediaType mt,
                                                                    AVCaptureDevicePosition pos) {
        // The real init touches private state. We bypass it entirely by
        // using class_createInstance — gives us a zero-ivar instance whose
        // isa is AVCaptureDeviceDiscoverySession, so subsequent
        // `[s devices]` hits our swizzled instance method.
        AVCaptureDeviceDiscoverySession *s =
            class_createInstance([AVCaptureDeviceDiscoverySession class], 0);
        NSArray *all = @[ simcam_back(), simcam_front() ];
        NSMutableArray *matched = [NSMutableArray arrayWithCapacity:2];
        for (AVCaptureDevice *d in all) {
            if (mt && ![mt isEqualToString:AVMediaTypeVideo]) continue;
            if (pos != AVCaptureDevicePositionUnspecified && d.position != pos) continue;
            [matched addObject:d];
        }
        objc_setAssociatedObject(s, "simcam.devices", matched, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return s;
    });
    simcam_swizzle_instance_method([AVCaptureDeviceDiscoverySession class],
                                   @selector(devices),
                                   ^NSArray *(id self) {
        NSArray *cached = objc_getAssociatedObject(self, "simcam.devices");
        return cached ?: @[ simcam_back(), simcam_front() ];
    });

    // ---------- AVCaptureDeviceInput +deviceInputWithDevice:error: ----------
    // Real impl pokes hardware. We allocate an empty AVCaptureDeviceInput-
    // -shaped object and stash the device association.
    simcam_swizzle_class_method([AVCaptureDeviceInput class],
                                @selector(deviceInputWithDevice:error:),
                                ^AVCaptureDeviceInput *(id self,
                                                        AVCaptureDevice *device,
                                                        NSError **errOut) {
        if (![device isKindOfClass:[SimCamFakeAVCaptureDevice class]]) {
            // Forward to original impl-equivalent: there is none safely
            // accessible after swizzle, so just synthesize.
            return nil;
        }
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput alloc];
        objc_setAssociatedObject(input, "simcam.device", device, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return input;
    });

    // ---------- AVCaptureSession addInput: / addOutput: ----------
    // Just remember them; real session won't run real hardware so we let
    // it succeed and we'll feed frames manually. We also stash a back-
    // pointer from input/output to the session so the slot router can
    // resolve the device → slot at frame-dispatch time.
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(addInput:),
                                   ^(AVCaptureSession *self, AVCaptureInput *input) {
        objc_setAssociatedObject(self, "simcam.input", input, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(input, "simcam.session", self, OBJC_ASSOCIATION_ASSIGN);
        // Keep a list of all inputs for simcam_session_slot to enumerate.
        // @synchronized(self) so simcam_session_slot snapshot stays
        // consistent with us mutating the array under the same lock.
        @synchronized(self) {
            NSMutableArray *inputs = objc_getAssociatedObject(self, "simcam.inputs");
            if (!inputs) {
                inputs = [NSMutableArray new];
                objc_setAssociatedObject(self, "simcam.inputs", inputs,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (input && ![inputs containsObject:input]) [inputs addObject:input];
            // Eagerly cache the slot from this just-added input so the
            // *next* removeInput→addInput micro-window has a fresh
            // fallback value.
            if ([input isKindOfClass:[AVCaptureDeviceInput class]]) {
                AVCaptureDevice *d = ((AVCaptureDeviceInput *)input).device;
                if (!d) d = objc_getAssociatedObject(input, "simcam.device");
                if (d) {
                    objc_setAssociatedObject(self, "simcam.lastSlot",
                                             @(simcam_slot_for_position(d.position)),
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            }
        }
    });
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(addOutput:),
                                   ^(AVCaptureSession *self, AVCaptureOutput *output) {
        objc_setAssociatedObject(output, "simcam.session", self, OBJC_ASSOCIATION_ASSIGN);
        @synchronized(self) {
            NSMutableArray *outputs = objc_getAssociatedObject(self, "simcam.outputs");
            if (!outputs) {
                outputs = [NSMutableArray new];
                objc_setAssociatedObject(self, "simcam.outputs", outputs,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (output && ![outputs containsObject:output]) [outputs addObject:output];
        }
    });
    // ---------- AVCaptureSession removeInput: / removeOutput: ----------
    // Apps like the demo do removeInput(old) + addInput(new) on the SAME
    // session when toggling back/front. We must keep the shadow array in
    // sync, otherwise simcam_session_slot() sees a stale tail and routes
    // frames to the wrong slot. We DO NOT clear simcam.lastSlot here —
    // the next addInput: will overwrite it; in the meantime the resolver
    // falls back to the cached value (which is still the soon-to-be-old
    // slot, and that is correct — frames in flight belong to that slot).
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(removeInput:),
                                   ^(AVCaptureSession *self, AVCaptureInput *input) {
        @synchronized(self) {
            NSMutableArray *inputs = objc_getAssociatedObject(self, "simcam.inputs");
            if (input) [inputs removeObject:input];
        }
        objc_setAssociatedObject(input, "simcam.session", nil, OBJC_ASSOCIATION_ASSIGN);
    });
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(removeOutput:),
                                   ^(AVCaptureSession *self, AVCaptureOutput *output) {
        @synchronized(self) {
            NSMutableArray *outputs = objc_getAssociatedObject(self, "simcam.outputs");
            if (output) [outputs removeObject:output];
        }
        objc_setAssociatedObject(output, "simcam.session", nil, OBJC_ASSOCIATION_ASSIGN);
    });
    // -inputs / -outputs are intentionally NOT swizzled. They are read by
    // UIKit / AVFoundation internals (UIMenuSystem builder, key-command
    // chain enumeration, …) on threads we don't control, with ARC retain
    // hints that a hand-rolled IMP can't honor. Our own slot router reads
    // the `simcam.inputs` / `simcam.outputs` associations directly.
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(canAddInput:),
                                   ^BOOL(AVCaptureSession *self, AVCaptureInput *input) {
        return YES;
    });
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(canAddOutput:),
                                   ^BOOL(AVCaptureSession *self, AVCaptureOutput *out) {
        return YES;
    });

    // ---------- AVCaptureVideoDataOutput setSampleBufferDelegate:queue: ----------
    simcam_swizzle_instance_method([AVCaptureVideoDataOutput class],
                                   @selector(setSampleBufferDelegate:queue:),
                                   ^(AVCaptureVideoDataOutput *self,
                                     id<AVCaptureVideoDataOutputSampleBufferDelegate> dlg,
                                     dispatch_queue_t q) {
        @synchronized(gSBDelegates) {
            [gSBDelegates filterUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(SimCamSBDelegateEntry *e, id _) {
                    return e.output != self && e.delegate != nil;
                }]];
            if (dlg) {
                SimCamSBDelegateEntry *e = [SimCamSBDelegateEntry new];
                e.delegate = dlg;
                e.queue = q ?: dispatch_get_main_queue();
                e.output = self;
                [gSBDelegates addObject:e];
                HLOG("registered sample-buffer delegate %s", class_getName([dlg class]));
            }
        }
    });

    // ---------- AVCaptureMetadataOutput setMetadataObjectsDelegate:queue: ----------
    simcam_swizzle_instance_method([AVCaptureMetadataOutput class],
                                   @selector(setMetadataObjectsDelegate:queue:),
                                   ^(AVCaptureMetadataOutput *self,
                                     id<AVCaptureMetadataOutputObjectsDelegate> dlg,
                                     dispatch_queue_t q) {
        @synchronized(gMetaDelegates) {
            [gMetaDelegates filterUsingPredicate:
                [NSPredicate predicateWithBlock:^BOOL(SimCamMetaDelegateEntry *e, id _) {
                    return e.output != self && e.delegate != nil;
                }]];
            if (dlg) {
                SimCamMetaDelegateEntry *e = [SimCamMetaDelegateEntry new];
                e.delegate = dlg;
                e.queue = q ?: dispatch_get_main_queue();
                e.output = self;
                [gMetaDelegates addObject:e];
                HLOG("registered metadata delegate %s", class_getName([dlg class]));
            }
        }
    });

    // The metadata output normally validates types against the connected
    // input's hardware-supported list. With our fake device that list is
    // empty, so .qr would throw. Swallow the validation: just store the
    // requested types via association.
    simcam_swizzle_instance_method([AVCaptureMetadataOutput class],
                                   @selector(setMetadataObjectTypes:),
                                   ^(AVCaptureMetadataOutput *self, NSArray *types) {
        objc_setAssociatedObject(self, "simcam.metaTypes", types,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
    simcam_swizzle_instance_method([AVCaptureMetadataOutput class],
                                   @selector(metadataObjectTypes),
                                   ^NSArray *(AVCaptureMetadataOutput *self) {
        NSArray *t = objc_getAssociatedObject(self, "simcam.metaTypes");
        return t ?: @[];
    });
    simcam_swizzle_instance_method([AVCaptureMetadataOutput class],
                                   @selector(availableMetadataObjectTypes),
                                   ^NSArray *(AVCaptureMetadataOutput *self) {
        return @[ AVMetadataObjectTypeQRCode,
                  AVMetadataObjectTypeEAN13Code,
                  AVMetadataObjectTypeEAN8Code,
                  AVMetadataObjectTypeCode128Code ];
    });

    // ---------- AVCaptureVideoPreviewLayer init ----------
    // The real impl walks a private session; in simulator we just give it
    // a stub layer and remember it so we can blit pixel buffers as contents.
    simcam_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
                                   @selector(initWithSession:),
                                   ^id(AVCaptureVideoPreviewLayer *self, AVCaptureSession *session) {
        // The +alloc that produced `self` already sized the buffer for
        // AVCaptureVideoPreviewLayer's full ivar layout; we just need to
        // run CALayer's -init on it (skipping AVF's real -init which dives
        // into the capture pipeline). class_createInstance zero-fills, so
        // any "if (_ivar)" guard inside AVF internals reads nil and bails.
        struct objc_super sup = { self, [CALayer class] };
        id (*castSuperInit)(struct objc_super *, SEL) =
            (id (*)(struct objc_super *, SEL))objc_msgSendSuper;
        CALayer *layer = (CALayer *)castSuperInit(&sup, @selector(init));
        if (!layer) layer = (CALayer *)self;
        layer.contentsGravity = kCAGravityResizeAspectFill;
        layer.backgroundColor = [UIColor blackColor].CGColor;
        @synchronized(gPreviewLayers) {
            [gPreviewLayers addObject:layer];
            if (session) {
                [gPreviewLayerSessions setObject:session forKey:layer];
            }
        }
        HLOG("AVCaptureVideoPreviewLayer initWithSession: registered");
        return (id)layer;
    });

    // Apple's AVCaptureVideoPreviewLayer overrides a bunch of CA hooks
    // (layerDidBecomeVisible:, _layerDidEnterTreeOnDisplay:, layoutSublayers,
    // actionForKey:) and dives into private ivars our bypassed init never
    // populated. Replace each with a no-op or super-forwarding stub.
    simcam_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
                                   @selector(layerDidBecomeVisible:),
                                   ^(CALayer *self, BOOL visible) {
        (void)self; (void)visible;
    });
    {
        SEL enterSel = NSSelectorFromString(@"_layerDidEnterTreeOnDisplay:");
        if ([AVCaptureVideoPreviewLayer instancesRespondToSelector:enterSel]) {
            simcam_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
                                           enterSel,
                                           ^(CALayer *self, id arg) { (void)self; (void)arg; });
        }
    }
    simcam_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
                                   @selector(layoutSublayers),
                                   ^(CALayer *self) { (void)self; });
    simcam_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
                                   @selector(actionForKey:),
                                   ^id(CALayer *self, NSString *k) {
        (void)self; (void)k; return nil;
    });

    // AVCaptureVideoPreviewLayer overrides -setFrame: / -setBounds: /
    // -layoutSublayers and pokes private ivars. Since we never let the
    // real init populate those ivars, every setter explodes. Forward
    // these overrides straight to CALayer's implementations.
    {
        Method src;
        IMP imp;
        Class avc = [AVCaptureVideoPreviewLayer class];
        Class cl  = [CALayer class];

        src = class_getInstanceMethod(cl, @selector(setBounds:));
        imp = method_getImplementation(src);
        method_setImplementation(class_getInstanceMethod(avc, @selector(setBounds:)), imp);

        src = class_getInstanceMethod(cl, @selector(setFrame:));
        imp = method_getImplementation(src);
        method_setImplementation(class_getInstanceMethod(avc, @selector(setFrame:)), imp);

        src = class_getInstanceMethod(cl, @selector(layoutSublayers));
        if (src) {
            imp = method_getImplementation(src);
            Method dst = class_getInstanceMethod(avc, @selector(layoutSublayers));
            if (dst) method_setImplementation(dst, imp);
        }

        src = class_getInstanceMethod(cl, @selector(display));
        if (src) {
            imp = method_getImplementation(src);
            Method dst = class_getInstanceMethod(avc, @selector(display));
            if (dst) method_setImplementation(dst, imp);
        }
    }
    // Some apps use +layerWithSession: which forwards to init; cover both.
    simcam_swizzle_class_method([AVCaptureVideoPreviewLayer class],
                                @selector(layerWithSession:),
                                ^AVCaptureVideoPreviewLayer *(id self, AVCaptureSession *session) {
        AVCaptureVideoPreviewLayer *l = [[AVCaptureVideoPreviewLayer alloc] initWithSession:session];
        return l;
    });

    // The real -setVideoGravity: dives into private state we don't have.
    // Map it to CALayer.contentsGravity which is what we actually render with.
    simcam_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
                                   @selector(setVideoGravity:),
                                   ^(CALayer *self, NSString *gravity) {
        if ([gravity isEqualToString:@"AVLayerVideoGravityResizeAspect"]) {
            self.contentsGravity = kCAGravityResizeAspect;
        } else if ([gravity isEqualToString:@"AVLayerVideoGravityResize"]) {
            self.contentsGravity = kCAGravityResize;
        } else {
            self.contentsGravity = kCAGravityResizeAspectFill;
        }
    });
    simcam_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
                                   @selector(setSession:),
                                   ^(CALayer *self, AVCaptureSession *session) {
        // Track which session this preview layer is observing so we can
        // route only the matching slot's frames to it.
        @synchronized(gPreviewLayers) {
            if (session) {
                [gPreviewLayerSessions setObject:session forKey:self];
            } else {
                [gPreviewLayerSessions removeObjectForKey:self];
            }
        }
    });
    simcam_swizzle_instance_method([AVCaptureVideoPreviewLayer class],
                                   @selector(connection),
                                   ^id(CALayer *self) { (void)self; return nil; });

    // ---------- AVCaptureSession startRunning / stopRunning ----------
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(startRunning),
                                   ^(AVCaptureSession *self) {
        HLOG("AVCaptureSession startRunning (simulated)");
        // ensure puller is alive — it's idempotent
        simcam_start_puller();
    });
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(stopRunning),
                                   ^(AVCaptureSession *self) {
        HLOG("AVCaptureSession stopRunning (simulated)");
    });
    simcam_swizzle_instance_method([AVCaptureSession class],
                                   @selector(isRunning),
                                   ^BOOL(AVCaptureSession *self) { return YES; });

    // ---------- AVCaptureDevice authorizationStatusForMediaType: ----------
    simcam_swizzle_class_method([AVCaptureDevice class],
                                @selector(authorizationStatusForMediaType:),
                                ^AVAuthorizationStatus(id self, AVMediaType mt) {
        return AVAuthorizationStatusAuthorized;
    });
    simcam_swizzle_class_method([AVCaptureDevice class],
                                @selector(requestAccessForMediaType:completionHandler:),
                                ^(id self, AVMediaType mt, void(^done)(BOOL)) {
        if (done) done(YES);
    });
}

// ============================================================
// MARK: - frame puller (unix socket → CVPixelBuffer)
// ============================================================
static int simcam_open_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, SIMCAM_DEFAULT_SOCK, sizeof(addr.sun_path));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static ssize_t simcam_read_full(int fd, void *buf, size_t n) {
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, (uint8_t*)buf + got, n - got);
        if (r <= 0) return r;
        got += (size_t)r;
    }
    return (ssize_t)got;
}

static void simcam_pull_loop(void) {
    uint8_t *payload = NULL;
    size_t   payloadCap = 0;
    while (gPullerRunning) {
        if (gSocketFD < 0) {
            gSocketFD = simcam_open_socket();
            if (gSocketFD < 0) { sleep(1); continue; }
            HLOG("connected to host frame socket fd=%d", gSocketFD);
        }
        SimCamFrameHeader hdr;
        ssize_t r = simcam_read_full(gSocketFD, &hdr, sizeof(hdr));
        if (r != (ssize_t)sizeof(hdr)) { close(gSocketFD); gSocketFD = -1; continue; }
        if (hdr.magic != SIMCAM_FRAME_MAGIC || hdr.version != SIMCAM_FRAME_VERSION) {
            HLOG("bad header magic=0x%x version=%u; reconnecting", hdr.magic, hdr.version);
            close(gSocketFD); gSocketFD = -1; continue;
        }
        size_t need = hdr.payloadLen + hdr.qrPayloadLen;
        if (need > payloadCap) {
            payload = realloc(payload, need);
            payloadCap = need;
        }
        if (need > 0) {
            r = simcam_read_full(gSocketFD, payload, need);
            if (r != (ssize_t)need) { close(gSocketFD); gSocketFD = -1; continue; }
        }

        CVPixelBufferRef pb = simcam_pixelbuffer_from_bgra(
            payload, hdr.width, hdr.height, hdr.bytesPerRow);
        int slot = (hdr.cameraSlot < SIMCAM_SLOT_COUNT)
                   ? (int)hdr.cameraSlot
                   : SIMCAM_SLOT_BACK;
        if (pb) {
            static int sPullCounter[SIMCAM_SLOT_COUNT] = {0,0};
            if ((sPullCounter[slot]++ % 60) == 0) {
                HLOG("pulled frame slot=%d %ux%u qrLen=%u",
                     slot, hdr.width, hdr.height, hdr.qrPayloadLen);
            }
            pthread_mutex_lock(&gFrameLock);
            if (gLatestPixelBuffer[slot]) CFRelease(gLatestPixelBuffer[slot]);
            gLatestPixelBuffer[slot] = pb; // retained
            gLatestHostTime[slot] = hdr.hostTimeNs;
            pthread_mutex_unlock(&gFrameLock);
            simcam_dispatch_sample(slot, pb, hdr.hostTimeNs);
            simcam_render_preview(slot, pb);
        }
        if (hdr.qrPayloadLen > 0) {
            NSString *qr = [[NSString alloc] initWithBytes:payload + hdr.payloadLen
                                                    length:hdr.qrPayloadLen
                                                  encoding:NSUTF8StringEncoding];
            if (qr) {
                pthread_mutex_lock(&gFrameLock);
                gLatestQRPayload[slot] = [qr copy];
                pthread_mutex_unlock(&gFrameLock);
                simcam_dispatch_metadata(slot, qr);
            }
        }
    }
    free(payload);
}

static void simcam_start_puller(void) {
    if (gPullerRunning) return;
    gPullerRunning = YES;
    dispatch_async(gPullerQueue, ^{ simcam_pull_loop(); });
}

// ============================================================
// MARK: - sample buffer construction
// ============================================================
static CVPixelBufferRef simcam_pixelbuffer_from_bgra(const uint8_t *bytes,
                                                    uint32_t width,
                                                    uint32_t height,
                                                    uint32_t bytesPerRow) {
    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
    };
    CVPixelBufferRef pb = NULL;
    CVReturn rv = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                      kCVPixelFormatType_32BGRA,
                                      (__bridge CFDictionaryRef)attrs, &pb);
    if (rv != kCVReturnSuccess || !pb) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    uint8_t *dst = CVPixelBufferGetBaseAddress(pb);
    size_t dstStride = CVPixelBufferGetBytesPerRow(pb);
    size_t copyW = MIN((size_t)bytesPerRow, dstStride);
    for (uint32_t y = 0; y < height; y++) {
        memcpy(dst + y * dstStride, bytes + (size_t)y * bytesPerRow, copyW);
    }
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static void simcam_dispatch_sample(int slot, CVPixelBufferRef pb, uint64_t hostTimeNs) {
    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt);
    if (!fmt) return;
    CMSampleTimingInfo timing = {
        .duration = CMTimeMake(1, 30),
        .presentationTimeStamp = CMTimeMake((int64_t)(hostTimeNs / 1000), 1000000),
        .decodeTimeStamp = kCMTimeInvalid
    };
    CMSampleBufferRef sb = NULL;
    OSStatus s = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pb,
                                                    true, NULL, NULL, fmt,
                                                    &timing, &sb);
    CFRelease(fmt);
    if (s != noErr || !sb) return;

    NSArray<SimCamSBDelegateEntry *> *snapshot;
    @synchronized(gSBDelegates) { snapshot = [gSBDelegates copy]; }
    for (SimCamSBDelegateEntry *e in snapshot) {
        id<AVCaptureVideoDataOutputSampleBufferDelegate> d = e.delegate;
        AVCaptureVideoDataOutput *out = e.output;
        if (!d || !out) continue;
        if (![d respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) continue;
        // Only fan out to delegates whose output is wired to a session
        // bound to the same slot we just received a frame for. Resolve
        // session via the association we set in addOutput:. A slot of -1
        // means the resolver couldn't determine the output's slot
        // (transient empty inputs window) — safer to drop the frame
        // than guess and visually flash the wrong camera.
        AVCaptureSession *session = objc_getAssociatedObject(out, "simcam.session");
        int outSlot = simcam_session_slot(session);
        if (outSlot < 0 || outSlot != slot) continue;
        AVCaptureConnection *conn = out.connections.firstObject;
        CFRetain(sb);
        dispatch_async(e.queue, ^{
            [d captureOutput:out didOutputSampleBuffer:sb fromConnection:conn];
            CFRelease(sb);
        });
    }
    CFRelease(sb);
}

static void simcam_dispatch_metadata(int slot, NSString *payload) {
    NSArray<SimCamMetaDelegateEntry *> *snapshot;
    @synchronized(gMetaDelegates) { snapshot = [gMetaDelegates copy]; }
    for (SimCamMetaDelegateEntry *e in snapshot) {
        id<AVCaptureMetadataOutputObjectsDelegate> d = e.delegate;
        AVCaptureMetadataOutput *out = e.output;
        if (!d || !out) continue;

        // Filter by slot — only emit to outputs whose session is bound
        // to the slot we received a QR payload for. Skip when slot
        // can't be resolved (-1).
        AVCaptureSession *session = objc_getAssociatedObject(out, "simcam.session");
        int outSlot = simcam_session_slot(session);
        if (outSlot < 0 || outSlot != slot) continue;

        if ([e.lastEmitted isEqualToString:payload]) continue;
        e.lastEmitted = payload;

        // Build an AVMetadataMachineReadableCodeObject via private impl is
        // brittle; instead vend a minimal subclass that exposes
        // .stringValue / .type. Most apps use only those two.
        AVMetadataObject *fake = [SimCamFakeMetadata withPayload:payload];
        dispatch_async(e.queue, ^{
            if ([d respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) {
                AVCaptureConnection *conn = out.connections.firstObject;
                [d captureOutput:out didOutputMetadataObjects:@[fake] fromConnection:conn];
            }
        });
    }
}

static void simcam_render_preview(int slot, CVPixelBufferRef pb) {
    // Hand the IOSurface-backed CVPixelBuffer directly to CALayer.contents.
    // CoreAnimation natively understands IOSurface and will zero-copy it to
    // the screen. This avoids:
    //   * CIContext + createCGImage (which on the iOS Simulator's Metal
    //     backend hits a "MTLSimTexture getBytes" readback that crashes
    //     because the texture wasn't created with shaderRead usage).
    //   * The expensive per-frame CPU readback in general.
    // We still filter by slot using the previewLayer<->session association.
    if (!pb) return;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pb);
    if (!surface) {
        // No IOSurface — fall back silently. (Pixel buffers we receive over
        // the unix socket are decoded with kCVPixelBufferIOSurfacePropertiesKey
        // so this should be very rare.)
        return;
    }
    NSMutableArray<CALayer *> *matched = [NSMutableArray new];
    @synchronized(gPreviewLayers) {
        for (CALayer *l in gPreviewLayers.allObjects) {
            AVCaptureSession *session = [gPreviewLayerSessions objectForKey:l];
            int layerSlot = simcam_session_slot(session);
            // Skip layers whose slot can't currently be resolved (-1
            // means the session has no input right now). Routing a
            // frame to such a layer would default-flash the wrong
            // camera into the layer's contents.
            if (layerSlot < 0) continue;
            if (layerSlot == slot) [matched addObject:l];
        }
    }
    static int sLogCounter[SIMCAM_SLOT_COUNT] = {0,0};
    if ((sLogCounter[slot]++ % 60) == 0) {
        HLOG("render_preview slot=%d matched=%lu (layers=%lu)",
             slot, (unsigned long)matched.count,
             (unsigned long)gPreviewLayers.allObjects.count);
    }
    if (matched.count == 0) return;
    // Retain the surface across the dispatch; CALayer keeps a reference for
    // the duration that contents points at it.
    CFRetain(surface);
    dispatch_async(dispatch_get_main_queue(), ^{
        for (CALayer *l in matched) {
            l.contents = (__bridge id)surface;
            l.contentsGravity = kCAGravityResizeAspectFill;
        }
        CFRelease(surface);
    });
}

// ============================================================
// MARK: - fake metadata object
// ============================================================
@implementation SimCamFakeMetadata {
    NSString *_payload;
}
+ (instancetype)withPayload:(NSString *)payload {
    SimCamFakeMetadata *m = [self alloc];
    m->_payload = [payload copy];
    return m;
}
- (NSString *)stringValue { return _payload; }
- (AVMetadataObjectType)type { return AVMetadataObjectTypeQRCode; }
- (CGRect)bounds { return CGRectMake(0, 0, 100, 100); }
@end
