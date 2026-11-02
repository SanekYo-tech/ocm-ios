#import "ShellShim.h"
#import <ios_system/ios_system.h>

static void OCMSetThreadStreams(FILE *input, FILE *output, FILE *error) {
    thread_stdin = input;
    thread_stdout = output;
    thread_stderr = error;
}

void OCMShellInit(NSString *root) {
    @autoreleasepool {
        initializeEnvironment();
        joinMainThread = true;
        sideLoading = true;

        NSURL *rootURL = [NSURL fileURLWithPath:root isDirectory:YES];
        ios_setMiniRootURL(rootURL);
        ios_setMiniRoot(root);
        ios_setDirectoryURL(rootURL);

        ios_setenv("HOME", root.UTF8String, 1);
        ios_setenv("PWD", root.UTF8String, 1);
        ios_setenv("TMPDIR", NSTemporaryDirectory().UTF8String, 1);
        NSString *path = [NSString stringWithFormat:@"%@/bin:/usr/local/bin:/usr/bin:/bin", root];
        ios_setenv("PATH", path.UTF8String, 1);
        ios_setenv("LANG", "C.UTF-8", 1);
        ios_setenv("TERM", "xterm-256color", 1);
    }
}

BOOL OCMShellHasCommand(NSString *command) {
    return ios_executable(command.UTF8String) != 0;
}

static NSString *OCMReadStream(FILE *stream) {
    if (!stream) return @"";
    fflush(stream);
    long size = ftell(stream);
    if (size <= 0) return @"";
    rewind(stream);
    const long cap = 600 * 1024;
    long toRead = MIN(size, cap);
    char *buf = malloc((size_t)toRead + 1);
    if (!buf) return @"";
    size_t got = fread(buf, 1, (size_t)toRead, stream);
    buf[got] = 0;
    NSString *s = [[NSString alloc] initWithBytes:buf length:got encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithBytes:buf length:got encoding:NSISOLatin1StringEncoding];
    free(buf);
    if (size > cap) s = [s stringByAppendingString:@"\n…[вывод обрезан]"];
    return s ?: @"";
}

NSString *OCMRunCommand(NSString *command, NSString *cwd, int *exitCode) {
    @autoreleasepool {
        if (command.length == 0) { if (exitCode) *exitCode = 0; return @""; }
        FILE *out = tmpfile();
        FILE *err = tmpfile();
        if (!out || !err) {
            if (out) fclose(out);
            if (err) fclose(err);
            if (exitCode) *exitCode = 1;
            return @"shell: cannot create output stream\n";
        }

        if (cwd.length > 0) {
            NSURL *cwdURL = [NSURL fileURLWithPath:cwd isDirectory:YES];
            ios_setDirectoryURL(cwdURL);
        }
        ios_setStreams(NULL, out, err);
        OCMSetThreadStreams(NULL, out, err);

        int result = ios_system(command.UTF8String);
        int status = ios_getCommandStatus();
        if (result == 0 && status != 0) result = status;

        NSString *stdoutText = OCMReadStream(out);
        NSString *stderrText = OCMReadStream(err);
        fclose(out);
        fclose(err);

        NSString *combined = stdoutText;
        if (stderrText.length > 0) {
            if (combined.length > 0 && ![combined hasSuffix:@"\n"]) combined = [combined stringByAppendingString:@"\n"];
            combined = [combined stringByAppendingString:stderrText];
        }
        if (exitCode) *exitCode = result;
        return combined;
    }
}

void OCMShellKill(void) {
    ios_kill();
}
