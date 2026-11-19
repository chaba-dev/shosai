#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#if !TARGET_OS_IOS || TARGET_OS_MACCATALYST
#error This SQLite build is only for iOS and its Simulator
#endif

// iPhone/iPad containers are local APFS. On Macs, verify the storage type
// instead of rejecting the platform or assuming that its container is APFS.
static int shosaiContainerPath(const char *path) {
  @autoreleasepool {
    if (path == NULL) return 0;
    NSString *name = [NSString stringWithUTF8String:path];
    if (name == nil || !name.isAbsolutePath) return 0;
    NSString *home = NSHomeDirectory().stringByResolvingSymlinksInPath;
    char canonical[PATH_MAX];
    BOOL creating = realpath(path, canonical) == NULL;
    if (creating) {
      // realpath requires an existing leaf. Resolve its existing parent for
      // creation, but reject dangling symlinks rather than follow them later.
      struct stat info;
      if (errno != ENOENT || lstat(path, &info) == 0) return 0;
      if (realpath(name.stringByDeletingLastPathComponent.fileSystemRepresentation,
                   canonical) == NULL) return 0;
    }
    NSString *resolved = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:canonical length:strlen(canonical)];
    if (creating) resolved = [resolved stringByAppendingPathComponent:name.lastPathComponent];
    if (![resolved hasPrefix:[home stringByAppendingString:@"/"]]) return 0;
    // iOS can return no volume type even when this key is available. Its
    // private-container filesystem contract does not require this query.
    if (!NSProcessInfo.processInfo.isiOSAppOnMac) return 1;
    if (@available(iOS 16.4, *)) {
      // A new database/journal need not exist yet. Its containing directory
      // must exist, and determines the filesystem where SQLite will create it.
      NSURL *directory = [NSURL fileURLWithPath:resolved.stringByDeletingLastPathComponent
                                   isDirectory:YES];
      NSString *type = nil;
      if (![directory getResourceValue:&type forKey:NSURLVolumeTypeNameKey error:NULL]) return 0;
      return [type isEqualToString:@"apfs"];
    }
    return 0;
  }
}
