// ICSettingsViewController.m — Tab 4: Settings
// Daemon control (spawn/kill), Open Web IDE, app version info

#import "ICSettingsViewController.h"
#import "AppDelegate.h"
#import "ICDaemonLauncher.h"

static const int kDaemonPort = 46952;

#define IC_BG [UIColor colorWithRed:0.06 green:0.06 blue:0.10 alpha:1]
#define IC_SURFACE [UIColor colorWithRed:0.11 green:0.11 blue:0.18 alpha:1]
#define IC_ACCENT [UIColor colorWithRed:0.42 green:0.39 blue:1.00 alpha:1]
#define IC_TEXT [UIColor colorWithWhite:0.92 alpha:1]
#define IC_SUBTEXT [UIColor colorWithWhite:0.55 alpha:1]
#define IC_GREEN [UIColor colorWithRed:0.20 green:0.85 blue:0.50 alpha:1]
#define IC_RED [UIColor colorWithRed:1.00 green:0.30 blue:0.35 alpha:1]

typedef NS_ENUM(NSInteger, ICSettingsRow) {
  kRowRestartDaemon,
  kRowStopDaemon,
  kRowOpenWebIDE,
  kRowCopyURL,
  kRowVersion,
  kRowCount
};

@interface ICSettingsViewController () <UITableViewDataSource,
                                        UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UILabel *daemonBadge;
@end

@implementation ICSettingsViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Settings";
  self.view.backgroundColor = IC_BG;

  // Nav bar
  UINavigationBarAppearance *nav = [UINavigationBarAppearance new];
  [nav configureWithOpaqueBackground];
  nav.backgroundColor = IC_SURFACE;
  nav.titleTextAttributes = @{NSForegroundColorAttributeName : IC_TEXT};
  self.navigationController.navigationBar.standardAppearance = nav;
  self.navigationController.navigationBar.scrollEdgeAppearance = nav;
  self.navigationController.navigationBar.tintColor = IC_ACCENT;

  // Daemon status badge in navbar
  self.daemonBadge = [[UILabel alloc] init];
  self.daemonBadge.text = @"⬤  —";
  self.daemonBadge.textColor = IC_SUBTEXT;
  self.daemonBadge.font = [UIFont systemFontOfSize:13
                                            weight:UIFontWeightMedium];
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithCustomView:self.daemonBadge];

  // TableView
  self.tableView =
      [[UITableView alloc] initWithFrame:CGRectZero
                                   style:UITableViewStyleInsetGrouped];
  self.tableView.backgroundColor = IC_BG;
  self.tableView.separatorColor = [UIColor colorWithWhite:0.2 alpha:1];
  self.tableView.dataSource = self;
  self.tableView.delegate = self;
  self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.tableView];

  [NSLayoutConstraint activateConstraints:@[
    [self.tableView.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [self.tableView.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor],
    [self.tableView.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    [self.tableView.bottomAnchor
        constraintEqualToAnchor:self.view.bottomAnchor],
  ]];

  [self checkDaemon];
  [NSTimer scheduledTimerWithTimeInterval:5.0
                                   target:self
                                 selector:@selector(checkDaemon)
                                 userInfo:nil
                                  repeats:YES];
}

- (void)checkDaemon {
  [[ICDaemonLauncher shared]
      checkStatusWithCompletion:^(BOOL alive, NSString *version) {
        if (alive) {
          self.daemonBadge.text =
              [NSString stringWithFormat:@"⬤  Running %@", version];
          self.daemonBadge.textColor = IC_GREEN;
        } else {
          self.daemonBadge.text = @"⬤  Offline";
          self.daemonBadge.textColor = IC_RED;
        }
      }];
}

// ── TableView
// ─────────────────────────────────────────────────────────────────

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv {
  return 3;
}

- (NSInteger)tableView:(UITableView *)tv
    numberOfRowsInSection:(NSInteger)section {
  switch (section) {
  case 0:
    return 2; // Restart / Stop
  case 1:
    return 2; // Open Web IDE / Copy URL
  case 2:
    return 1; // Version
  default:
    return 0;
  }
}

- (NSString *)tableView:(UITableView *)tv
    titleForHeaderInSection:(NSInteger)section {
  switch (section) {
  case 0:
    return @"Daemon Control";
  case 1:
    return @"Web IDE";
  case 2:
    return @"About";
  default:
    return nil;
  }
}

- (NSString *)tableView:(UITableView *)tv
    titleForFooterInSection:(NSInteger)section {
  if (section == 0) {
    return [NSString
        stringWithFormat:@"Daemon listens on port %d. Survives app kills.",
                         kDaemonPort];
  }
  if (section == 2) {
    return @"IOSControl — Non-jailbroken iOS automation\nBuilt with TrollStore "
           @"+ Lua 5.4";
  }
  return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell =
      [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                             reuseIdentifier:nil];
  cell.backgroundColor = IC_SURFACE;
  cell.textLabel.textColor = IC_TEXT;
  cell.detailTextLabel.textColor = IC_SUBTEXT;
  cell.selectionStyle = UITableViewCellSelectionStyleDefault;

  if (ip.section == 0) {
    if (ip.row == 0) {
      cell.textLabel.text = @"Restart Daemon";
      cell.imageView.image =
          [UIImage systemImageNamed:@"arrow.clockwise.circle.fill"];
      cell.imageView.tintColor = IC_ACCENT;
    } else {
      cell.textLabel.text = @"Stop Daemon";
      cell.imageView.image = [UIImage systemImageNamed:@"stop.circle.fill"];
      cell.imageView.tintColor = IC_RED;
      cell.textLabel.textColor = IC_RED;
    }
  } else if (ip.section == 1) {
    if (ip.row == 0) {
      cell.textLabel.text = @"Open Web IDE in Safari";
      cell.imageView.image = [UIImage systemImageNamed:@"safari.fill"];
      cell.imageView.tintColor = IC_ACCENT;
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
      cell.textLabel.text = @"Copy Web IDE URL";
      cell.imageView.image = [UIImage systemImageNamed:@"link"];
      cell.imageView.tintColor = IC_SUBTEXT;
    }
  } else {
    cell.textLabel.text = @"IOSControl";
    cell.detailTextLabel.text = @"v0.7.0 — Phase 8";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.imageView.image = [UIImage systemImageNamed:@"app.badge"];
    cell.imageView.tintColor = IC_ACCENT;
  }

  return cell;
}

- (CGFloat)tableView:(UITableView *)tv
    heightForRowAtIndexPath:(NSIndexPath *)ip {
  return 56;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [tv deselectRowAtIndexPath:ip animated:YES];

  if (ip.section == 0 && ip.row == 0) {
    // Restart daemon
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Restart Daemon?"
                         message:@"Will kill and respawn the IOSControl daemon."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert
        addAction:
            [UIAlertAction
                actionWithTitle:@"Restart"
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *a) {
                          AppDelegate *app =
                              (AppDelegate *)[UIApplication sharedApplication]
                                  .delegate;
                          [app pauseWatchdog];
                          // Kill old daemon first so port 46952 is freed
                          [[ICDaemonLauncher shared] killDaemon];
                          // 300ms delay → port releases → then spawn fresh
                          dispatch_after(
                              dispatch_time(DISPATCH_TIME_NOW,
                                            300 * NSEC_PER_MSEC),
                              dispatch_get_main_queue(), ^{
                                [[ICDaemonLauncher
                                    shared] spawnDaemonWithCompletion:^(BOOL
                                                                            ok) {
                                  [app resumeWatchdog];
                                  [self checkDaemon];
                                  dispatch_async(dispatch_get_main_queue(), ^{
                                    NSString *msg =
                                        ok ? @"✅ Daemon restarted."
                                           : @"❌ Daemon spawn failed.";
                                    UIAlertController *r = [UIAlertController
                                        alertControllerWithTitle:ok ? @"Success"
                                                                    : @"Failed"
                                                         message:msg
                                                  preferredStyle:
                                                      UIAlertControllerStyleAlert];
                                    [r addAction:
                                            [UIAlertAction
                                                actionWithTitle:@"OK"
                                                          style:
                                                              UIAlertActionStyleDefault
                                                        handler:nil]];
                                    [self presentViewController:r
                                                       animated:YES
                                                     completion:nil];
                                  });
                                }];
                              });
                        }]];
    [self presentViewController:alert animated:YES completion:nil];

  } else if (ip.section == 0 && ip.row == 1) {
    // Stop daemon — also pause watchdog so it doesn't immediately respawn
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Stop Daemon?"
                         message:@"Daemon will be killed. Watchdog will be "
                                 @"paused \u2014 tap Restart to bring it back."
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert
        addAction:[UIAlertAction
                      actionWithTitle:@"Stop"
                                style:UIAlertActionStyleDestructive
                              handler:^(UIAlertAction *a) {
                                // Pause watchdog FIRST so it doesn't
                                // respawn killed daemon
                                AppDelegate *app =
                                    (AppDelegate *)
                                        [UIApplication sharedApplication]
                                            .delegate;
                                [app pauseWatchdog];

                                [[ICDaemonLauncher shared] killDaemon];
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                             NSEC_PER_SEC / 2),
                                               dispatch_get_main_queue(), ^{
                                                 [self checkDaemon];
                                               });
                              }]];
    [self presentViewController:alert animated:YES completion:nil];

  } else if (ip.section == 1 && ip.row == 0) {
    // Open Web IDE
    NSString *urlStr =
        [NSString stringWithFormat:@"http://127.0.0.1:%d/", kDaemonPort];
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlStr]
                                       options:@{}
                             completionHandler:nil];

  } else if (ip.section == 1 && ip.row == 1) {
    // Copy URL
    NSString *urlStr =
        [NSString stringWithFormat:@"http://127.0.0.1:%d/", kDaemonPort];
    [[UIPasteboard generalPasteboard] setString:urlStr];
    // Visual feedback
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
    cell.detailTextLabel.text = @"Copied!";
    cell.detailTextLabel.textColor = IC_GREEN;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
                     [tv reloadRowsAtIndexPaths:@[ ip ]
                               withRowAnimation:UITableViewRowAnimationNone];
                   });
  }
}

@end
