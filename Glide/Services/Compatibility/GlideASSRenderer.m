#import "GlideASSRenderer.h"
#import "Vendor/libass/ass.h"

@interface GlideASSFrame ()
@property(nonatomic) BOOL changed;
@property(nonatomic, nullable) UIImage *image;
@property(nonatomic) CGRect rect;
@property(nonatomic) NSUInteger imageCount;
@end
@implementation GlideASSFrame
@end

static double bounded(double v) { return MAX(0.0, MIN(1.0, v)); }
static void assColour(uint32_t colour, ASS_YCbCrMatrix matrix, NSString *videoMatrix, int height, int *r, int *g, int *b) {
    *r = colour >> 24; *g = (colour >> 16) & 255; *b = (colour >> 8) & 255;
    if (matrix == YCBCR_NONE || [videoMatrix isEqualToString:@"hdr"] || [videoMatrix containsString:@"2020"] || [videoMatrix isEqualToString:@"rgb"]) return;
    double kr = 0.299, kb = 0.114; BOOL tv = YES;
    switch (matrix) {
        case YCBCR_BT709_TV: case YCBCR_BT709_PC: kr = 0.2126; kb = 0.0722; break;
        case YCBCR_SMPTE240M_TV: case YCBCR_SMPTE240M_PC: kr = 0.212; kb = 0.087; break;
        case YCBCR_FCC_TV: case YCBCR_FCC_PC: kr = 0.30; kb = 0.11; break;
        default: break;
    }
    tv = matrix != YCBCR_BT601_PC && matrix != YCBCR_BT709_PC && matrix != YCBCR_SMPTE240M_PC && matrix != YCBCR_FCC_PC;
    double rr = *r / 255.0, gg = *g / 255.0, bb = *b / 255.0;
    double y = kr * rr + (1 - kr - kb) * gg + kb * bb;
    double cb = (bb - y) / (2 * (1 - kb)), cr = (rr - y) / (2 * (1 - kr));
    if (!tv) { y = (255 * y - 16) / 219; cb *= 255.0 / 224; cr *= 255.0 / 224; }
    BOOL sd = [videoMatrix isEqualToString:@"bt470bg"] || [videoMatrix isEqualToString:@"smpte170m"] || (videoMatrix.length == 0 && height <= 576);
    double outKr = sd ? 0.299 : 0.2126, outKb = sd ? 0.114 : 0.0722;
    if ([videoMatrix isEqualToString:@"smpte240m"]) { outKr = 0.212; outKb = 0.087; }
    rr = y + 2 * (1 - outKr) * cr; bb = y + 2 * (1 - outKb) * cb;
    gg = (y - outKr * rr - outKb * bb) / (1 - outKr - outKb);
    *r = (int)lrint(bounded(rr) * 255); *g = (int)lrint(bounded(gg) * 255); *b = (int)lrint(bounded(bb) * 255);
}
@interface GlideASSRenderer ()
- (void)noteSelectedPostScript:(const char *)name;
@end

static void silentASSLog(int level, const char *format, va_list args, void *data) {
    // Inspect only this exact format in the pinned public logger callback. Never
    // format or export other log messages, which may contain private dialogue.
    if (!data || strcmp(format, "fontselect: (%s, %d, %d) -> %s, %d, %s") != 0) return;
    va_list copy; va_copy(copy, args);
    (void)va_arg(copy, const char *); (void)va_arg(copy, int); (void)va_arg(copy, int);
    (void)va_arg(copy, const char *); (void)va_arg(copy, int);
    const char *postScript = va_arg(copy, const char *);
    [(__bridge GlideASSRenderer *)data noteSelectedPostScript:postScript];
    va_end(copy);
}
@implementation GlideASSRenderer {
    ASS_Library *_library;
    ASS_Renderer *_renderer;
    ASS_Track *_track;
    int _width, _height, _sourceWidth, _sourceHeight;
    NSString *_videoMatrix;
    BOOL _matrixChanged;
    NSMutableSet<NSString *> *_selectedNames;
}
- (instancetype)initWithScript:(NSData *)script fonts:(NSArray<NSData *> *)fonts fallbackPath:(NSString *)fallbackPath {
    self = [super init];
    if (!self) return nil;
    // Both fixed MobileVLCKit slices ship this ABI. Never guess on SDK upgrades.
    if (ass_library_version() != LIBASS_VERSION || script.length > 2000000) return nil;
    _library = ass_library_init();
    if (!_library) return nil;
    _selectedNames = [NSMutableSet new];
    ass_set_message_cb(_library, silentASSLog, (__bridge void *)self);
    ass_set_extract_fonts(_library, 1);
    NSUInteger total = 0;
    for (NSUInteger i = 0; i < fonts.count; i++) {
        NSData *font = fonts[i]; total += font.length;
        if (font.length > 20000000 || total > 64000000) return nil;
        ass_add_font(_library, [[NSString stringWithFormat:@"attachment-%lu", (unsigned long)i] UTF8String], (char *)font.bytes, (int)font.length);
    }
    NSMutableData *buffer = [script mutableCopy];
    [buffer appendBytes:"\0" length:1];
    _track = ass_read_memory(_library, buffer.mutableBytes, script.length, "UTF-8");
    if (!_track || _track->n_events <= 0) return nil;
    _renderer = ass_renderer_init(_library);
    if (!_renderer) return nil;
    ass_set_fonts(_renderer, fallbackPath.UTF8String, "sans-serif", ASS_FONTPROVIDER_AUTODETECT, NULL, 1);
    ass_set_shaper(_renderer, ASS_SHAPING_COMPLEX);
    ass_set_hinting(_renderer, ASS_HINTING_NONE);
    ass_set_use_margins(_renderer, 0);
    ass_set_cache_limits(_renderer, 1000, 32);
    return self;
}
- (void)setVideoMatrix:(NSString *)matrix {
    if (![_videoMatrix isEqualToString:matrix]) { _videoMatrix = [matrix copy]; _matrixChanged = YES; }
}
- (int)version { return ass_library_version(); }
- (void)noteSelectedPostScript:(const char *)name {
    if (!name) return;
    NSString *value = [NSString stringWithUTF8String:name];
    if (value.length && ![value isEqualToString:@"(none)"]) [_selectedNames addObject:value];
}
- (NSArray<NSString *> *)selectedPostScriptNames { return _selectedNames.allObjects; }
- (int)eventCount { return _track ? _track->n_events : 0; }
- (GlideASSFrame *)renderAt:(int64_t)milliseconds width:(int)width height:(int)height sourceWidth:(int)sw sourceHeight:(int)sh {
    GlideASSFrame *result = [GlideASSFrame new];
    if (!_renderer || width < 1 || height < 1 || width > 4096 || height > 4096 || (int64_t)width * height > 8388608) return result;
    BOOL resized = width != _width || height != _height || sw != _sourceWidth || sh != _sourceHeight;
    if (resized) {
        ass_set_frame_size(_renderer, width, height);
        ass_set_storage_size(_renderer, MAX(1, sw), MAX(1, sh));
        // The target rectangle is the actual display rectangle. Let libass
        // derive PAR from display/storage sizes, including anamorphic video.
        ass_set_pixel_aspect(_renderer, 0.0);
        _width = width; _height = height; _sourceWidth = sw; _sourceHeight = sh;
    }
    int changed = 0;
    ASS_Image *images = ass_render_frame(_renderer, _track, milliseconds, &changed);
    result.changed = changed != 0 || resized || _matrixChanged; _matrixChanged = NO;
    if (!result.changed) return result;
    int left = width, top = height, right = 0, bottom = 0;
    for (ASS_Image *p = images; p; p = p->next) {
        if (p->w <= 0 || p->h <= 0 || !p->bitmap || (p->color & 255) == 255) continue;
        left = MIN(left, MAX(0, p->dst_x)); top = MIN(top, MAX(0, p->dst_y));
        right = MAX(right, MIN(width, p->dst_x + p->w)); bottom = MAX(bottom, MIN(height, p->dst_y + p->h));
        result.imageCount++;
    }
    if (right <= left || bottom <= top) return result;
    int w = right - left, h = bottom - top;
    size_t size = (size_t)w * h * 4;
    uint8_t *rgba = calloc(1, size);
    if (!rgba) return result;
    // Preserve libass's layer order and premultiply coverage with ASS's inverted alpha.
    for (ASS_Image *p = images; p; p = p->next) {
        int opacity = 255 - (p->color & 255);
        if (p->w <= 0 || p->h <= 0 || !p->bitmap || !opacity) continue;
        int r, g, b; assColour(p->color, _track->YCbCrMatrix, _videoMatrix ?: @"", sh, &r, &g, &b);
        for (int y = MAX(top, p->dst_y); y < MIN(bottom, p->dst_y + p->h); y++) {
            const uint8_t *src = p->bitmap + (y - p->dst_y) * p->stride;
            uint8_t *dst = rgba + ((size_t)(y - top) * w) * 4;
            for (int x = MAX(left, p->dst_x); x < MIN(right, p->dst_x + p->w); x++) {
                int a = (src[x - p->dst_x] * opacity + 127) / 255, inverse = 255 - a;
                uint8_t *pixel = dst + (x - left) * 4;
                pixel[0] = (r * a + pixel[0] * inverse + 127) / 255;
                pixel[1] = (g * a + pixel[1] * inverse + 127) / 255;
                pixel[2] = (b * a + pixel[2] * inverse + 127) / 255;
                pixel[3] = a + (pixel[3] * inverse + 127) / 255;
            }
        }
    }
    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, rgba, size, kCFAllocatorMalloc);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false, kCGRenderingIntentDefault);
    if (image) { result.image = [UIImage imageWithCGImage:image]; CGImageRelease(image); }
    result.rect = CGRectMake(left, top, w, h);
    CGColorSpaceRelease(space); CGDataProviderRelease(provider); CFRelease(data);
    return result;
}
- (void)dealloc {
    if (_renderer) ass_renderer_done(_renderer);
    if (_track) ass_free_track(_track);
    if (_library) ass_library_done(_library);
}
@end
