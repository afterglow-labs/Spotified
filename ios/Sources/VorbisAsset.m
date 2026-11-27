#import "VorbisAsset.h"
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <vorbis/vorbisfile.h>

static NSError *PlaybackError(NSString *message) {
    return [NSError errorWithDomain:@"Spotified.Vorbis" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

// Only the private server receives the session cookie.
@interface MediaRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation MediaRedirectDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completion {
    completion(nil);
}
@end

// libvorbisfile reads synchronously on the asset's serial worker queue. Keep several
// compressed blocks so opening the file (which inspects both ends) and small seeks are cheap.
@interface OggInput : NSObject
@property (nonatomic, readonly) int64_t length;
@property (nonatomic) int64_t position;
@property (nonatomic, strong) NSError *error;
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;
- (instancetype)initWithRequest:(NSURLRequest *)request length:(int64_t)length;
- (size_t)read:(void *)destination bytes:(size_t)count;
- (void)cancel;
@end

@implementation OggInput {
    NSURLRequest *_request;
    NSURLSession *_session;
    NSURLSessionDataTask *_transfer;
    NSCache<NSNumber *, NSData *> *_blocks;
    BOOL _cancelled;
}
- (instancetype)initWithRequest:(NSURLRequest *)request length:(int64_t)length {
    if ((self = [super init])) {
        _request = [request copy];
        _length = length;
        _blocks = [[NSCache alloc] init];
        _blocks.countLimit = 6;
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.HTTPCookieStorage = nil;
        config.URLCache = nil;
        config.timeoutIntervalForRequest = 15;
        _session = [NSURLSession sessionWithConfiguration:config delegate:[MediaRedirectDelegate new] delegateQueue:nil];
    }
    return self;
}
- (NSData *)blockAt:(int64_t)start length:(int64_t)length {
    if (self.cancelled) return nil;
    NSData *cached = [_blocks objectForKey:@(start)];
    if (cached) return cached;
    NSMutableURLRequest *request = [_request mutableCopy];
    int64_t end = start + length - 1;
    [request setValue:[NSString stringWithFormat:@"bytes=%lld-%lld", start, end] forHTTPHeaderField:@"Range"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSData *bytes;
    __block NSError *failure;
    NSURLSessionDataTask *transfer = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSString *range = [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, self.length];
        if (error) failure = error;
        else if (http.statusCode == 401) failure = PlaybackError(@"Your server session expired. Sign in again.");
        else if (http.statusCode == 206 && [range isEqualToString:[http valueForHTTPHeaderField:@"Content-Range"]] && data.length == length) bytes = data;
        else failure = PlaybackError(@"The server could not read this part of the song. Refresh your library and try again.");
        dispatch_semaphore_signal(finished);
    }];
    @synchronized (self) {
        _transfer = transfer;
        if (_cancelled) [transfer cancel];
        [transfer resume];
    }
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
    @synchronized (self) { _transfer = nil; }
    self.error = failure;
    if (bytes) [_blocks setObject:bytes forKey:@(start)];
    return bytes;
}
- (size_t)read:(void *)destination bytes:(size_t)count {
    const int64_t blockSize = 128 * 1024;
    size_t copied = 0;
    while (copied < count && _position < _length) {
        int64_t start = (_position / blockSize) * blockSize;
        NSData *block = [self blockAt:start length:MIN(blockSize, _length - start)];
        if (!block) break;
        NSUInteger offset = (NSUInteger)(_position - start);
        NSUInteger take = MIN(count - copied, block.length - offset);
        [block getBytes:(uint8_t *)destination + copied range:NSMakeRange(offset, take)];
        copied += take;
        _position += take;
    }
    return copied;
}
- (void)cancel {
    @synchronized (self) { _cancelled = YES; [_transfer cancel]; }
}
- (BOOL)isCancelled { @synchronized (self) { return _cancelled; } }
- (void)dealloc { [_session invalidateAndCancel]; }
@end

static size_t ReadOgg(void *buffer, size_t size, size_t count, void *context) {
    if (!size || count > SIZE_MAX / size) return 0;
    OggInput *input = (__bridge OggInput *)context;
    return [input read:buffer bytes:size * count] / size;
}
static int SeekOgg(void *context, ogg_int64_t offset, int whence) {
    OggInput *input = (__bridge OggInput *)context;
    int64_t base;
    switch (whence) {
        case SEEK_SET: base = 0; break;
        case SEEK_CUR: base = input.position; break;
        case SEEK_END: base = input.length; break;
        default: return -1;
    }
    if (offset < -base || offset > input.length - base) return -1;
    input.position = base + offset;
    return 0;
}
static long TellOgg(void *context) { return (long)((__bridge OggInput *)context).position; }

// A CAF with floating-point PCM lets AVPlayer retain seeking, AirPlay and lock-screen
// playback. No decoded file is written. The header describes the exact Vorbis frame count.
typedef struct __attribute__((packed)) {
    char magic[4]; uint16_t version, fileFlags;
    char desc[4]; uint64_t descSize; CFSwappedFloat64 rate; char codec[4];
    uint32_t flags, bytesPerPacket, framesPerPacket, channels, bits;
    char data[4]; uint64_t dataSize; uint32_t editCount;
} PCMHeader;

static char VorbisOwnerKey;

@interface VorbisAsset () <AVAssetResourceLoaderDelegate>
@end

@implementation VorbisAsset {
    OggInput *_input;
    OggVorbis_File _file;
    dispatch_queue_t _queue;
    BOOL _open;
    int _channels;
    int64_t _byteLength;
    NSData *_header;
}
- (instancetype)initWithRequest:(NSURLRequest *)request byteCount:(int64_t)byteCount {
    if ((self = [super init])) {
        _input = [[OggInput alloc] initWithRequest:request length:byteCount];
        _queue = dispatch_queue_create("com.afterglowlabs.spotified.vorbis", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)prepareWithCompletionHandler:(void (^)(BOOL, NSError *))completion {
    dispatch_async(_queue, ^{
        ov_callbacks io = {ReadOgg, SeekOgg, NULL, TellOgg};
        int result = ov_open_callbacks((__bridge void *)self->_input, &self->_file, NULL, 0, io);
        if (result != 0) {
            NSError *error = self->_input.error;
            if (!error && result != OV_ENOTVORBIS) error = PlaybackError(@"Could not read the Ogg audio headers.");
            completion(NO, error);
            return;
        }
        self->_open = YES;
        vorbis_info *info = ov_info(&self->_file, 0);
        int64_t frames = ov_pcm_total(&self->_file, -1);
        if (!info || info->rate <= 0 || info->channels < 1 || info->channels > 2 || frames <= 0 ||
            frames > (INT64_MAX - sizeof(PCMHeader) - 4) / (info->channels * sizeof(float))) {
            completion(NO, self->_input.error);
            return;
        }
        for (int link = 1; link < ov_streams(&self->_file); link++) {
            vorbis_info *next = ov_info(&self->_file, link);
            if (!next || next->rate != info->rate || next->channels != info->channels) { completion(NO, nil); return; }
        }
        self->_channels = info->channels;
        uint32_t stride = info->channels * sizeof(float);
        int64_t bytes = frames * stride;
        PCMHeader header = {"caff", CFSwapInt16HostToBig(1), 0, "desc", CFSwapInt64HostToBig(32),
            CFConvertDoubleHostToSwapped(info->rate), "lpcm",
            CFSwapInt32HostToBig(kCAFLinearPCMFormatFlagIsFloat | kCAFLinearPCMFormatFlagIsLittleEndian),
            CFSwapInt32HostToBig(stride), CFSwapInt32HostToBig(1), CFSwapInt32HostToBig(info->channels),
            CFSwapInt32HostToBig(32), "data", CFSwapInt64HostToBig(bytes + 4), 0};
        self->_header = [NSData dataWithBytes:&header length:sizeof(header)];
        self->_byteLength = sizeof(header) + bytes;
        completion(YES, nil);
    });
}
- (AVPlayerItem *)playerItem {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"spotified-audio://local/%@.caf", NSUUID.UUID.UUIDString]];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    [asset.resourceLoader setDelegate:self queue:_queue];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    objc_setAssociatedObject(item, &VorbisOwnerKey, self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return item;
}
- (NSData *)pcmAt:(int64_t)offset length:(NSUInteger)count {
    int stride = _channels * sizeof(float);
    int64_t frame = offset / stride;
    int skip = offset % stride;
    if (ov_pcm_tell(&_file) != frame && ov_pcm_seek(&_file, frame) != 0) return nil;
    int frames = (int)((skip + count + stride - 1) / stride);
    NSMutableData *data = [NSMutableData dataWithLength:frames * stride];
    float *dest = data.mutableBytes;
    int remaining = frames, holes = 0;
    while (remaining > 0) {
        float **samples = NULL;
        long read = ov_read_float(&_file, &samples, remaining, NULL);
        if (read == OV_HOLE && ++holes <= 8) continue;
        if (read <= 0) return nil;
        for (long i = 0; i < read; i++)
            for (int c = 0; c < _channels; c++) *dest++ = samples[c][i];
        remaining -= (int)read;
    }
    if (skip == 0 && count == data.length) return data;
    return [data subdataWithRange:NSMakeRange(skip, count)];
}
- (BOOL)resourceLoader:(AVAssetResourceLoader *)loader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)request {
    AVAssetResourceLoadingContentInformationRequest *info = request.contentInformationRequest;
    info.contentType = AVFileTypeCoreAudioFormat;
    info.contentLength = _byteLength;
    info.byteRangeAccessSupported = YES;
    [self respondTo:request];
    return YES;
}
- (void)respondTo:(AVAssetResourceLoadingRequest *)request {
    if (request.cancelled || request.finished) return;
    if (_input.cancelled) {
        [request finishLoadingWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
        return;
    }
    AVAssetResourceLoadingDataRequest *data = request.dataRequest;
    if (!data) { [request finishLoading]; return; }
    int64_t offset = data.currentOffset;
    int64_t start = data.requestedOffset;
    if (start < 0 || start > _byteLength || offset < start || offset > _byteLength) {
        [request finishLoadingWithError:PlaybackError(@"Invalid audio seek position.")]; return;
    }
    int64_t end = data.requestsAllDataToEndOfResource ? _byteLength : start + MIN(_byteLength - start, data.requestedLength);
    if (offset >= end) { [request finishLoading]; return; }
    NSData *chunk;
    if (offset < (int64_t)_header.length) {
        NSUInteger size = MIN(end - offset, (int64_t)_header.length - offset);
        chunk = [_header subdataWithRange:NSMakeRange((NSUInteger)offset, size)];
    } else {
        NSUInteger size = MIN(end - offset, 64 * 1024);
        chunk = [self pcmAt:offset - _header.length length:size];
    }
    if (!chunk.length) { [request finishLoadingWithError:_input.error ?: PlaybackError(@"Could not decode this part of the song.")]; return; }
    [data respondWithData:chunk];
    if (data.currentOffset >= end) [request finishLoading];
    else dispatch_async(_queue, ^{ [self respondTo:request]; });
}
- (void)cancel { [_input cancel]; }
+ (void)cancelItem:(AVPlayerItem *)item { [(VorbisAsset *)objc_getAssociatedObject(item, &VorbisOwnerKey) cancel]; }
- (void)dealloc { if (_open) ov_clear(&_file); }
@end
