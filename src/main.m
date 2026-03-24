#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#include <unistd.h>

static NSString *ReachyPythonExecutable(void) {
    NSString *resourcePath = [[NSBundle mainBundle] resourcePath] ?: @"";
    NSArray<NSString *> *candidates = @[
        [[resourcePath stringByAppendingPathComponent:@"venv/bin/python3.12"] stringByStandardizingPath],
        [[resourcePath stringByAppendingPathComponent:@"venv/bin/python3"] stringByStandardizingPath],
        [[resourcePath stringByAppendingPathComponent:@"venv/bin/python"] stringByStandardizingPath],
        @"/Users/maxl/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none/bin/python3.12",
        @"/usr/bin/python3",
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *candidate in candidates) {
        if (candidate.length && [fm isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static BOOL ReachyShouldForwardToPython(int argc, const char *argv[]) {
    if (argc < 2) return NO;
    NSString *firstArg = [NSString stringWithUTF8String:argv[1] ?: ""];
    if (!firstArg.length) return NO;

    // Only hand off to Python for explicit Python flags or a script file path.
    // Crucially, do NOT match macOS launch args like -psn_0_XXXXX (Process Serial Number).
    if ([firstArg isEqualToString:@"-c"] || [firstArg isEqualToString:@"-m"]) {
        return YES;
    }

    return [[NSFileManager defaultManager] fileExistsAtPath:firstArg];
}

static int ReachyForwardToPython(int argc, const char *argv[]) {
    NSString *python = ReachyPythonExecutable();
    if (!python.length) {
        fprintf(stderr, "ReachyControl: no Python executable available for CLI handoff\n");
        return 1;
    }

    char **forwardArgv = calloc((size_t)argc + 1, sizeof(char *));
    forwardArgv[0] = strdup(python.fileSystemRepresentation);
    for (int i = 1; i < argc; i++) {
        forwardArgv[i] = strdup(argv[i]);
    }

    execv(forwardArgv[0], forwardArgv);
    perror("ReachyControl execv");
    return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (ReachyShouldForwardToPython(argc, argv)) {
            return ReachyForwardToPython(argc, argv);
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
