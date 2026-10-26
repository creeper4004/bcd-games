// SPDX-License-Identifier: GPL-3.0-only
#import "BCDHDR.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif
#import <objc/runtime.h>
#include <stdatomic.h>
#include <pthread.h>
#include <time.h>
#include <math.h>

NSNotificationName const BCDHDRChangedNotification = @"BCDHDRChanged";
static _Atomic uint32_t g_flags = BCD_HDR_ENABLED, g_revision = 1;
static _Atomic int g_busy;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static BCDHDRSnapshot g_reading;
static uint64_t g_owner, g_owner_area, g_seen, g_last_probe, g_last_log;
static id<MTLDevice> g_device;
static id<MTLComputePipelineState> g_pipeline;
static char g_tag_key;

@interface BCDHDRTag : NSObject
@property(nonatomic) uint32_t revision, flags;
@property(nonatomic) float peak;
@end
@implementation BCDHDRTag
@end

static uint64_t hdr_now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec;
}
static void hdr_notify(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:BCDHDRChangedNotification object:nil];
    });
}
void bcd_hdr_read(BCDHDRSnapshot *out) {
    if (!out) return;
    pthread_mutex_lock(&g_lock); *out = g_reading;
    out->flags = atomic_load(&g_flags); out->revision = atomic_load(&g_revision);
    pthread_mutex_unlock(&g_lock);
}
void bcd_hdr_reset(void) {
    pthread_mutex_lock(&g_lock);
    atomic_fetch_add(&g_revision, 1); atomic_store(&g_flags, BCD_HDR_ENABLED);
    g_reading = (BCDHDRSnapshot){0}; g_owner = g_owner_area = g_seen = g_last_probe = g_last_log = 0;
    pthread_mutex_unlock(&g_lock); hdr_notify();
}
static void hdr_set(uint32_t flag, int on) {
    pthread_mutex_lock(&g_lock);
    uint32_t old = atomic_load(&g_flags), next = on ? old | flag : old & ~flag;
    if (old == next) { pthread_mutex_unlock(&g_lock); return; }
    atomic_store(&g_flags, next); atomic_fetch_add(&g_revision, 1);
    g_reading.valid = 0; g_reading.error = 0; g_last_probe = g_last_log = 0;
    pthread_mutex_unlock(&g_lock); hdr_notify();
}
void bcd_hdr_set_enabled(int on) { hdr_set(BCD_HDR_ENABLED, on); }
void bcd_hdr_set_pattern(int on) { hdr_set(BCD_HDR_PATTERN, on); }
void bcd_hdr_set_probe(int on) { hdr_set(BCD_HDR_PROBE, on); }
uint32_t bcd_hdr_control_get(uint32_t *revision) {
    pthread_mutex_lock(&g_lock);
    *revision = atomic_load(&g_revision);
    uint32_t reply = 0x48445200u | atomic_load(&g_flags);
    pthread_mutex_unlock(&g_lock);
    return reply; // versioned reply; zero means an older backend
}

void bcd_hdr_tag_drawable(uint64_t handle, uint32_t revision, uint32_t flags, float peak) {
    id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)(void *)(uintptr_t)handle;
    if (!drawable || revision != atomic_load(&g_revision)) return;
    uint64_t layer = (uint64_t)(uintptr_t)(__bridge void *)drawable.layer;
    uint64_t area = (uint64_t)drawable.texture.width * drawable.texture.height, now = hdr_now();
    pthread_mutex_lock(&g_lock);
    if (revision != atomic_load(&g_revision)) { pthread_mutex_unlock(&g_lock); return; }
    // Ignore smaller launcher/helper swapchains while the game's layer is presenting.
    if (g_owner && layer != g_owner && area < g_owner_area && now - g_seen < 2000000000ull) {
        pthread_mutex_unlock(&g_lock); return;
    }
    int notify = g_reading.prepared != !!(flags & BCD_HDR_ELIGIBLE) || layer != g_owner;
    if (notify) { g_reading.valid = 0; g_reading.error = 0; }
    g_owner = layer; g_owner_area = area; g_seen = now;
    g_reading.prepared = !!(flags & BCD_HDR_ELIGIBLE);
    pthread_mutex_unlock(&g_lock);
    if (notify) hdr_notify();
    if (atomic_load(&g_flags) & BCD_HDR_PROBE) {
        BCDHDRTag *tag = [BCDHDRTag new]; tag.revision = revision; tag.flags = flags; tag.peak = peak;
        objc_setAssociatedObject(drawable, &g_tag_key, tag, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static float hdr_headroom(CAMetalLayer *layer) {
    __block float value = 1;
    void (^read)(void) = ^{
        for (CALayer *p = layer; p; p = p.superlayer) {
#if TARGET_OS_IOS
            if ([p.delegate isKindOfClass:UIView.class]) {
                UIScreen *screen = ((UIView *)p.delegate).window.windowScene.screen;
                if (screen) { value = fmaxf(1, screen.currentEDRHeadroom); break; }
            }
#else
            if ([p.delegate isKindOfClass:NSView.class]) {
                NSScreen *screen = ((NSView *)p.delegate).window.screen;
                if (screen) { value = fmaxf(1, screen.maximumExtendedDynamicRangeColorComponentValue); break; }
            }
#endif
        }
    };
    if ([NSThread isMainThread]) read(); else dispatch_sync(dispatch_get_main_queue(), read);
    return value;
}

// Uniform sampling of 2,304 pixels of the actual game drawable, at most twice
// a second. Positive samples prove an HDR signal; zero cannot rule out tiny
// highlights between the sample points. UIKit's HUD/menu is outside this texture.
static NSString *const hdr_msl = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct Stats { atomic_uint peak, above, finite, invalid; };\n"
"kernel void hdr_sample(texture2d<float, access::read> src [[texture(0)]],\n"
" device Stats &out [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {\n"
" uint2 p = min(uint2(src.get_width()-1, src.get_height()-1),\n"
"   uint2((float2(gid)+0.5f)*float2(src.get_width(),src.get_height())/float2(64,36)));\n"
" float3 c = src.read(p).rgb;\n"
" if (!all(isfinite(c))) { atomic_fetch_add_explicit(&out.invalid,1u,memory_order_relaxed); return; }\n"
" float peak = max(0.0f,max(c.r,max(c.g,c.b)));\n"
" atomic_fetch_max_explicit(&out.peak,as_type<uint>(peak),memory_order_relaxed);\n"
" atomic_fetch_add_explicit(&out.finite,1u,memory_order_relaxed);\n"
" if (peak>1.001f) atomic_fetch_add_explicit(&out.above,1u,memory_order_relaxed);\n"
"}\n";

void bcd_hdr_probe_encode(uint64_t cb_handle, uint64_t drawable_handle) {
    if (!(atomic_load(&g_flags) & BCD_HDR_PROBE)) return;
    id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)(void *)(uintptr_t)drawable_handle;
    id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)(void *)(uintptr_t)cb_handle;
    BCDHDRTag *tag = objc_getAssociatedObject(drawable, &g_tag_key);
    if (!tag || !(tag.flags & BCD_HDR_ELIGIBLE) || tag.revision != atomic_load(&g_revision)) return;
    CAMetalLayer *layer = drawable.layer;
    uint64_t owner = (uint64_t)(uintptr_t)(__bridge void *)layer, now = hdr_now();
    pthread_mutex_lock(&g_lock);
    int due = owner == g_owner && (g_last_probe == 0 || now - g_last_probe >= 500000000ull);
    pthread_mutex_unlock(&g_lock);
    int idle = 0;
    if (!due || !atomic_compare_exchange_strong(&g_busy, &idle, 1)) return;
    pthread_mutex_lock(&g_lock); g_last_probe = now; pthread_mutex_unlock(&g_lock);
    id<MTLTexture> texture = drawable.texture;
    if (layer.framebufferOnly || texture.pixelFormat != MTLPixelFormatRGBA16Float) {
        pthread_mutex_lock(&g_lock); g_reading.error = 1; pthread_mutex_unlock(&g_lock);
        atomic_store(&g_busy, 0); hdr_notify(); return;
    }
    if (g_device != texture.device || !g_pipeline) {
        g_device = texture.device;
        NSError *error = nil;
        MTLCompileOptions *options = [MTLCompileOptions new]; options.languageVersion = MTLLanguageVersion3_1;
        id<MTLLibrary> library = [g_device newLibraryWithSource:hdr_msl options:options error:&error];
        g_pipeline = library ? [g_device newComputePipelineStateWithFunction:[library newFunctionWithName:@"hdr_sample"] error:&error] : nil;
        if (!g_pipeline) {
            fprintf(stderr, "[hdr-signal] probe compilation failed: %s\n", error.localizedDescription.UTF8String);
            pthread_mutex_lock(&g_lock); g_reading.error = 2; pthread_mutex_unlock(&g_lock);
            atomic_store(&g_busy, 0); hdr_notify(); return;
        }
    }
    id<MTLBuffer> data = [g_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    if (!data) { atomic_store(&g_busy, 0); return; }
    memset(data.contents, 0, 16);
    float headroom = hdr_headroom(layer);
    CFStringRef name = layer.colorspace ? CGColorSpaceCopyName(layer.colorspace) : NULL;
    BOOL linear = name && CFEqual(name, kCGColorSpaceExtendedLinearSRGB);
    if (name) CFRelease(name);
    BCDHDRSnapshot snapshot = {0};
    snapshot.applied_flags = tag.flags; snapshot.applied_peak = tag.peak;
    snapshot.revision = tag.revision; snapshot.headroom = headroom;
    snapshot.edr = layer.wantsExtendedDynamicRangeContent; snapshot.linear = linear;
    snapshot.pixel_format = (uint32_t)texture.pixelFormat;
    snapshot.width = (uint32_t)texture.width; snapshot.height = (uint32_t)texture.height;
    id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder];
    if (!encoder) { atomic_store(&g_busy, 0); return; }
    encoder.label = @"BCD HDR signal sample";
    [encoder setComputePipelineState:g_pipeline]; [encoder setTexture:texture atIndex:0]; [encoder setBuffer:data offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(64,36,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [encoder endEncoding];
    pthread_mutex_lock(&g_lock); g_last_probe = now; pthread_mutex_unlock(&g_lock);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        BCDHDRSnapshot result = snapshot;
        if (finished.status == MTLCommandBufferStatusCompleted) {
            uint32_t *values = data.contents;
            memcpy(&result.peak, &values[0], sizeof(float));
            result.above_sdr = values[1]; result.samples = values[2]; result.invalid = values[3];
            result.valid = 1; result.sample_ns = hdr_now();
        } else result.error = 3;
        pthread_mutex_lock(&g_lock);
        BOOL current = tag.revision == atomic_load(&g_revision) && owner == g_owner;
        if (current) {
            result.prepared = g_reading.prepared; g_reading = result;
            if (result.valid && (g_last_log == 0 || result.sample_ns - g_last_log >= 5000000000ull)) {
                g_last_log = result.sample_ns;
                fprintf(stderr, "[hdr-signal] view=%s pattern=%u edr=%u linear=%u format=%u headroom=%.3f peak=%.3f above=%u/%u invalid=%u size=%ux%u\n",
                        tag.flags & BCD_HDR_ENABLED ? "HDR" : "SDR", !!(tag.flags & BCD_HDR_PATTERN), result.edr, result.linear,
                        result.pixel_format, result.headroom, result.peak, result.above_sdr, result.samples, result.invalid, result.width, result.height);
            }
        }
        pthread_mutex_unlock(&g_lock);
        atomic_store(&g_busy, 0);
        if (current) hdr_notify();
    }];
}
