#import <MobileVLCKit/VLCLibrary.h>
#import <MobileVLCKit/VLCMediaPlayer.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns a player through the SDK's public native-instance initializer. This
/// narrow bridge reads libVLC's public clock instead of the SDK's event cache.
@interface VLCClockPlayer : NSObject
- (nullable instancetype)initWithLibrary:(VLCLibrary *)library;
@property (nonatomic, strong, readonly) VLCMediaPlayer *player;
@property (nonatomic, readonly) int64_t timeMilliseconds;
@end

NS_ASSUME_NONNULL_END
