#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface GlideASSFrame : NSObject
@property(nonatomic, readonly) BOOL changed;
@property(nonatomic, readonly, nullable) UIImage *image;
@property(nonatomic, readonly) CGRect rect;
@property(nonatomic, readonly) NSUInteger imageCount;
@end
/// Confined to ASSRenderWorker's actor; no calls or destruction overlap.
@interface GlideASSRenderer : NSObject
- (nullable instancetype)initWithScript:(NSData *)script fonts:(NSArray<NSData *> *)fonts fallbackPath:(NSString *)fallbackPath;
- (void)setVideoMatrix:(NSString *)matrix;
- (GlideASSFrame *)renderAt:(int64_t)milliseconds width:(int)width height:(int)height sourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight;
@property(nonatomic, readonly) int eventCount;
@property(nonatomic, readonly) NSArray<NSString *> *selectedPostScriptNames;
@property(nonatomic, readonly) int version;
@end
NS_ASSUME_NONNULL_END
