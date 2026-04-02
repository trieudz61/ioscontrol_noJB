// ICAppControl.h — App launch/kill/list for IOSControl daemon
// Uses LSApplicationWorkspace (private framework, available in daemon with
// entitlements)

#pragma once
#import <Foundation/Foundation.h>

// List all installed apps → NSArray of NSDictionary {bundleID, name, version}
NSArray<NSDictionary *> *ic_appList(void);

// Launch app by bundle ID → YES on success
BOOL ic_appLaunch(NSString *bundleID);

// Kill app by bundle ID → YES on success
BOOL ic_appKill(NSString *bundleID);

// Check if app is running → YES/NO
BOOL ic_appIsRunning(NSString *bundleID);

// Get frontmost app bundle ID → NSString (nil if none)
NSString *ic_appFrontmost(void);
