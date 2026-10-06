#import "AppDelegate.h"
#import "DisplayViewController.h"
#import "PDLog.h"
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions { PDLog(@"App launch version=%@ build=%@ log=%@", [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"], [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"], PDLogFilePath()); application.idleTimerDisabled = YES; self.window=[[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds]; self.window.rootViewController=[[DisplayViewController alloc] init]; [self.window makeKeyAndVisible]; return YES; }
- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application { PDLog(@"MEMORY WARNING received"); }
- (void)applicationWillResignActive:(UIApplication *)application { PDLog(@"App will resign active"); }
- (void)applicationDidBecomeActive:(UIApplication *)application { PDLog(@"App became active"); }
- (void)applicationDidEnterBackground:(UIApplication *)application { PDLog(@"App entered background"); }
- (void)applicationWillEnterForeground:(UIApplication *)application { PDLog(@"App will enter foreground"); }
- (void)applicationWillTerminate:(UIApplication *)application { PDLog(@"App will terminate"); }
@end
