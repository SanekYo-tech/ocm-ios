#import "BoringHTTP.h"

#include <openssl/ssl.h>
#include <openssl/err.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <limits.h>

static NSError *BoringError(NSString *message) {
    return [NSError errorWithDomain:@"BoringHTTP" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static int BoringConnect(NSString *host, NSString **reason) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *result = NULL;
    int rc = getaddrinfo(host.UTF8String, "443", &hints, &result);
    if (rc != 0 || !result) {
        if (reason) *reason = [NSString stringWithFormat:@"DNS: %s", gai_strerror(rc)];
        return -1;
    }
    int fd = -1;
    for (struct addrinfo *item = result; item; item = item->ai_next) {
        fd = socket(item->ai_family, item->ai_socktype, item->ai_protocol);
        if (fd < 0) continue;
        struct timeval timeout = { .tv_sec = 60, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        if (connect(fd, item->ai_addr, item->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(result);
    if (fd < 0 && reason) *reason = [NSString stringWithFormat:@"connect: %s", strerror(errno)];
    return fd;
}

/// Decode an HTTP chunked body. Returns nil for malformed input.
static NSData *BoringDecodeChunked(NSData *raw) {
    NSMutableData *out = [NSMutableData data];
    const uint8_t *bytes = raw.bytes;
    NSUInteger length = raw.length;
    NSUInteger pos = 0;
    while (pos < length) {
        NSUInteger lineEnd = pos;
        while (lineEnd + 1 < length && !(bytes[lineEnd] == '\r' && bytes[lineEnd + 1] == '\n')) lineEnd++;
        if (lineEnd + 1 >= length) break;
        NSString *line = [[NSString alloc] initWithBytes:bytes + pos length:lineEnd - pos encoding:NSASCIIStringEncoding];
        NSString *sizeText = [[line componentsSeparatedByString:@";"] firstObject] ?: @"";
        unsigned long long size = strtoull(sizeText.UTF8String, NULL, 16);
        pos = lineEnd + 2;
        if (size == 0) break;
        if (pos + size > length) return nil;
        [out appendBytes:bytes + pos length:(NSUInteger)size];
        pos += (NSUInteger)size;
        if (pos + 1 < length && bytes[pos] == '\r' && bytes[pos + 1] == '\n') pos += 2;
    }
    return out;
}

NSData * _Nullable BoringHTTPPost(NSString *host,
                                  NSString *path,
                                  NSDictionary<NSString *, NSString *> *headers,
                                  NSData *body,
                                  NSInteger *status,
                                  NSError **error) {
    NSString *reason = nil;
    int fd = BoringConnect(host, &reason);
    if (fd < 0) {
        if (error) *error = BoringError(reason ?: @"connect failed");
        return nil;
    }

    SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
    if (!ctx) {
        if (error) *error = BoringError(@"SSL_CTX_new failed");
        close(fd);
        return nil;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    // These two extensions, plus BoringSSL's default cipher list and ALPN,
    // reproduce Bun's ClientHello (17 ciphers / 12 extensions).
    SSL_CTX_enable_signed_cert_timestamps(ctx);
    SSL *ssl = SSL_new(ctx);
    if (!ssl) {
        if (error) *error = BoringError(@"SSL_new failed");
        SSL_CTX_free(ctx);
        close(fd);
        return nil;
    }
    SSL_set_fd(ssl, fd);
    SSL_set_tlsext_host_name(ssl, host.UTF8String);
    SSL_set_tlsext_status_type(ssl, TLSEXT_STATUSTYPE_ocsp);
    static const unsigned char alpn[] = { 2, 'h', '2', 8, 'h', 't', 't', 'p', '/', '1', '.', '1' };
    SSL_set_alpn_protos(ssl, alpn, sizeof(alpn));

    int connected = SSL_connect(ssl);
    if (connected != 1) {
        unsigned long e = ERR_get_error();
        char buffer[256] = {0};
        if (e) ERR_error_string_n(e, buffer, sizeof(buffer));
        if (error) *error = BoringError([NSString stringWithFormat:@"TLS: %s", buffer]);
        SSL_free(ssl);
        SSL_CTX_free(ctx);
        close(fd);
        return nil;
    }

    NSMutableString *request = [NSMutableString string];
    [request appendFormat:@"POST %@ HTTP/1.1\r\n", path];
    [request appendFormat:@"Host: %@\r\n", host];
    for (NSString *key in headers) {
        [request appendFormat:@"%@: %@\r\n", key, headers[key]];
    }
    [request appendFormat:@"Content-Length: %lu\r\n", (unsigned long)body.length];
    [request appendString:@"Connection: close\r\n\r\n"];
    NSData *head = [request dataUsingEncoding:NSUTF8StringEncoding];

    BOOL failed = NO;
    for (NSData *part in @[head, body]) {
        const uint8_t *p = part.bytes;
        NSUInteger remaining = part.length;
        while (remaining > 0) {
            int written = SSL_write(ssl, p, (int)MIN(remaining, (NSUInteger)INT_MAX));
            if (written <= 0) { failed = YES; break; }
            p += written;
            remaining -= (NSUInteger)written;
        }
        if (failed) break;
    }
    if (failed) {
        if (error) *error = BoringError(@"TLS write failed");
        SSL_shutdown(ssl);
        SSL_free(ssl);
        SSL_CTX_free(ctx);
        close(fd);
        return nil;
    }

    NSMutableData *raw = [NSMutableData data];
    uint8_t buffer[16 * 1024];
    for (;;) {
        int got = SSL_read(ssl, buffer, sizeof(buffer));
        if (got > 0) {
            [raw appendBytes:buffer length:(NSUInteger)got];
            continue;
        }
        int err = SSL_get_error(ssl, got);
        if (err == SSL_ERROR_ZERO_RETURN) break;
        if (err == SSL_ERROR_WANT_READ || err == SSL_ERROR_WANT_WRITE) continue;
        break;
    }
    SSL_shutdown(ssl);
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    close(fd);

    NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSRange headerRange = [raw rangeOfData:separator options:0 range:NSMakeRange(0, raw.length)];
    if (headerRange.location == NSNotFound) {
        if (error) *error = BoringError(@"No HTTP response headers");
        return nil;
    }
    NSData *headerData = [raw subdataWithRange:NSMakeRange(0, headerRange.location)];
    NSData *payload = [raw subdataWithRange:NSMakeRange(NSMaxRange(headerRange), raw.length - NSMaxRange(headerRange))];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    NSInteger code = 0;
    if (lines.count > 0) {
        NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
        if (parts.count > 1) code = [parts[1] integerValue];
    }
    BOOL chunked = NO;
    NSUInteger contentLength = NSUIntegerMax;
    for (NSString *line in lines) {
        NSString *lower = line.lowercaseString;
        if ([lower hasPrefix:@"transfer-encoding:"] && [lower containsString:@"chunked"]) chunked = YES;
        if ([lower hasPrefix:@"content-length:"]) {
            contentLength = (NSUInteger)[[line substringFromIndex:15] integerValue];
        }
    }
    NSData *decoded = payload;
    if (chunked) {
        decoded = BoringDecodeChunked(payload);
        if (!decoded) {
            if (error) *error = BoringError(@"Malformed chunked response");
            return nil;
        }
    } else if (contentLength != NSUIntegerMax && payload.length >= contentLength) {
        decoded = [payload subdataWithRange:NSMakeRange(0, contentLength)];
    }
    if (status) *status = code;
    return decoded ?: [NSData data];
}