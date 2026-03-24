#define PY_SSIZE_T_CLEAN
#import "PythonBridge.h"
#import <Python.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>

// Path to the uv-managed Python 3.12 installation
static NSString * const kPyPrefix = @"/Users/maxl/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none";

@interface PythonBridge ()
@property (nonatomic, assign) BOOL initialized;
@property (nonatomic, assign) PyObject *bridgeModule;   // bridge.py module
@property (nonatomic, assign) PyThreadState *mainThreadState;
@end

@implementation PythonBridge

- (BOOL)initialize {
    if (self.initialized) return YES;

    // Determine bridge.py path: inside bundle or dev path
    NSString *bridgePath = nil;
    NSString *bundleRes = [[NSBundle mainBundle] resourcePath];
    NSString *bundleBridge = [bundleRes stringByAppendingPathComponent:@"bridge.py"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleBridge]) {
        bridgePath = [bundleBridge stringByDeletingLastPathComponent];
    } else {
        // Dev mode: relative to executable
        NSString *exeDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
        // Walk up to find python/bridge.py
        NSString *candidate = [[exeDir stringByAppendingPathComponent:@"../../../.."]
                               stringByAppendingPathComponent:@"python"];
        bridgePath = [candidate stringByStandardizingPath];
    }

    // Also determine venv site-packages to inject
    NSString *venvPath = nil;
    NSString *bundleVenv = [bundleRes stringByAppendingPathComponent:@"venv"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:bundleVenv]) {
        venvPath = bundleVenv;
    } else {
        NSString *exeDir = [[[NSBundle mainBundle] executablePath] stringByDeletingLastPathComponent];
        NSString *devVenv = [[[[exeDir stringByAppendingPathComponent:@"../../../.."]
                               stringByAppendingPathComponent:@"python/.venv"]
                              stringByStandardizingPath] copy];
        if ([[NSFileManager defaultManager] fileExistsAtPath:devVenv]) {
            venvPath = devVenv;
        }
    }

    NSString *programPath = [self pythonExecutableForVenv:venvPath];
    if (!programPath.length) {
        programPath = [kPyPrefix stringByAppendingPathComponent:@"bin/python3.12"];
    }

    // Configure Python home so it finds stdlib
    NSString *pyHome = kPyPrefix;
    Py_SetPythonHome((wchar_t *)[self wcharFromString:pyHome]);
    if (programPath.length) {
        setenv("PYTHONEXECUTABLE", programPath.UTF8String, 1);
        Py_SetProgramName((wchar_t *)[self wcharFromString:programPath]);
    }

    // Initialize
    Py_Initialize();
    if (!Py_IsInitialized()) {
        NSLog(@"PythonBridge: Py_Initialize() failed");
        return NO;
    }

    // Inject paths via sys.path
    PyRun_SimpleString("import sys");

    if (programPath.length) {
        NSString *escapedProgramPath = [[programPath stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
            stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        NSString *cmd = [NSString stringWithFormat:
            @"import os, sys\n"
             "_py = '%@'\n"
             "sys.executable = _py\n"
             "sys._base_executable = _py\n"
             "os.environ['PYTHONEXECUTABLE'] = _py\n"
             "try:\n"
             "    import multiprocessing as _mp\n"
             "    _mp.set_executable(_py)\n"
             "except Exception:\n"
             "    pass\n",
             escapedProgramPath];
        PyRun_SimpleString(cmd.UTF8String);
        NSLog(@"PythonBridge: using Python executable %@", programPath);
    }

    // Add bridge.py directory
    if (bridgePath) {
        NSString *cmd = [NSString stringWithFormat:
            @"import sys; sys.path.insert(0, '%@')", bridgePath];
        PyRun_SimpleString(cmd.UTF8String);
    }

    // Add venv site-packages
    if (venvPath) {
        NSString *sitePkgs = [NSString stringWithFormat:
            @"%@/lib/python3.12/site-packages", venvPath];
        NSString *cmd = [NSString stringWithFormat:
            @"import sys; sys.path.insert(0, '%@')", sitePkgs];
        PyRun_SimpleString(cmd.UTF8String);
        NSLog(@"PythonBridge: added venv site-packages: %@", sitePkgs);
    }

    // Import bridge module
    PyObject *name = PyUnicode_FromString("bridge");
    self.bridgeModule = PyImport_Import(name);
    Py_DECREF(name);

    if (!self.bridgeModule) {
        PyErr_Print();
        NSLog(@"PythonBridge: failed to import bridge.py (path: %@)", bridgePath);
        // Don't fail hard — app still works via HTTP
    } else {
        NSLog(@"PythonBridge: bridge.py imported successfully");
    }

    // Release the GIL so Python background threads can run. Subsequent bridge
    // calls reacquire it with PyGILState_Ensure().
    self.mainThreadState = PyEval_SaveThread();

    self.initialized = YES;
    return YES;
}

- (nullable NSString *)callFunction:(NSString *)funcName withArgs:(nullable NSDictionary *)args {
    if (!self.initialized || !self.bridgeModule) return nil;

    PyGILState_STATE gstate = PyGILState_Ensure();

    NSString *result = nil;
    PyObject *func = PyObject_GetAttrString(self.bridgeModule, funcName.UTF8String);
    if (!func || !PyCallable_Check(func)) {
        PyErr_Clear();
        Py_XDECREF(func);
        PyGILState_Release(gstate);
        NSLog(@"PythonBridge: function '%@' not found in bridge", funcName);
        return nil;
    }

    // Build args tuple and kwargs dict
    PyObject *pyResult = NULL;
    if (args && args.count > 0) {
        // Pass as JSON string argument
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        PyObject *pyArg = PyUnicode_FromString(jsonStr.UTF8String);
        PyObject *tuple = PyTuple_Pack(1, pyArg);
        pyResult = PyObject_CallObject(func, tuple);
        Py_DECREF(tuple);
        Py_DECREF(pyArg);
    } else {
        PyObject *emptyTuple = PyTuple_New(0);
        pyResult = PyObject_CallObject(func, emptyTuple);
        Py_DECREF(emptyTuple);
    }

    if (pyResult) {
        if (PyUnicode_Check(pyResult)) {
            result = [NSString stringWithUTF8String:PyUnicode_AsUTF8(pyResult)];
        }
        Py_DECREF(pyResult);
    } else {
        PyErr_Print();
    }

    Py_DECREF(func);
    PyGILState_Release(gstate);
    return result;
}

- (BOOL)startCameraWithCallback:(void *)callbackPtr {
    if (!self.initialized || !self.bridgeModule) return NO;

    PyGILState_STATE gstate = PyGILState_Ensure();

    PyObject *func = PyObject_GetAttrString(self.bridgeModule, "start_camera");
    BOOL ok = NO;
    if (func && PyCallable_Check(func)) {
        // Pass the C function pointer as a Python int
        PyObject *pyPtr = PyLong_FromVoidPtr(callbackPtr);
        PyObject *tuple = PyTuple_Pack(1, pyPtr);
        PyObject *res = PyObject_CallObject(func, tuple);
        Py_DECREF(tuple);
        Py_DECREF(pyPtr);
        if (res) {
            ok = YES;
            Py_DECREF(res);
        } else {
            PyErr_Print();
        }
        Py_DECREF(func);
    } else {
        PyErr_Clear();
    }

    PyGILState_Release(gstate);
    return ok;
}

- (BOOL)startLiveSessionWithAPI:(NSString *)api
                       statusFn:(void *)statusPtr
                   transcriptFn:(void *)transcriptPtr
                      speakingFn:(void *)speakingPtr {
    if (!self.initialized || !self.bridgeModule) return NO;

    PyGILState_STATE gstate = PyGILState_Ensure();

    PyObject *func = PyObject_GetAttrString(self.bridgeModule, "start_live_session");
    BOOL ok = NO;
    if (func && PyCallable_Check(func)) {
        NSDictionary *cfg = @{@"api": api};
        NSData *jd = [NSJSONSerialization dataWithJSONObject:cfg options:0 error:nil];
        NSString *js = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];

        PyObject *pyJson     = PyUnicode_FromString(js.UTF8String);
        PyObject *pyStatus   = PyLong_FromVoidPtr(statusPtr);
        PyObject *pyTrans    = PyLong_FromVoidPtr(transcriptPtr);
        PyObject *pySpeaking = PyLong_FromVoidPtr(speakingPtr);
        PyObject *tuple = PyTuple_Pack(4, pyJson, pyStatus, pyTrans, pySpeaking);

        PyObject *res = PyObject_CallObject(func, tuple);
        Py_DECREF(tuple);
        Py_DECREF(pyJson); Py_DECREF(pyStatus);
        Py_DECREF(pyTrans); Py_DECREF(pySpeaking);

        if (res) { ok = YES; Py_DECREF(res); }
        else { PyErr_Print(); }
        Py_DECREF(func);
    } else {
        PyErr_Clear();
    }

    PyGILState_Release(gstate);
    return ok;
}

- (void)stopLiveSession {
    if (!self.initialized || !self.bridgeModule) return;
    PyGILState_STATE gstate = PyGILState_Ensure();
    PyObject *func = PyObject_GetAttrString(self.bridgeModule, "stop_live_session");
    if (func && PyCallable_Check(func)) {
        PyObject *t = PyTuple_New(0);
        PyObject *r = PyObject_CallObject(func, t);
        Py_DECREF(t); Py_XDECREF(r);
        Py_DECREF(func);
    } else {
        PyErr_Clear();
    }
    PyGILState_Release(gstate);
}

- (void)teardown {
    if (!self.initialized) return;
    if (self.mainThreadState) {
        PyEval_RestoreThread(self.mainThreadState);
        self.mainThreadState = NULL;
    }
    if (self.bridgeModule) {
        Py_XDECREF(self.bridgeModule);
        self.bridgeModule = NULL;
    }
    Py_FinalizeEx();
    self.initialized = NO;
}

// ── Helpers ──────────────────────────────────────────────────────────────────

- (wchar_t *)wcharFromString:(NSString *)s {
    const char *utf8 = s.UTF8String;
    size_t len = mbstowcs(NULL, utf8, 0) + 1;
    wchar_t *buf = (wchar_t *)malloc(len * sizeof(wchar_t));
    mbstowcs(buf, utf8, len);
    return buf;  // caller owns; leaking is fine for one-time config
}

- (NSString *)pythonExecutableForVenv:(NSString *)venvPath {
    NSArray<NSString *> *candidates = @[
        [venvPath stringByAppendingPathComponent:@"bin/python3.12"],
        [venvPath stringByAppendingPathComponent:@"bin/python3"],
        [venvPath stringByAppendingPathComponent:@"bin/python"],
        [kPyPrefix stringByAppendingPathComponent:@"bin/python3.12"],
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *candidate in candidates) {
        if (candidate.length && [fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

@end
