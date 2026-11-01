#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Prepares ios_system and restricts it to the app's OpenCode workspace.
void OCMShellInit(NSString *root);

/// Runs one command through ios_system and returns combined stdout+stderr.
/// `exitCode` receives the command status.
NSString *OCMRunCommand(NSString *command, NSString *cwd, int *exitCode);

/// Interrupts the currently running ios_system command.
void OCMShellKill(void);

/// True when ios_system knows this command.
BOOL OCMShellHasCommand(NSString *command);

NS_ASSUME_NONNULL_END