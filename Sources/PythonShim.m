#import "PythonShim.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <limits.h>

// Python is loaded dynamically. If the prebuilt framework or one of its
// dependencies is missing on a particular iOS build, dlopen fails and Python
// reports an error instead of taking the whole app down at link/load time.
static void *gHandle = NULL;
static BOOL gReady = NO;
static BOOL gTried = NO;
static int gExit = 1;
static NSString *gLoadError = nil;

typedef void (*PySetHome)(const wchar_t *);
typedef void (*PySetProgram)(const wchar_t *);
typedef void (*PyInitEx)(int);
typedef int (*PyIsInit)(void);
typedef int (*PyRunString)(const char *);
typedef int (*PyRunFile)(FILE *, const char *, int, void *);
typedef void (*PySysArgv)(int, wchar_t **, int);
typedef void (*PyErrPrint)(void);
typedef void *(*PyErrOccurred)(void);
typedef wchar_t *(*PyDecodeLocale)(const char *, size_t *);
typedef void (*PyRawFree)(void *);
typedef const char *(*PyVersion)(void);

static PySetHome pSetHome;
static PySetProgram pSetProgram;
static PyInitEx pInitEx;
static PyIsInit pIsInit;
static PyRunString pRunString;
static PyRunFile pRunFile;
static PySysArgv pSysArgv;
static PyErrPrint pErrPrint;
static PyErrOccurred pErrOccurred;
static PyDecodeLocale pDecode;
static PyRawFree pRawFree;
static PyVersion pVersion;

static NSArray<NSString *> *pySplit(NSString *input) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSMutableString *cur = [NSMutableString string];
    BOOL inSingle = NO, inDouble = NO, has = NO;
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if (c == '\\' && !inSingle && i + 1 < input.length) {
            [cur appendFormat:@"%C", [input characterAtIndex:++i]];
            has = YES;
            continue;
        }
        if (c == '\'' && !inDouble) { inSingle = !inSingle; has = YES; continue; }
        if (c == '"' && !inSingle) { inDouble = !inDouble; has = YES; continue; }
        if ((c == ' ' || c == '\t' || c == '\n') && !inSingle && !inDouble) {
            if (has) { [out addObject:[cur copy]]; [cur setString:@""]; has = NO; }
            continue;
        }
        [cur appendFormat:@"%C", c];
        has = YES;
    }
    if (has) [out addObject:[cur copy]];
    return out;
}

static NSString *pyLiteral(NSString *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (json.length >= 2) return [json substringWithRange:NSMakeRange(1, json.length - 2)];
    return @"''";
}

static NSString *readStream(FILE *stream) {
    if (!stream) return @"";
    fflush(stream);
    long size = ftell(stream);
    if (size <= 0) return @"";
    rewind(stream);
    const long cap = 800 * 1024;
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

static void *symbol(const char *name) {
    if (!gHandle) return NULL;
    return dlsym(gHandle, name);
}

static NSString *loadPython(void) {
    if (gHandle) return nil;
    NSLog(@"OCM PY load start");
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"python3_ios.framework/python3_ios"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/python3_ios.framework/python3_ios"];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return @"python3: framework не найден в бандле";
    }

    gHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    NSLog(@"OCM PY dlopen %@ -> %p", path, gHandle);
    if (!gHandle) {
        const char *err = dlerror();
        NSLog(@"OCM PY dlopen error %s", err ? err : "?");
        return [NSString stringWithFormat:@"python3: не удалось загрузить рантайм: %s", err ? err : "unknown"];
    }

    pSetHome = (PySetHome)symbol("Py_SetPythonHome");
    pSetProgram = (PySetProgram)symbol("Py_SetProgramName");
    pInitEx = (PyInitEx)symbol("Py_InitializeEx");
    pIsInit = (PyIsInit)symbol("Py_IsInitialized");
    pRunString = (PyRunString)symbol("PyRun_SimpleString");
    pRunFile = (PyRunFile)symbol("PyRun_SimpleFileExFlags");
    pSysArgv = (PySysArgv)symbol("PySys_SetArgvEx");
    pErrPrint = (PyErrPrint)symbol("PyErr_Print");
    pErrOccurred = (PyErrOccurred)symbol("PyErr_Occurred");
    pDecode = (PyDecodeLocale)symbol("Py_DecodeLocale");
    pRawFree = (PyRawFree)symbol("PyMem_RawFree");
    pVersion = (PyVersion)symbol("Py_GetVersion");

    NSLog(@"OCM PY symbols home=%p init=%p run=%p", pSetHome, pInitEx, pRunString);
    if (!pSetHome || !pInitEx || !pIsInit || !pRunString || !pRunFile ||
        !pSysArgv || !pErrPrint || !pDecode || !pRawFree) {
        dlclose(gHandle);
        gHandle = NULL;
        return @"python3: в рантайме нет нужных C API";
    }
    return nil;
}

static NSString *initializePython(void) {
    if (gReady) return nil;
    if (gTried) return gLoadError ?: @"python3: рантайм недоступен";
    gTried = YES;

    NSString *home = [NSBundle.mainBundle.resourceURL.path stringByAppendingPathComponent:@"python"];
    NSString *lib = [home stringByAppendingPathComponent:@"lib/python3.9"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[lib stringByAppendingPathComponent:@"os.py"]]) {
        gLoadError = @"python3: стандартная библиотека не встроена";
        return gLoadError;
    }

    NSString *loadError = loadPython();
    if (loadError) { gLoadError = loadError; return gLoadError; }

    setenv("PYTHONHOME", home.fileSystemRepresentation, 1);
    setenv("PYTHONPATH", lib.fileSystemRepresentation, 1);
    setenv("PYTHONIOENCODING", "utf-8", 1);

    wchar_t *whome = pDecode(home.fileSystemRepresentation, NULL);
    wchar_t *wprog = pDecode("python3", NULL);
    if (!whome || !wprog) {
        gLoadError = @"python3: не удалось закодировать путь";
        return gLoadError;
    }
    pSetHome(whome);
    if (pSetProgram) pSetProgram(wprog);

    NSLog(@"OCM PY before InitializeEx");
    pInitEx(0);
    NSLog(@"OCM PY after InitializeEx");
    if (!pIsInit()) {
        gLoadError = @"python3: Py_InitializeEx завершился неудачно";
        return gLoadError;
    }

    NSString *bootstrap = [NSString stringWithFormat:
        @"import sys\nfor _p in [%@, %@]:\n    if _p not in sys.path:\n        sys.path.insert(0, _p)\n",
        pyLiteral(lib), pyLiteral([lib stringByAppendingPathComponent:@"site-packages"])];
    NSLog(@"OCM PY bootstrap");
    pRunString(bootstrap.UTF8String);
    NSLog(@"OCM PY ready");
    gReady = YES;
    return nil;
}

BOOL OCMPythonAvailable(void) {
    NSString *err = initializePython();
    return err == nil;
}

BOOL OCMPythonIsCommand(NSString *command) {
    NSArray *args = pySplit(command);
    if (args.count == 0) return NO;
    NSString *first = args[0];
    return [first isEqualToString:@"python"] || [first isEqualToString:@"python3"] || [first isEqualToString:@"python3.9"];
}

int OCMPythonLastExit(void) { return gExit; }

static NSString *runPython(NSString *command, NSString *cwd) {
    gExit = 1;
    NSString *initError = initializePython();
    if (initError) return [initError stringByAppendingString:@"\n"];

    NSArray<NSString *> *tokens = pySplit(command);
    if (tokens.count == 0) return @"";
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]];
    if (args.count && ([args[0] isEqualToString:@"-V"] || [args[0] isEqualToString:@"--version"])) {
        return [NSString stringWithFormat:@"Python %s\n", pVersion ? pVersion() : "3.9"];
    }

    NSString *code = nil, *script = nil, *module = nil;
    NSMutableArray<NSString *> *pyArgs = [NSMutableArray array];
    if (args.count && [args[0] isEqualToString:@"-c"]) {
        if (args.count < 2) return @"python3: argument expected for -c\n";
        code = args[1];
        if (args.count > 2) [pyArgs addObjectsFromArray:[args subarrayWithRange:NSMakeRange(2, args.count - 2)]];
    } else if (args.count && [args[0] isEqualToString:@"-m"]) {
        if (args.count < 2) return @"python3: argument expected for -m\n";
        module = args[1];
        if (args.count > 2) [pyArgs addObjectsFromArray:[args subarrayWithRange:NSMakeRange(2, args.count - 2)]];
    } else if (args.count) {
        script = args[0];
        if (args.count > 1) [pyArgs addObjectsFromArray:[args subarrayWithRange:NSMakeRange(1, args.count - 1)]];
    } else {
        return @"python3: интерактивный REPL не поддерживается. Запусти файл или python3 -c \"…\".\n";
    }

    NSString *workDir = cwd;
    NSString *resolvedScript = nil;
    if (script) {
        resolvedScript = [script isAbsolutePath] ? script : [workDir stringByAppendingPathComponent:script];
        if (![[NSFileManager defaultManager] fileExistsAtPath:resolvedScript]) {
            return [NSString stringWithFormat:@"python3: can't open file '%@': No such file or directory\n", script];
        }
        workDir = [resolvedScript stringByDeletingLastPathComponent];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:workDir]) {
        return [NSString stringWithFormat:@"python3: no such directory: %@\n", workDir];
    }

    char previous[PATH_MAX];
    BOOL changed = getcwd(previous, sizeof(previous)) != NULL &&
        [[NSFileManager defaultManager] changeCurrentDirectoryPath:workDir];

    NSMutableArray<NSString *> *argvStrings = [NSMutableArray array];
    if (script) [argvStrings addObject:script];
    else if (code) [argvStrings addObject:@"-c"];
    else if (module) [argvStrings addObject:@"-m"];
    [argvStrings addObjectsFromArray:pyArgs];

    int argc = (int)argvStrings.count;
    wchar_t **argv = calloc((size_t)argc + 1, sizeof(wchar_t *));
    for (int i = 0; i < argc; i++) argv[i] = pDecode(argvStrings[i].UTF8String, NULL);

    int savedOut = dup(STDOUT_FILENO);
    int savedErr = dup(STDERR_FILENO);
    FILE *out = tmpfile();
    FILE *err = tmpfile();
    if (out) dup2(fileno(out), STDOUT_FILENO);
    if (err) dup2(fileno(err), STDERR_FILENO);

    NSLog(@"OCM PY run start %@", command);
    pSysArgv(argc, argv, 1);
    NSString *pathCode = [NSString stringWithFormat:@"import sys\n_p=%@\nif _p not in sys.path: sys.path.insert(0,_p)\n", pyLiteral(workDir)];
    pRunString(pathCode.UTF8String);

    int rc = 0;
    if (code) {
        rc = pRunString(code.UTF8String);
    } else if (module) {
        NSString *safe = module;
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"];
        NSMutableString *clean = [NSMutableString string];
        for (NSUInteger i = 0; i < safe.length; i++) {
            unichar c = [safe characterAtIndex:i];
            if ([allowed characterIsMember:c]) [clean appendFormat:@"%C", c];
        }
        NSString *run = [NSString stringWithFormat:@"import runpy; runpy.run_module('%@', run_name='__main__', alter_sys=True)", clean];
        rc = pRunString(run.UTF8String);
    } else if (resolvedScript) {
        FILE *fp = fopen(resolvedScript.fileSystemRepresentation, "r");
        if (!fp) rc = -1;
        else rc = pRunFile(fp, resolvedScript.fileSystemRepresentation, 1, NULL);
    }

    if (pErrOccurred && pErrOccurred()) {
        pErrPrint();
        rc = -1;
    }
    NSLog(@"OCM PY rc=%d", rc);
    pRunString("import sys\nfor _s in (sys.stdout, sys.stderr):\n    try: _s.flush()\n    except Exception: pass\n");
    NSLog(@"OCM PY flushed");

    fflush(stdout);
    fflush(stderr);
    if (out) {
        fsync(fileno(out));
        if (savedOut >= 0) dup2(savedOut, STDOUT_FILENO);
    }
    if (err) {
        fsync(fileno(err));
        if (savedErr >= 0) dup2(savedErr, STDERR_FILENO);
    }
    if (savedOut >= 0) close(savedOut);
    if (savedErr >= 0) close(savedErr);

    NSString *stdoutText = readStream(out);
    NSString *stderrText = readStream(err);
    if (out) fclose(out);
    if (err) fclose(err);

    for (int i = 0; i < argc; i++) if (argv[i]) pRawFree(argv[i]);
    free(argv);
    if (changed) chdir(previous);

    NSString *combined = stdoutText;
    if (stderrText.length) {
        if (combined.length && ![combined hasSuffix:@"\n"]) combined = [combined stringByAppendingString:@"\n"];
        combined = [combined stringByAppendingString:stderrText];
    }
    gExit = rc == 0 ? 0 : 1;
    return combined;
}

NSString *OCMPythonRun(NSString *command, NSString *cwd) {
    // CPython is initialized and driven on the main thread. This avoids the
    // per-thread GIL/ios_system session traps of the first native integration.
    __block NSString *result = nil;
    if ([NSThread isMainThread]) {
        result = runPython(command, cwd);
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            result = runPython(command, cwd);
        });
    }
    return result ?: @"";
}