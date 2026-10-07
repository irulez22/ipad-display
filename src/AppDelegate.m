#import "AppDelegate.h"
#import "DisplayViewController.h"
#import "PDLog.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *build = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];
    PDLog(@"App launch version=%@ build=%@ log=%@", version, build, PDLogFilePath());

    application.idleTimerDisabled = YES;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[DisplayViewController alloc] init];
    [self.window makeKeyAndVisible];

    NSString *serviceName = [NSString stringWithFormat:@"PadDisplay-%@", [UIDevice currentDevice].name ?: @"iPad"];
    self.padDisplayService = [[NSNetService alloc] initWithDomain:@"local."
                                                            type:@"_paddisplay._tcp."
                                                            name:serviceName
                                                            port:4822];
    self.padDisplayService.delegate = self;

    NSDictionary *txt = @{
        @"protocol": [@"1" dataUsingEncoding:NSUTF8StringEncoding],
        @"version": [version dataUsingEncoding:NSUTF8StringEncoding],
        @"build": [build dataUsingEncoding:NSUTF8StringEncoding],
        @"audioPort": [@"4824" dataUsingEncoding:NSUTF8StringEncoding]
    };
    [self.padDisplayService setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:txt]];
    [self.padDisplayService publish];
    return YES;
}

- (void)netServiceDidPublish:(NSNetService *)sender
{
    PDLog(@"Bonjour published %@.%@ port=%ld", sender.name, sender.type, (long)sender.port);
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary *)errorDict
{
    PDLog(@"Bonjour publish failed: %@", errorDict);
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application { PDLog(@"MEMORY WARNING received"); }
- (void)applicationWillResignActive:(UIApplication *)application { PDLog(@"App will resign active"); }
- (void)applicationDidBecomeActive:(UIApplication *)application { PDLog(@"App became active"); }
- (void)applicationDidEnterBackground:(UIApplication *)application { PDLog(@"App entered background"); }
- (void)applicationWillEnterForeground:(UIApplication *)application { PDLog(@"App will enter foreground"); }
- (void)applicationWillTerminate:(UIApplication *)application {
    [self.padDisplayService stop];
    PDLog(@"App will terminate");
}
@end
