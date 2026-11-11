#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MobileVLCKit/VLCLibrary.h>

NS_ASSUME_NONNULL_BEGIN
/// A cancellable, silent, bounded-size memory output. It never creates UIKit
/// video views and joins the decoder on a utility thread before completion.
@interface GlideVLCFrameExtractor : NSObject
- (instancetype)initWithLibrary:(VLCLibrary *)library url:(NSURL *)url;
- (void)startWithCompletion:(void (^)(CGImageRef _Nullable image, NSError * _Nullable error))completion NS_SWIFT_NAME(start(completion:));
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
