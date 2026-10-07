#import <UIKit/UIKit.h>
@interface AppDelegate : UIResponder <UIApplicationDelegate, NSNetServiceDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) NSNetService *padDisplayService;
@end
