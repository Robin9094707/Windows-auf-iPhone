#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>

#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#include "fb_display.h"

/* Sharp upscaling: 9-tap Catmull-Rom bicubic (identity when the scale is 1:1). */
static NSString *const kFbShaderSharp =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut {\n"
     "    float4 pos [[position]];\n"
     "    float2 uv;\n"
     "};\n"
     "vertex VOut fb_vs(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {\n"
     "    const float2 quad[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "    const float2 uvs[4]  = { float2(0,1),   float2(1,1),  float2(0,0),  float2(1,0) };\n"
     "    VOut o;\n"
     "    o.pos = float4(quad[vid] * scale, 0.0, 1.0);\n"
     "    o.uv  = uvs[vid];\n"
     "    return o;\n"
     "}\n"
     "fragment float4 fb_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
     "    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);\n"
     "    float2 size = float2(tex.get_width(), tex.get_height());\n"
     "    float2 p = in.uv * size;\n"
     "    float2 t1 = floor(p - 0.5) + 0.5;\n"
     "    float2 f = p - t1;\n"
     "    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));\n"
     "    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);\n"
     "    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));\n"
     "    float2 w3 = f * f * (-0.5 + 0.5 * f);\n"
     "    float2 w12 = w1 + w2;\n"
     "    float2 t0 = (t1 - 1.0) / size;\n"
     "    float2 t3 = (t1 + 2.0) / size;\n"
     "    float2 t12 = (t1 + w2 / w12) / size;\n"
     "    float3 c = tex.sample(s, float2(t0.x,  t0.y)).rgb  * (w0.x  * w0.y)\n"
     "             + tex.sample(s, float2(t12.x, t0.y)).rgb  * (w12.x * w0.y)\n"
     "             + tex.sample(s, float2(t3.x,  t0.y)).rgb  * (w3.x  * w0.y)\n"
     "             + tex.sample(s, float2(t0.x,  t12.y)).rgb * (w0.x  * w12.y)\n"
     "             + tex.sample(s, float2(t12.x, t12.y)).rgb * (w12.x * w12.y)\n"
     "             + tex.sample(s, float2(t3.x,  t12.y)).rgb * (w3.x  * w12.y)\n"
     "             + tex.sample(s, float2(t0.x,  t3.y)).rgb  * (w0.x  * w3.y)\n"
     "             + tex.sample(s, float2(t12.x, t3.y)).rgb  * (w12.x * w3.y)\n"
     "             + tex.sample(s, float2(t3.x,  t3.y)).rgb  * (w3.x  * w3.y);\n"
     "    return float4(saturate(c), 1.0);\n"
     "}\n";

static NSString *const kFbShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut {\n"
     "    float4 pos [[position]];\n"
     "    float2 uv;\n"
     "};\n"
     "vertex VOut fb_vs(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {\n"
     "    const float2 quad[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "    const float2 uvs[4]  = { float2(0,1),   float2(1,1),  float2(0,0),  float2(1,0) };\n"
     "    VOut o;\n"
     "    o.pos = float4(quad[vid] * scale, 0.0, 1.0);\n"
     "    o.uv  = uvs[vid];\n"
     "    return o;\n"
     "}\n"
     "fragment float4 fb_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
     "    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);\n"
     "    float4 c = tex.sample(s, in.uv);\n"
     "    return float4(c.rgb, 1.0);\n"
     "}\n";

@interface HvFbMetalPresenter : NSObject {
@public
    HvFbDisplay *fb;
    os_unfair_lock lock;
    CAMetalLayer *layer;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLTexture> texture;
    uint32_t texW, texH;
    dispatch_source_t timer;
    _Atomic(uint64_t) framesPresented;
    BOOL forceFull;
    BOOL pendingPresent;      /* changes uploaded but not yet presented (no drawable) */
    CGSize lastDrawableSize;
    uint8_t *shadow;          /* last uploaded frame, to find changed bands */
    size_t shadowLen;
    uint32_t shadowStride;
}
- (instancetype)initWithDisplay:(HvFbDisplay *)display;
- (void)setTargetLayer:(CAMetalLayer *)newLayer;
- (void)tick;
@end

@implementation HvFbMetalPresenter

- (instancetype)initWithDisplay:(HvFbDisplay *)display {
    if ((self = [super init])) {
        fb = display;
        lock = OS_UNFAIR_LOCK_INIT;
        device = MTLCreateSystemDefaultDevice();
        if (device) {
            queue = [device newCommandQueue];
            /* Sharp bicubic first; plain bilinear if that fails to compile on this GPU. */
            NSArray<NSString *> *sources = @[kFbShaderSharp, kFbShaderSource];
            for (NSString *src in sources) {
                NSError *err = nil;
                id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
                if (!lib) continue;
                MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
                pd.vertexFunction = [lib newFunctionWithName:@"fb_vs"];
                pd.fragmentFunction = [lib newFunctionWithName:@"fb_fs"];
                pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
                if (pipeline) break;
            }
        }
    }
    return self;
}

- (void)setTargetLayer:(CAMetalLayer *)newLayer {
    os_unfair_lock_lock(&lock);
    layer = newLayer;
    forceFull = YES;
    lastDrawableSize = CGSizeZero;
    if (layer && device) {
        dispatch_block_t cfg = ^{
            newLayer.device = self->device;
            newLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            newLayer.framebufferOnly = YES;
        };
        if ([NSThread isMainThread]) cfg();
        else dispatch_async(dispatch_get_main_queue(), cfg);

        if (!timer) {
            dispatch_queue_t q = dispatch_queue_create("me.ammaar.windowsios.fbmetal", DISPATCH_QUEUE_SERIAL);
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
#if TARGET_OS_IPHONE
            /* ProMotion: present up to 120 Hz (unchanged frames cost only a memcmp). */
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 120, 1 * NSEC_PER_MSEC);
#else
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, 2 * NSEC_PER_MSEC);
#endif
            __weak HvFbMetalPresenter *weakSelf = self;
            dispatch_source_set_event_handler(timer, ^{
                [weakSelf tick];
            });
            dispatch_resume(timer);
        }
    } else if (!layer && timer) {
        dispatch_source_cancel(timer);
        timer = nil;
    }
    os_unfair_lock_unlock(&lock);
}

- (void)tick {
    @autoreleasepool {
        const uint8_t *px = NULL;
        uint32_t w = 0, h = 0, stride = 0;
        if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0) return;

        os_unfair_lock_lock(&lock);
        CAMetalLayer *curLayer = layer;
        if (!curLayer || !device || !pipeline || !queue) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        CGSize dsize = curLayer.drawableSize;
        if (dsize.width < 4 || dsize.height < 4) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        BOOL sizeChanged = !CGSizeEqualToSize(dsize, lastDrawableSize);
        BOOL full = forceFull || sizeChanged;

        if (!texture || texW != w || texH != h) {
            full = YES;
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                          width:w
                                                                                         height:h
                                                                                      mipmapped:NO];
            td.usage = MTLTextureUsageShaderRead;
            texture = [device newTextureWithDescriptor:td];
            texW = w;
            texH = h;
        }

        /* Compare the whole frame in 16-row bands against what was uploaded last time and
           upload only the changed runs – nothing (cursor, caret) is missed, little is copied. */
        size_t need = (size_t)stride * h;
        if (!shadow || shadowLen != need || shadowStride != stride) {
            free(shadow);
            shadow = malloc(need);
            shadowLen = shadow ? need : 0;
            shadowStride = stride;
            full = YES;
        }
        if (!shadow) {
            os_unfair_lock_unlock(&lock);
            return;
        }
        const uint32_t band = 16;
        BOOL dirty = NO;
        uint32_t runStart = UINT32_MAX;
        for (uint32_t y = 0;; y += band) {
            BOOL atEnd = y >= h;
            BOOL changed = NO;
            if (!atEnd) {
                uint32_t rows = h - y < band ? h - y : band;
                size_t off = (size_t)y * stride, len = (size_t)rows * stride;
                if (full || memcmp(px + off, shadow + off, len) != 0) {
                    memcpy(shadow + off, px + off, len);
                    changed = YES;
                }
            }
            if (changed && runStart == UINT32_MAX) runStart = y;
            if (!changed && runStart != UINT32_MAX) {
                uint32_t end = atEnd ? h : y;
                [texture replaceRegion:MTLRegionMake2D(0, runStart, w, end - runStart)
                           mipmapLevel:0
                             withBytes:shadow + (size_t)runStart * stride
                           bytesPerRow:stride];
                runStart = UINT32_MAX;
                dirty = YES;
            }
            if (atEnd) break;
        }
        if (!dirty && !full && !pendingPresent) {
            os_unfair_lock_unlock(&lock);
            return;
        }
        forceFull = NO;

        id<CAMetalDrawable> drawable = [curLayer nextDrawable];
        if (!drawable) {
            pendingPresent = YES;
            os_unfair_lock_unlock(&lock);
            return;
        }
        pendingPresent = NO;

        float dstAspect = (float)(dsize.width / dsize.height);
        float srcAspect = (float)w / (float)h;
        float scale[2] = {1.0f, 1.0f};
        if (dstAspect > srcAspect) {
            scale[0] = srcAspect / dstAspect;
        } else {
            scale[1] = dstAspect / srcAspect;
        }

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipeline];
        [enc setVertexBytes:scale length:sizeof(scale) atIndex:0];
        [enc setFragmentTexture:texture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];

        lastDrawableSize = dsize;
        atomic_fetch_add_explicit(&framesPresented, 1, memory_order_relaxed);
        os_unfair_lock_unlock(&lock);
    }
}

@end

static HvFbMetalPresenter *ensure_presenter(HvFbDisplay *fb) {
    if (!fb) return nil;
    pthread_mutex_lock(&fb->mu);
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    if (!p) {
        p = [[HvFbMetalPresenter alloc] initWithDisplay:fb];
        fb->metal = (__bridge_retained void *)p;
    }
    pthread_mutex_unlock(&fb->mu);
    return p;
}

void hv_fb_metal_set_layer(HvFbDisplay *fb, void *ca_metal_layer) {
    HvFbMetalPresenter *p = ensure_presenter(fb);
    if (!p) return;
    [p setTargetLayer:(__bridge CAMetalLayer *)ca_metal_layer];
}

uint64_t hv_fb_metal_frames(HvFbDisplay *fb) {
    if (!fb || !fb->metal) return 0;
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    return atomic_load_explicit(&p->framesPresented, memory_order_relaxed);
}

int hv_fb_save_png(HvFbDisplay *fb, const char *path) {
    if (!fb || !path) return -1;
    const uint8_t *px = NULL;
    uint32_t w = 0, h = 0, stride = 0;
    if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0) return -1;

    @autoreleasepool {
        size_t total = (size_t)stride * h;
        uint8_t *copy = malloc(total);
        if (!copy) return -1;
        memcpy(copy, px, total);
        /* Ensure alpha byte is 0xff (XRGB8888 leaves X=0x00) */
        for (uint32_t y = 0; y < h; y++) {
            uint8_t *row = copy + (size_t)y * stride;
            for (uint32_t x = 0; x < w; x++) row[x * 4 + 3] = 0xff;
        }

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, copy, total, NULL);
        CGBitmapInfo bmi = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
        CGImageRef img = CGImageCreate(w, h, 8, 32, stride, cs, bmi, prov, NULL, false, kCGRenderingIntentDefault);
        int rc = -1;
        if (img) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            if (dst) {
                CGImageDestinationAddImage(dst, img, NULL);
                if (CGImageDestinationFinalize(dst)) rc = 0;
                CFRelease(dst);
            }
            CGImageRelease(img);
        }
        CGDataProviderRelease(prov);
        CGColorSpaceRelease(cs);
        free(copy);
        return rc;
    }
}
