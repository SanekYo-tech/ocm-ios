#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL OCMPythonIsCommand(NSString *command);
BOOL OCMPythonAvailable(void);
NSString *OCMPythonRun(NSString *command, NSString *cwd);
int OCMPythonLastExit(void);

NS_ASSUME_NONNULL_END