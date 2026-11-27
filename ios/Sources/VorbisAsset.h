#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Supplies locally decoded PCM to AVPlayer while reading the original Ogg by HTTP range.
@interface VorbisAsset : NSObject
- (instancetype)initWithRequest:(NSURLRequest *)request byteCount:(int64_t)byteCount;
- (void)prepareWithCompletionHandler:(void (^)(BOOL supported, NSError * _Nullable error))completion;
- (AVPlayerItem *)playerItem;
- (void)cancel;
+ (void)cancelItem:(nullable AVPlayerItem *)item;
@end

NS_ASSUME_NONNULL_END
