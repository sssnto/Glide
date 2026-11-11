#import "GlideVLCFrameExtractor.h"
#include <stdatomic.h>
#include <pthread.h>

// Public libVLC 3.x C ABI from the pinned MobileVLCKit 3.7.3 framework.
typedef struct libvlc_instance_t libvlc_instance_t;
typedef struct libvlc_media_t libvlc_media_t;
typedef struct libvlc_media_player_t libvlc_media_player_t;
extern libvlc_media_t *libvlc_media_new_location(libvlc_instance_t *, const char *);
extern void libvlc_media_add_option(libvlc_media_t *, const char *);
extern void libvlc_media_release(libvlc_media_t *);
extern libvlc_media_player_t *libvlc_media_player_new(libvlc_instance_t *);
extern void libvlc_media_player_set_media(libvlc_media_player_t *, libvlc_media_t *);
extern int libvlc_media_player_play(libvlc_media_player_t *);
extern void libvlc_media_player_stop(libvlc_media_player_t *);
extern void libvlc_media_player_release(libvlc_media_player_t *);
extern int libvlc_media_player_get_state(libvlc_media_player_t *);
extern void libvlc_video_set_callbacks(libvlc_media_player_t *, void *(*)(void *, void **), void (*)(void *, void *, void *const *), void (*)(void *, void *), void *);
extern void libvlc_video_set_format_callbacks(libvlc_media_player_t *, unsigned (*)(void **, char *, unsigned *, unsigned *, unsigned *, unsigned *), void (*)(void *));

typedef struct {
    pthread_mutex_t mutex;
    atomic_bool cancelled;
    unsigned width, height, pitch, frames;
    uint8_t *pixels;
    CGImageRef image;
} GlideFrameOutput;

static unsigned GlideFrameFormat(void **opaque, char *chroma, unsigned *width, unsigned *height, unsigned *pitches, unsigned *lines) {
    GlideFrameOutput *out = *opaque;
    if (!*width || !*height || *width > 131072 || *height > 131072) return 0;
    double scale = MIN(1., 640. / MAX(*width, *height));
    *width = MAX(1, (unsigned)(*width * scale)); *height = MAX(1, (unsigned)(*height * scale));
    memcpy(chroma, "RGBA", 4);
    pitches[0] = (*width * 4 + 31) & ~31u; lines[0] = (*height + 31) & ~31u;
    pthread_mutex_lock(&out->mutex);
    free(out->pixels); out->pixels = NULL;
    void *buffer = NULL;
    size_t bytes = (size_t)pitches[0] * lines[0];
    if (posix_memalign(&buffer, 32, bytes) == 0) { memset(buffer, 0, bytes); out->pixels = buffer; }
    out->width = *width; out->height = *height; out->pitch = pitches[0];
    BOOL allocated = out->pixels != NULL;
    pthread_mutex_unlock(&out->mutex);
    return allocated ? 1 : 0;
}
static void *GlideFrameLock(void *opaque, void **planes) {
    GlideFrameOutput *out = opaque;
    pthread_mutex_lock(&out->mutex); planes[0] = out->pixels; return NULL;
}
static void GlideFrameUnlock(void *opaque, void *picture, void *const *planes) {
    pthread_mutex_unlock(&((GlideFrameOutput *)opaque)->mutex);
}
static void GlideFrameDisplay(void *opaque, void *picture) {
    GlideFrameOutput *out = opaque;
    pthread_mutex_lock(&out->mutex);
    out->frames++;
    if (!out->image && out->pixels && out->frames >= 2 && !atomic_load(&out->cancelled)) {
        // Copy once; libVLC can overwrite or release its RGBA buffer after this callback.
        CFDataRef bytes = CFDataCreate(NULL, out->pixels, out->pitch * out->height);
        if (!bytes) { pthread_mutex_unlock(&out->mutex); return; }
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(bytes);
        CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        out->image = CGImageCreate(out->width, out->height, 8, 32, out->pitch, color,
                                  kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault, provider, NULL, false, kCGRenderingIntentDefault);
        CGColorSpaceRelease(color); CGDataProviderRelease(provider); CFRelease(bytes);
    }
    pthread_mutex_unlock(&out->mutex);
}

@implementation GlideVLCFrameExtractor {
    VLCLibrary *_library;
    NSURL *_url;
    GlideFrameOutput _output;
}
- (instancetype)initWithLibrary:(VLCLibrary *)library url:(NSURL *)url {
    if ((self = [super init])) {
        _library = library; _url = url;
        pthread_mutex_init(&_output.mutex, NULL); atomic_init(&_output.cancelled, false);
    }
    return self;
}
- (void)cancel { atomic_store(&_output.cancelled, true); }
- (void)startWithCompletion:(void (^)(CGImageRef, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            libvlc_media_t *media = libvlc_media_new_location((libvlc_instance_t *)self->_library.instance, self->_url.absoluteString.UTF8String);
            libvlc_media_player_t *player = libvlc_media_player_new((libvlc_instance_t *)self->_library.instance);
            BOOL started = NO;
            if (media && player && !atomic_load(&self->_output.cancelled)) {
                for (NSString *option in @[@":no-audio", @":no-spu", @":no-osd", @":network-caching=150", @":avcodec-threads=1", @":avcodec-skiploopfilter=3", @":codec=avcodec,none", @":start-time=0.1"]) {
                    libvlc_media_add_option(media, option.UTF8String);
                }
                libvlc_media_player_set_media(player, media);
                libvlc_video_set_callbacks(player, GlideFrameLock, GlideFrameUnlock, GlideFrameDisplay, &self->_output);
                libvlc_video_set_format_callbacks(player, GlideFrameFormat, NULL);
                started = libvlc_media_player_play(player) == 0;
            }
            CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 10;
            BOOL captured = NO;
            while (started && !atomic_load(&self->_output.cancelled) && CFAbsoluteTimeGetCurrent() < deadline) {
                pthread_mutex_lock(&self->_output.mutex); captured = self->_output.image != NULL; pthread_mutex_unlock(&self->_output.mutex);
                int state = libvlc_media_player_get_state(player);
                if (captured || state == 6 || state == 7) break; // ended / error in libVLC 3.x
                [NSThread sleepForTimeInterval:0.025];
            }
            // There are no main-thread vout callbacks to deadlock while joining.
            if (player) { libvlc_media_player_stop(player); libvlc_media_player_release(player); }
            if (media) libvlc_media_release(media);
            pthread_mutex_lock(&self->_output.mutex);
            CGImageRef image = self->_output.image; self->_output.image = NULL;
            free(self->_output.pixels); self->_output.pixels = NULL;
            pthread_mutex_unlock(&self->_output.mutex);
            BOOL cancelled = atomic_load(&self->_output.cancelled);
            NSError *error = image && !cancelled ? nil : [NSError errorWithDomain:@"GlideThumbnail" code:cancelled ? NSUserCancelledError : 1 userInfo:@{NSLocalizedDescriptionKey:cancelled ? @"已取消视频预览" : @"无法读取视频预览画面"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(cancelled ? NULL : image, error); if (image) CGImageRelease(image); });
        }
    });
}
- (void)dealloc { pthread_mutex_destroy(&_output.mutex); }
@end
