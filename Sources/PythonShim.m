#import "PythonShim.h"
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <limits.h>
#include <errno.h>
#include <string.h>

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
typedef void *(*PyFileFromFd)(int, const char *, const char *, int, const char *, const char *, const char *, int);
typedef int (*PySysSetObject)(const char *, void *);
typedef void *(*PySysGetObject)(const char *);
typedef void (*PyIncRef)(void *);
typedef void (*PyDecRef)(void *);

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
static PyFileFromFd pFileFromFd;
static PySysSetObject pSysSetObject;
static PySysGetObject pSysGetObject;
static PyIncRef pIncRef;
static PyDecRef pDecRef;

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
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value] options:NSJSONWritingWithoutEscapingSlashes error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (json.length >= 2) return [json substringWithRange:NSMakeRange(1, json.length - 2)];
    return @"''";
}

static void *symbol(const char *name) {
    if (!gHandle) return NULL;
    return dlsym(gHandle, name);
}

static NSString *loadPython(void) {
    if (gHandle) return nil;
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"Python.framework/Python"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/Python.framework/Python"];
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return @"python3: framework не найден в бандле";
    }

    gHandle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!gHandle) {
        const char *err = dlerror();
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
    pFileFromFd = (PyFileFromFd)symbol("PyFile_FromFd");
    pSysSetObject = (PySysSetObject)symbol("PySys_SetObject");
    pSysGetObject = (PySysGetObject)symbol("PySys_GetObject");
    pIncRef = (PyIncRef)symbol("Py_IncRef");
    pDecRef = (PyDecRef)symbol("Py_DecRef");

    if (!pSetHome || !pInitEx || !pIsInit || !pRunString || !pRunFile ||
        !pSysArgv || !pErrPrint || !pDecode || !pRawFree ||
        !pFileFromFd || !pSysSetObject || !pSysGetObject || !pIncRef || !pDecRef) {
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
    NSString *lib = [home stringByAppendingPathComponent:@"lib/python3.13"];
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

    pInitEx(0);
    if (!pIsInit()) {
        gLoadError = @"python3: Py_InitializeEx завершился неудачно";
        return gLoadError;
    }

    NSString *dynload = [[NSBundle.mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"Python.framework/lib-dynload"] copy];
    NSString *bootstrap = [NSString stringWithFormat:
        @"import sys\nfor _p in [%@, %@, %@]:\n    if _p not in sys.path:\n        sys.path.insert(0, _p)\n",
        pyLiteral(dynload), pyLiteral(lib), pyLiteral([lib stringByAppendingPathComponent:@"site-packages"])];
    pRunString(bootstrap.UTF8String);
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
    return [first isEqualToString:@"python"] || [first isEqualToString:@"python3"] || [first isEqualToString:@"python3.13"];
}

int OCMPythonLastExit(void) { return gExit; }

static NSString *runPython(NSString *command, NSString *cwd) {
    gExit = 1;
    NSString *initError = initializePython();
    if (initError) return [initError stringByAppendingString:@"\n"];

    NSArray<NSString *> *tokens = pySplit(command);
    if (tokens.count == 0) return @"";
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]];
    if (args.count && ([args[0] isEqualToString:@"-V"] || [args[0] isEqualToString:@"--version"] || [args[0] isEqualToString:@"-version"])) {
        return [NSString stringWithFormat:@"Python %s\n", pVersion ? pVersion() : "3.13"];
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

    NSArray<NSString *> *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *resultDir = documents.firstObject ?: NSTemporaryDirectory();
    NSString *resultPath = [resultDir stringByAppendingPathComponent:[NSString stringWithFormat:@"ocm-py-%@.txt", NSUUID.UUID.UUIDString]];

    NSString *source = nil;
    NSString *filename = @"<string>";
    if (code) {
        source = code;
    } else if (module) {
        NSString *safe = module;
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"];
        NSMutableString *clean = [NSMutableString string];
        for (NSUInteger i = 0; i < safe.length; i++) {
            unichar c = [safe characterAtIndex:i];
            if ([allowed characterIsMember:c]) [clean appendFormat:@"%C", c];
        }
        source = [NSString stringWithFormat:@"import runpy\nrunpy.run_module(%@, run_name='__main__', alter_sys=True)", pyLiteral(clean)];
        filename = @"<runpy>";
    } else if (resolvedScript) {
        NSError *readError = nil;
        source = [NSString stringWithContentsOfFile:resolvedScript encoding:NSUTF8StringEncoding error:&readError];
        if (!source) {
            return [NSString stringWithFormat:@"python3: can't read file '%@': %@\n", script, readError.localizedDescription ?: @"decode error"];
        }
        filename = resolvedScript;
    }

    if (!source) {
        return @"python3: no code to execute\n";
    }

    FILE *capture = fopen(resultPath.fileSystemRepresentation, "w+");
    if (!capture) {
        return [NSString stringWithFormat:@"python3: cannot create output file: %s\n", strerror(errno)];
    }
    void *stream = pFileFromFd(fileno(capture), "ocm-python", "w", -1, "utf-8", "strict", NULL, 0);
    if (!stream) {
        fclose(capture);
        return @"python3: cannot create Python stream\n";
    }
    void *oldOut = pSysGetObject("stdout");
    void *oldErr = pSysGetObject("stderr");
    if (oldOut) pIncRef(oldOut);
    if (oldErr) pIncRef(oldErr);
    pSysSetObject("stdout", stream);
    pSysSetObject("stderr", stream);

    pSysArgv(argc, argv, 1);
    NSString *fileCode = [NSString stringWithFormat:@"import __main__\n__main__.__file__ = %@\n", pyLiteral(filename)];
    pRunString(fileCode.UTF8String);
    NSString *pathCode = [NSString stringWithFormat:@"import sys\n_p=%@\nif _p not in sys.path: sys.path.insert(0,_p)\n", pyLiteral(workDir)];
    pRunString(pathCode.UTF8String);
    int rc = pRunString(source.UTF8String);
    if (pErrOccurred && pErrOccurred()) {
        pErrPrint();
        rc = -1;
    }
    pRunString("import sys\nfor _s in (sys.stdout, sys.stderr):\n    try: _s.flush()\n    except Exception: pass\n");
    fflush(capture);
    pSysSetObject("stdout", oldOut);
    pSysSetObject("stderr", oldErr);
    if (oldOut) pDecRef(oldOut);
    if (oldErr) pDecRef(oldErr);
    pDecRef(stream);
    fclose(capture);

    NSString *resultText = [NSString stringWithContentsOfFile:resultPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [[NSFileManager defaultManager] removeItemAtPath:resultPath error:nil];

    for (int i = 0; i < argc; i++) if (argv[i]) pRawFree(argv[i]);
    free(argv);
    if (changed) chdir(previous);

    gExit = rc == 0 ? 0 : 1;
    return resultText;

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
