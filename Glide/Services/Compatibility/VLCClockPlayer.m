#import "VLCClockPlayer.h"

// Public libVLC 3.x C ABI, exported by the pinned MobileVLCKit 3.7.3 framework.
typedef struct libvlc_instance_t libvlc_instance_t;
typedef struct libvlc_media_player_t libvlc_media_player_t;
extern libvlc_media_player_t *libvlc_media_player_new(libvlc_instance_t *);
extern void libvlc_media_player_release(libvlc_media_player_t *);
extern int64_t libvlc_media_player_get_time(libvlc_media_player_t *);
extern int libvlc_media_player_get_state(libvlc_media_player_t *);

@implementation VLCClockPlayer {
    libvlc_media_player_t *_nativePlayer;
}
- (nullable instancetype)initWithLibrary:(VLCLibrary *)library {
    if ((self = [super init])) {
        _nativePlayer = libvlc_media_player_new((libvlc_instance_t *)library.instance);
        if (!_nativePlayer) return nil;
        // This initializer transfers the new native player's one reference to
        // VLCMediaPlayer. Its asynchronous retirement remains the adapter's job.
        _player = [[VLCMediaPlayer alloc] initWithLibVLCInstance:_nativePlayer andLibrary:library];
        if (!_player) {
            libvlc_media_player_release(_nativePlayer);
            return nil;
        }
    }
    return self;
}
- (int64_t)timeMilliseconds { return libvlc_media_player_get_time(_nativePlayer); }
- (int)nativeState { return libvlc_media_player_get_state(_nativePlayer); }
// libvlc_state_t in the pinned libVLC 3.x public ABI: libvlc_Ended = 6.
- (BOOL)hasEnded { return self.nativeState == 6; }
@end
