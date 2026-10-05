#import "AppDelegate.h"
#import "DisplayViewController.h"
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions { application.idleTimerDisabled = YES; self.window=[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds]; self.window.rootViewController=[[DisplayViewController alloc] init]; [self.window makeKeyAndVisible]; return YES; }
@end
