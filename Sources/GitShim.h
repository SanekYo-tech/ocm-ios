#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs a `git ...` command against the repository containing `cwd`.
NSString *OCMGitRun(NSString *command, NSString *cwd);

/// True if the raw shell command is a git invocation.
BOOL OCMGitIsCommand(NSString *command);

/// Exit status of the last OCMGitRun call.
int OCMGitLastExit(void);

NS_ASSUME_NONNULL_END