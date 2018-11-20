//
//  ShareViewController.m
//  OpenWith - Share Extension
//

//
// The MIT License (MIT)
//
// Copyright (c) 2017 Jean-Christophe Hoelt
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#import <UIKit/UIKit.h>
#import <Social/Social.h>
#import "ShareViewController.h"

@interface ShareViewController : UIViewController {
    int _verbosityLevel;
    NSUserDefaults *_userDefaults;
    NSString *_backURL;
}
@property (nonatomic) int verbosityLevel;
@property (nonatomic,retain) NSUserDefaults *userDefaults;
@property (nonatomic,retain) NSString *backURL;
@end

/*
 * Constants
 */

#define VERBOSITY_DEBUG  0
#define VERBOSITY_INFO  10
#define VERBOSITY_WARN  20
#define VERBOSITY_ERROR 30

@implementation ShareViewController

@synthesize verbosityLevel = _verbosityLevel;
@synthesize userDefaults = _userDefaults;
@synthesize backURL = _backURL;

- (void) log:(int)level message:(NSString*)message {
    if (level >= self.verbosityLevel) {
        NSLog(@"[ShareViewController.m]%@", message);
    }
}
- (void) debug:(NSString*)message { [self log:VERBOSITY_DEBUG message:message]; }
- (void) info:(NSString*)message { [self log:VERBOSITY_INFO message:message]; }
- (void) warn:(NSString*)message { [self log:VERBOSITY_WARN message:message]; }
- (void) error:(NSString*)message { [self log:VERBOSITY_ERROR message:message]; }

-(void) viewDidLoad {
    [super viewDidLoad];
    printf("did load");
    [self debug:@"[viewDidLoad]"];
    [self submit];
}

- (void) setup {
    self.userDefaults = [[NSUserDefaults alloc] initWithSuiteName:SHAREEXT_GROUP_IDENTIFIER];
    self.verbosityLevel = [self.userDefaults integerForKey:@"verbosityLevel"];
    [self debug:@"[setup]"];
}

- (BOOL) isContentValid {
    return YES;
}

- (void) openURL:(nonnull NSURL *)url {

    SEL selector = NSSelectorFromString(@"openURL:options:completionHandler:");

    UIResponder* responder = self;
    while ((responder = [responder nextResponder]) != nil) {
        NSLog(@"responder = %@", responder);
        if([responder respondsToSelector:selector] == true) {
            NSMethodSignature *methodSignature = [responder methodSignatureForSelector:selector];
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSignature];

            // Arguments
            NSDictionary<NSString *, id> *options = [NSDictionary dictionary];
            void (^completion)(BOOL success) = ^void(BOOL success) {
                NSLog(@"Completions block: %i", success);
            };

            [invocation setTarget: responder];
            [invocation setSelector: selector];
            [invocation setArgument: &url atIndex: 2];
            [invocation setArgument: &options atIndex:3];
            [invocation setArgument: &completion atIndex: 4];
            [invocation invoke];
            break;
        }
    }
}

- (void) submit {

    [self setup];
    [self debug:@"[submit]"];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *groupPath = [fileManager containerURLForSecurityApplicationGroupIdentifier:SHAREEXT_GROUP_IDENTIFIER];
    NSString *tmpDir = [groupPath.path stringByAppendingPathComponent:@"shareTmp"];
    NSLog(@"tmpDir %@",tmpDir);
    NSError *error;

    if (((NSExtensionItem*)self.extensionContext.inputItems[0]).attachments.count > 0) {
        BOOL successDelete = [fileManager removeItemAtPath:tmpDir error:&error];
        if (successDelete) {
            NSLog(@"SUCCESS DELETE 'shareTmp' NO ERROR");
        } else {
            NSLog(@"Deleting error %@, %@", error, [error userInfo]);
        }
    }
    // create path to store files
    BOOL success = [fileManager createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:&error];
    if (!success) {
        NSLog(@"Creating dir error %@, %@", error, [error userInfo]);
    }

    NSMutableArray *dataArray = [NSMutableArray new];
    dispatch_group_t dispatchGroup = dispatch_group_create();
    dispatch_group_enter(dispatchGroup);

    // This is called after the user selects Post. Do the upload of contentText and/or NSExtensionContext attachments.
    for (NSItemProvider* itemProvider in ((NSExtensionItem*)self.extensionContext.inputItems[0]).attachments) {

        if ([itemProvider hasItemConformingToTypeIdentifier:@"public.plain-text"]) {
            dispatch_group_enter(dispatchGroup);

            [self debug:@"[public.plain-text]"];
            [self debug:[NSString stringWithFormat:@"item provider = %@", itemProvider]];

            [itemProvider loadItemForTypeIdentifier:@"public.plain-text" options:nil completionHandler: ^(id<NSSecureCoding> item, NSError *error) {

                NSString *data;
                if([(NSObject*)item isKindOfClass:[NSString class]]) {
                    data = (NSString*)item;
                }

                NSString *uti = nil;
                if ([itemProvider.registeredTypeIdentifiers count] > 0) {
                    uti = itemProvider.registeredTypeIdentifiers[0];
                }
                else {
                    uti = @"public.plain-text";
                }

                NSDictionary *dict = @{
                                       @"backURL": self.backURL != nil ? self.backURL : @"",
                                       @"text": data,
                                       @"path": @"",
                                       @"uti": uti,
                                       @"utis": itemProvider.registeredTypeIdentifiers,
                                       @"name": @""
                                       };

                [dataArray addObject:dict];

                dispatch_group_leave(dispatchGroup);
            }];
        } else
        if ([itemProvider hasItemConformingToTypeIdentifier:@"public.image"]) {
            dispatch_group_enter(dispatchGroup);
            [self debug:[NSString stringWithFormat:@"item provider = %@", itemProvider]];

            [itemProvider loadItemForTypeIdentifier:@"public.image" options:nil completionHandler: ^(id<NSSecureCoding> item, NSError *error) {

                /**
                 * Save the image to NSTemporaryDirectory(), which cleans itself tri-daily.
                 * This is necessary as the iOS 11 screenshot editor gives us a UIImage, while
                 * sharing from Photos and similar apps gives us a URL
                 * Therefore the solution is to save a UIImage, either way, and return the local path to that temp UIImage
                 * This path will be sent to React Native and can be processed and accessed RN side.
                 **/

                NSString *filePath = [tmpDir stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
                NSString *fullPath;
                NSData *sharedData = nil;

                NSString *uti = nil;
                if ([itemProvider.registeredTypeIdentifiers count] > 0) {
                    uti = itemProvider.registeredTypeIdentifiers[0];
                }
                else {
                    uti = @"public.image";
                }

                if ([uti hasPrefix:@"public.png"]) {
                    // not tested
                    fullPath = [filePath stringByAppendingPathExtension:@"png"];
                } else {
                    fullPath = [filePath stringByAppendingPathExtension:@"jpg"];
                }

                if ([(NSObject *)item isKindOfClass:[UIImage class]]) {
                    // maybe crash here, but gallery usually returns NSURL
                    sharedData = UIImageJPEGRepresentation((UIImage *)item, 1);
                } else if ([(NSObject *)item isKindOfClass:[NSURL class]]){
                    NSURL *url = (NSURL *)item;
                    sharedData = [NSData dataWithContentsOfURL: url];
                }

                [fileManager createFileAtPath:fullPath contents:sharedData attributes:nil];

                if ([fileManager fileExistsAtPath:fullPath]) {
                    NSLog(@"Image stored");
                }

                NSString *suggestedName = @"";
                if ([itemProvider respondsToSelector:NSSelectorFromString(@"getSuggestedName")]) {
                    suggestedName = [itemProvider valueForKey:@"suggestedName"];
                }

                NSDictionary *dict = @{
                    @"backURL": self.backURL != nil ? self.backURL : @"",
                    @"text": @"",
                    @"path": fullPath,
                    @"uti": uti,
                    @"utis": itemProvider.registeredTypeIdentifiers,
                    @"name": suggestedName
                };

                [dataArray addObject:dict];
                dispatch_group_leave(dispatchGroup);
            }];
        }
        if ([itemProvider hasItemConformingToTypeIdentifier:@"public.movie"]) {
            dispatch_group_enter(dispatchGroup);
            [self debug:@"[public.movie]"];

            [self debug:[NSString stringWithFormat:@"item provider = %@", itemProvider]];

            [itemProvider loadItemForTypeIdentifier:@"public.movie" options:nil completionHandler: ^(NSURL *itemUrl, NSError *error) {

                NSLog(@"itemUrl.path: %@", itemUrl.path);

                NSString *fullPath = [tmpDir stringByAppendingPathComponent:[itemUrl.path lastPathComponent]];

                BOOL success = [fileManager copyItemAtPath:itemUrl.path toPath:fullPath error:&error];
                if (success) {
                    NSLog(@"Video stored");
                }

                NSDictionary *dict = @{
                                       @"backURL": self.backURL != nil ? self.backURL : @"",
                                       @"text": @"",
                                       @"path": fullPath,
                                       @"uti": @"public.movie",
                                       @"utis": itemProvider.registeredTypeIdentifiers,
                                       @"name": @""
                                       };

                [dataArray addObject:dict];
                dispatch_group_leave(dispatchGroup);
            }];
        }
    }
    dispatch_group_leave(dispatchGroup);

    dispatch_group_notify(dispatchGroup, dispatch_get_main_queue(),^{
        NSLog(@"dispatch_get_main_queue");

        [self.userDefaults setObject:dataArray forKey:@"shareData"];
        [self.userDefaults synchronize];

        // Emit a URL that opens the cordova app
        NSString *url = [NSString stringWithFormat:@"%@://shareData", SHAREEXT_URL_SCHEME];

        // Not allowed:
        // [[UIApplication sharedApplication] openURL:[NSURL URLWithString:url]];

        // Crashes:
        // [self.extensionContext openURL:[NSURL URLWithString:url] completionHandler:nil];

        // From https://stackoverflow.com/a/25750229/2343390
        // Reported not to work since iOS 8.3
        // NSURLRequest *request = [[NSURLRequest alloc] initWithURL:[NSURL URLWithString:url]];
        // [self.webView loadRequest:request];

        [self openURL:[NSURL URLWithString:url]];

        // Inform the host that we're done, so it un-blocks its UI.
        [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
    });

    // Inform the host that we're done, so it un-blocks its UI.
    // [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
}

- (NSArray*) configurationItems {
    // To add configuration options via table cells at the bottom of the sheet, return an array of SLComposeSheetConfigurationItem here.
    return @[];
}

- (NSString*) backURLFromBundleID: (NSString*)bundleId {
    if (bundleId == nil) return nil;
    // App Store - com.apple.AppStore
    if ([bundleId isEqualToString:@"com.apple.AppStore"]) return @"itms-apps://";
    // Calculator - com.apple.calculator
    // Calendar - com.apple.mobilecal
    // Camera - com.apple.camera
    // Clock - com.apple.mobiletimer
    // Compass - com.apple.compass
    // Contacts - com.apple.MobileAddressBook
    // FaceTime - com.apple.facetime
    // Find Friends - com.apple.mobileme.fmf1
    // Find iPhone - com.apple.mobileme.fmip1
    // Game Center - com.apple.gamecenter
    // Health - com.apple.Health
    // iBooks - com.apple.iBooks
    // iTunes Store - com.apple.MobileStore
    // Mail - com.apple.mobilemail - message://
    if ([bundleId isEqualToString:@"com.apple.mobilemail"]) return @"message://";
    // Maps - com.apple.Maps - maps://
    if ([bundleId isEqualToString:@"com.apple.Maps"]) return @"maps://";
    // Messages - com.apple.MobileSMS
    // Music - com.apple.Music
    // News - com.apple.news - applenews://
    if ([bundleId isEqualToString:@"com.apple.news"]) return @"applenews://";
    // Notes - com.apple.mobilenotes - mobilenotes://
    if ([bundleId isEqualToString:@"com.apple.mobilenotes"]) return @"mobilenotes://";
    // Phone - com.apple.mobilephone
    // Photos - com.apple.mobileslideshow
    if ([bundleId isEqualToString:@"com.apple.mobileslideshow"]) return @"photos-redirect://";
    // Podcasts - com.apple.podcasts
    // Reminders - com.apple.reminders - x-apple-reminder://
    if ([bundleId isEqualToString:@"com.apple.reminders"]) return @"x-apple-reminder://";
    // Safari - com.apple.mobilesafari
    // Settings - com.apple.Preferences
    // Stocks - com.apple.stocks
    // Tips - com.apple.tips
    // Videos - com.apple.videos - videos://
    if ([bundleId isEqualToString:@"com.apple.videos"]) return @"videos://";
    // Voice Memos - com.apple.VoiceMemos - voicememos://
    if ([bundleId isEqualToString:@"com.apple.VoiceMemos"]) return @"voicememos://";
    // Wallet - com.apple.Passbook
    // Watch - com.apple.Bridge
    // Weather - com.apple.weather
    return nil;
}

// This is called at the point where the Post dialog is about to be shown.
// We use it to store the _hostBundleID
- (void) willMoveToParentViewController: (UIViewController*)parent {
    NSString *hostBundleID = [parent valueForKey:(@"_hostBundleID")];
    self.backURL = [self backURLFromBundleID:hostBundleID];
}

@end
