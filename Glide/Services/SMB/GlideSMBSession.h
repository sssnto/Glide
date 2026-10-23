#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Blocking operations run exclusively on the caller's background queue.
/// cancel is the only operation allowed concurrently. No remote mutation API.
@interface GlideSMBEntry : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL directory;
@property (nonatomic) uint64_t size;
@property (nonatomic, strong, nullable) NSDate *modified;
@property (nonatomic, strong, nullable) NSDate *created;
@end

@interface GlideSMBSession : NSObject
- (instancetype)initWithHost:(NSString *)host share:(NSString *)share user:(NSString *)user
                   password:(nullable NSString *)password domain:(NSString *)domain encrypted:(BOOL)encrypted;
- (nullable NSArray<GlideSMBEntry *> *)list:(NSString *)path error:(NSError **)error;
- (nullable NSNumber *)size:(NSString *)path error:(NSError **)error;
- (nullable NSData *)read:(NSString *)path offset:(uint64_t)offset length:(NSUInteger)length error:(NSError **)error;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
