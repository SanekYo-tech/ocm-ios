#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal HTTP/1.1 client using BoringSSL with the exact ClientHello
/// shape used by Bun/OpenCode. This is only used for free-tier requests.
NSData * _Nullable BoringHTTPPost(NSString *host,
                                  NSString *path,
                                  NSDictionary<NSString *, NSString *> *headers,
                                  NSData *body,
                                  NSInteger *status,
                                  NSError **error);

NS_ASSUME_NONNULL_END