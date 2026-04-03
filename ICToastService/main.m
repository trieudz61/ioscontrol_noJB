// main.m — ICToastService Application Entry Point
// Uses UIApplicationMain like XXTUIService from XXTouch

#import <UIKit/UIKit.h>
#import "ICToastAppDelegate.h"

int main(int argc, char *argv[]) {
  @autoreleasepool {
    // Write early log
    int fd = open("/tmp/ictoast_log.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
      dprintf(fd, "%s: main() entered (PID=%d)\n", [NSDate date], getpid());
      close(fd);
    }

    // UIApplicationMain handles all UIKit bootstrapping
    // This is the pattern XXTUIService uses
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([ICToastAppDelegate class]));
  }
}
