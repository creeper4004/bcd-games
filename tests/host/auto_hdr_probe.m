// SPDX-License-Identifier: GPL-3.0-only
// Exercise the production sampler on real floating-point CAMetalDrawables.
#import "BCDHDR.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <assert.h>
#import <math.h>

static BCDHDRSnapshot sample(id<MTLCommandQueue> queue, CAMetalLayer *layer,
                             double value, BOOL stale) {
    bcd_hdr_set_probe(0); bcd_hdr_set_probe(1); // new revision, no rate-limit wait
    uint32_t revision;
    bcd_hdr_control_get(&revision);
    id<CAMetalDrawable> drawable = [layer nextDrawable]; assert(drawable);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(value, value / 2, 0, 1);
    [[cb renderCommandEncoderWithDescriptor:pass] endEncoding];
    bcd_hdr_tag_drawable((uint64_t)(__bridge void *)drawable, revision, 9, 2);
    bcd_hdr_probe_encode((uint64_t)(__bridge void *)cb, (uint64_t)(__bridge void *)drawable);
    if (stale) bcd_hdr_set_enabled(0);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> finished) { dispatch_semaphore_signal(done); }];
    [cb commit];
    assert(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC)) == 0);
    assert(cb.status == MTLCommandBufferStatusCompleted);
    BCDHDRSnapshot result; bcd_hdr_read(&result); return result;
}
int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    CAMetalLayer *layer = [CAMetalLayer layer]; layer.device = device;
    layer.pixelFormat = MTLPixelFormatRGBA16Float; layer.framebufferOnly = NO;
    layer.drawableSize = CGSizeMake(128, 72); layer.wantsExtendedDynamicRangeContent = YES;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    layer.colorspace = cs; CGColorSpaceRelease(cs);
    bcd_hdr_reset();
    BCDHDRSnapshot hdr = sample(queue, layer, 1.5, NO);
    assert(hdr.valid && hdr.prepared && hdr.samples == 2304 && hdr.above_sdr == 2304);
    assert(fabsf(hdr.peak - 1.5f) < 0.001 && hdr.invalid == 0 && hdr.error == 0);
    assert(hdr.edr && hdr.linear && hdr.pixel_format == MTLPixelFormatRGBA16Float);
    assert(hdr.headroom == 1); // detached layer must not claim a physical HDR display
    BCDHDRSnapshot sdr = sample(queue, layer, 1, NO);
    assert(sdr.valid && sdr.samples == 2304 && sdr.above_sdr == 0 && sdr.peak == 1);
    BCDHDRSnapshot stale = sample(queue, layer, 2, YES);
    assert(!stale.valid && !(stale.flags & BCD_HDR_ENABLED));
    bcd_hdr_reset(); BCDHDRSnapshot reset; bcd_hdr_read(&reset);
    assert(!reset.valid && !reset.prepared && reset.flags == BCD_HDR_ENABLED);
    puts("PASS: production GPU probe: actual HDR/SDR drawable pixels, layer metadata, stale-frame rejection, session reset");
} }
