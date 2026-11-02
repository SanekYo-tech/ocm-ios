#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

typedef void (*PySetHome)(const wchar_t *);
typedef void (*PySetProgram)(const wchar_t *);
typedef void (*PyInitEx)(int);
typedef int (*PyIsInit)(void);
typedef int (*PyRunString)(const char *);
typedef wchar_t *(*PyDecode)(const char *, size_t *);
typedef const char *(*PyVersion)(void);

int main(void) {
    const char *fw = "Vendor/python3_ios.xcframework/macos-x86_64/python3_ios.framework/python3_ios";
    const char *home = "Resources/python";
    void *h = dlopen(fw, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    PySetHome setHome = (PySetHome)dlsym(h, "Py_SetPythonHome");
    PySetProgram setProgram = (PySetProgram)dlsym(h, "Py_SetProgramName");
    PyInitEx initEx = (PyInitEx)dlsym(h, "Py_InitializeEx");
    PyIsInit isInit = (PyIsInit)dlsym(h, "Py_IsInitialized");
    PyRunString run = (PyRunString)dlsym(h, "PyRun_SimpleString");
    PyDecode decode = (PyDecode)dlsym(h, "Py_DecodeLocale");
    PyVersion version = (PyVersion)dlsym(h, "Py_GetVersion");
    if (!setHome || !initEx || !isInit || !run || !decode) { fprintf(stderr, "missing symbols\n"); return 2; }
    setenv("PYTHONHOME", home, 1);
    setenv("PYTHONPATH", "Resources/python/lib/python3.9", 1);
    wchar_t *wh = decode(home, NULL);
    wchar_t *wp = decode("python3", NULL);
    setHome(wh);
    if (setProgram) setProgram(wp);
    initEx(0);
    if (!isInit()) { fprintf(stderr, "not initialized\n"); return 3; }
    run("import sys\nprint('PY', sys.version)\nprint('PATH', sys.path[:5])\nprint('CALC', 6*7)\nsys.stdout.flush()\nsys.stderr.flush()\n");
    fprintf(stderr, "version: %s\n", version ? version() : "?");
    return 0;
}