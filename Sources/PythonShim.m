#import "PythonShim.h"
#include <Python.h>
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <stdio.h>
#include <limits.h>

static BOOL gPythonReady = NO;
static BOOL gPythonTried = NO;
static int gPythonExit = 0;
static PyThreadState *gPythonThreadState = NULL;

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

static NSString *pyStringLiteral(NSString *value) {
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

static BOOL ensurePython(void) {
    if (gPythonReady) return YES;
    if (gPythonTried) return NO;
    gPythonTried = YES;

    NSString *home = [NSBundle.mainBundle.resourceURL.path stringByAppendingPathComponent:@"python"];
    NSString *osPy = [home stringByAppendingPathComponent:@"lib/python3.9/os.py"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:osPy]) {
        return NO;
    }

    wchar_t *whome = Py_DecodeLocale(home.fileSystemRepresentation, NULL);
    wchar_t *wprog = Py_DecodeLocale("python3", NULL);
    if (!whome || !wprog) return NO;
    Py_SetPythonHome(whome);
    Py_SetProgramName(wprog);
    Py_Initialize();
    if (!Py_IsInitialized()) return NO;
    NSString *lib = [home stringByAppendingPathComponent:@"lib/python3.9"];
    NSString *site = [lib stringByAppendingPathComponent:@"site-packages"];
    NSString *bootstrap = [NSString stringWithFormat:
        @"import sys\nfor _p in [%@, %@]:\n    if _p not in sys.path:\n        sys.path.insert(0, _p)\n",
        pyStringLiteral(lib), pyStringLiteral(site)];
    PyRun_SimpleString(bootstrap.UTF8String);
    gPythonThreadState = PyEval_SaveThread();
    gPythonReady = YES;
    return YES;
}

BOOL OCMPythonAvailable(void) {
    return ensurePython();
}

BOOL OCMPythonIsCommand(NSString *command) {
    NSArray *args = pySplit(command);
    if (args.count == 0) return NO;
    NSString *first = args[0];
    return [first isEqualToString:@"python"] || [first isEqualToString:@"python3"] || [first isEqualToString:@"python3.7"];
}

int OCMPythonLastExit(void) { return gPythonExit; }

NSString *OCMPythonRun(NSString *command, NSString *cwd) {
    gPythonExit = 1;
    if (!ensurePython()) {
        return @"python3: stdlib не встроен в эту сборку (нужна папка Resources/python)\n";
    }

    NSArray<NSString *> *tokens = pySplit(command);
    if (tokens.count == 0) return @"";
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)]];

    if (args.count && ([args[0] isEqualToString:@"-V"] || [args[0] isEqualToString:@"--version"])) {
        return [NSString stringWithFormat:@"Python %s\n", Py_GetVersion()];
    }

    NSString *code = nil;
    NSString *script = nil;
    NSString *module = nil;
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
        return @"python3: interactive REPL is not supported. Run a script or use -c \"...\".\n";
    }

    NSString *workDir = cwd;
    NSString *resolvedScript = nil;
    if (script) {
        resolvedScript = script;
        if (![resolvedScript isAbsolutePath]) resolvedScript = [workDir stringByAppendingPathComponent:resolvedScript];
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

    // Build sys.argv: python uses argv[0] as the script name or -c/-m.
    NSMutableArray<NSString *> *argvStrings = [NSMutableArray array];
    if (script) [argvStrings addObject:script];
    else if (code) [argvStrings addObject:@"-c"];
    else if (module) [argvStrings addObject:@"-m"];
    [argvStrings addObjectsFromArray:pyArgs];

    int argc = (int)argvStrings.count;
    wchar_t **argv = calloc((size_t)argc + 1, sizeof(wchar_t *));
    if (!argv) {
        if (changed) chdir(previous);
        return @"python3: out of memory\n";
    }
    for (int i = 0; i < argc; i++) argv[i] = Py_DecodeLocale(argvStrings[i].UTF8String, NULL);

    int savedOut = dup(STDOUT_FILENO);
    int savedErr = dup(STDERR_FILENO);
    FILE *out = tmpfile();
    FILE *err = tmpfile();
    if (out) dup2(fileno(out), STDOUT_FILENO);
    if (err) dup2(fileno(err), STDERR_FILENO);

    PyGILState_STATE gil = PyGILState_Ensure();
    PySys_SetArgvEx(argc, argv, 1);

    // Make relative imports work from cwd/script dir.
    NSString *pathCode = [NSString stringWithFormat:@"import sys; p=%@; sys.path.insert(0,p) if p not in sys.path else None", pyStringLiteral(workDir)];
    PyRun_SimpleString(pathCode.UTF8String);

    int rc = 0;
    if (code) {
        rc = PyRun_SimpleString(code.UTF8String);
    } else if (module) {
        NSString *safe = module;
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._"];
        NSMutableString *clean = [NSMutableString string];
        for (NSUInteger i = 0; i < safe.length; i++) {
            unichar c = [safe characterAtIndex:i];
            if ([allowed characterIsMember:c]) [clean appendFormat:@"%C", c];
        }
        NSString *run = [NSString stringWithFormat:@"import runpy; runpy.run_module('%@', run_name='__main__', alter_sys=True)", clean];
        rc = PyRun_SimpleString(run.UTF8String);
    } else if (resolvedScript) {
        FILE *fp = fopen(resolvedScript.fileSystemRepresentation, "r");
        if (!fp) {
            rc = -1;
        } else {
            rc = PyRun_SimpleFileExFlags(fp, resolvedScript.fileSystemRepresentation, 1, NULL);
        }
    }

    if (PyErr_Occurred()) {
        PyErr_Print();
        rc = -1;
    }
    PyRun_SimpleString("import sys\nfor _s in (sys.stdout, sys.stderr):\n    try: _s.flush()\n    except Exception: pass\n");
    PyGILState_Release(gil);

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

    for (int i = 0; i < argc; i++) PyMem_RawFree(argv[i]);
    free(argv);
    if (changed) chdir(previous);

    NSString *combined = stdoutText;
    if (stderrText.length) {
        if (combined.length && ![combined hasSuffix:@"\n"]) combined = [combined stringByAppendingString:@"\n"];
        combined = [combined stringByAppendingString:stderrText];
    }
    gPythonExit = rc == 0 ? 0 : 1;
    return combined;
}