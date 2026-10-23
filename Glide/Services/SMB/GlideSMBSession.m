#import "GlideSMBSession.h"
#include <poll.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <errno.h>
#include <sys/time.h>
#include "Vendor/smb2/smb2.h"
#include "Vendor/smb2/libsmb2.h"

// Public libsmb2 4.0.0 ABI already exported by pinned MobileVLCKit 3.7.3.
// Each instance owns a context; never share it with VLC's input context.
typedef struct { BOOL done; int status; void *data; } GlideSMBResult;
static void completed(struct smb2_context *ctx, int status, void *data, void *opaque) {
    GlideSMBResult *result = opaque;
    result->status = status; result->data = data; result->done = YES;
}

@implementation GlideSMBEntry
@end

@implementation GlideSMBSession {
    struct smb2_context *_context;
    atomic_bool _cancelled;
    NSString *_host, *_share, *_user, *_password, *_domain;
    BOOL _encrypted;
}
- (instancetype)initWithHost:(NSString *)host share:(NSString *)share user:(NSString *)user
                   password:(NSString *)password domain:(NSString *)domain encrypted:(BOOL)encrypted {
    if ((self = [super init])) {
        _host = [host copy]; _share = [share copy]; _user = [user copy];
        _password = [password copy]; _domain = [domain copy]; _encrypted = encrypted;
        atomic_init(&_cancelled, false);
    }
    return self;
}
- (void)dealloc { if (_context) smb2_destroy_context(_context); }
- (void)cancel { atomic_store(&_cancelled, true); }
- (BOOL)fail:(int)code error:(NSError **)error {
    if (_context && code != ECANCELED && code != ETIMEDOUT) {
        const char *detail = smb2_get_error(_context);
        if (detail && (strstr(detail, "LOGON_FAILURE") || strstr(detail, "PASSWORD") || strstr(detail, "ACCOUNT_"))) code = 1001;
        else if (detail && strstr(detail, "ACCESS_DENIED")) code = EACCES;
        else if (detail && (strstr(detail, "OBJECT_NAME_NOT_FOUND") || strstr(detail, "BAD_NETWORK_NAME") || strstr(detail, "OBJECT_PATH_NOT_FOUND"))) code = ENOENT;
        else if (detail && strstr(detail, "NOT_SUPPORTED")) code = ENOTSUP;
    }
    // Never expose libsmb2_get_error: it may contain host, path or account data.
    if (error) *error = [NSError errorWithDomain:@"Glide.SMB" code:abs(code) userInfo:nil];
    return NO;
}
- (BOOL)wait:(GlideSMBResult *)result start:(int)start error:(NSError **)error {
    if (start < 0) return [self fail:start error:error];
    NSTimeInterval deadline = NSDate.timeIntervalSinceReferenceDate + 15;
    int failure = 0;
    while (!result->done) {
        if (atomic_load(&_cancelled)) { failure = ECANCELED; break; }
        if (NSDate.timeIntervalSinceReferenceDate >= deadline) { failure = ETIMEDOUT; break; }
        size_t count = 0; int timeout = -1;
        const int *fds = smb2_get_fds(_context, &count, &timeout);
        if (count > 32) { failure = EIO; break; }
        struct pollfd polls[32];
        for (size_t i = 0; i < count; ++i) polls[i] = (struct pollfd){fds[i], smb2_which_events(_context), 0};
        int delay = timeout < 0 ? 100 : MIN(100, timeout);
        int ready = poll(polls, (nfds_t)count, delay);
        if (ready < 0 && errno != EINTR) { failure = errno; break; }
        if (ready > 0) {
            for (size_t i = 0; i < count; ++i) {
                if (polls[i].revents && smb2_service_fd(_context, polls[i].fd, polls[i].revents) < 0) { failure = ECONNRESET; break; }
                if (result->done) break;
            }
        } else if (smb2_service_fd(_context, -1, 0) < 0) { failure = ECONNRESET; }
        if (failure) break;
    }
    if (failure && !result->done) {
        [self fail:failure error:error];
        // Destroy while the callback's stack storage is still valid.
        smb2_destroy_context(_context); _context = NULL;
        return NO;
    }
    return result->status >= 0 || [self fail:result->status error:error];
}
- (BOOL)connect:(NSError **)error {
    if (atomic_load(&_cancelled)) return [self fail:ECANCELED error:error];
    if (_context) return YES;
    _context = smb2_init_context();
    if (!_context) return [self fail:ENOMEM error:error];
    smb2_set_version(_context, _encrypted ? SMB2_VERSION_ANY3 : SMB2_VERSION_ANY);
    smb2_set_security_mode(_context, SMB2_NEGOTIATE_SIGNING_ENABLED);
    smb2_set_timeout(_context, 12);
    smb2_set_user(_context, _user.UTF8String);
    smb2_set_password(_context, _password.UTF8String);
    smb2_set_domain(_context, _domain.UTF8String);
    smb2_set_seal(_context, _encrypted);
    GlideSMBResult result = {0};
    return [self wait:&result start:smb2_connect_share_async(_context, _host.UTF8String, _share.UTF8String, _user.UTF8String, completed, &result) error:error];
}
- (NSArray<GlideSMBEntry *> *)list:(NSString *)path error:(NSError **)error {
    if (![self connect:error]) return nil;
    GlideSMBResult result = {0};
    if (![self wait:&result start:smb2_opendir_async(_context, path.UTF8String, completed, &result) error:error]) return nil;
    struct smb2dir *directory = result.data;
    NSMutableArray *entries = [NSMutableArray array];
    struct smb2dirent *entry;
    while ((entry = smb2_readdir(_context, directory))) {
        if (atomic_load(&_cancelled)) { smb2_closedir(_context, directory); [self fail:ECANCELED error:error]; return nil; }
        NSString *name = [NSString stringWithUTF8String:entry->name];
        if (!name || [name isEqualToString:@"."] || [name isEqualToString:@".."] || entry->st.smb2_type == SMB2_TYPE_LINK) continue;
        GlideSMBEntry *item = [GlideSMBEntry new]; item.name = name;
        item.directory = entry->st.smb2_type == SMB2_TYPE_DIRECTORY; item.size = entry->st.smb2_size;
        if (entry->st.smb2_mtime > 0) item.modified = [NSDate dateWithTimeIntervalSince1970:entry->st.smb2_mtime];
        if (entry->st.smb2_btime > 0) item.created = [NSDate dateWithTimeIntervalSince1970:entry->st.smb2_btime];
        [entries addObject:item];
    }
    smb2_closedir(_context, directory);
    return entries;
}
- (NSNumber *)size:(NSString *)path error:(NSError **)error {
    if (![self connect:error]) return nil;
    struct smb2_stat_64 stat = {0}; GlideSMBResult result = {0};
    if (![self wait:&result start:smb2_stat_async(_context, path.UTF8String, &stat, completed, &result) error:error]) return nil;
    if (stat.smb2_type != SMB2_TYPE_FILE) { [self fail:EISDIR error:error]; return nil; }
    return @(stat.smb2_size);
}
- (NSData *)read:(NSString *)path offset:(uint64_t)offset length:(NSUInteger)length error:(NSError **)error {
    if (![self connect:error]) return nil;
    GlideSMBResult opened = {0};
    if (![self wait:&opened start:smb2_open_async(_context, path.UTF8String, O_RDONLY, completed, &opened) error:error]) return nil;
    struct smb2fh *file = opened.data;
    NSUInteger bounded = MIN(length, MIN(smb2_get_max_read_size(_context), 1024 * 1024));
    NSMutableData *data = [NSMutableData dataWithLength:bounded];
    GlideSMBResult read = {0};
    BOOL success = [self wait:&read start:smb2_pread_async(_context, file, data.mutableBytes, (uint32_t)bounded, offset, completed, &read) error:error];
    if (_context) { GlideSMBResult closed = {0}; [self wait:&closed start:smb2_close_async(_context, file, completed, &closed) error:nil]; }
    if (!success) return nil;
    data.length = (NSUInteger)read.status;
    return data;
}
@end
