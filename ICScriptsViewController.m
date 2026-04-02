// ICScriptsViewController.m — Tab 1: Script list + run
// Lists .lua files from daemon via /api/script/list
// Tap to run, long press to delete, + button to create new

#import "ICScriptsViewController.h"

static const int kDaemonPort = 46952;
static NSString *const kAccent = nil; // set in IC_COLORS

// ─── Design tokens ───────────────────────────────────────────────────────────
#define IC_BG [UIColor colorWithRed:0.06 green:0.06 blue:0.10 alpha:1]
#define IC_SURFACE [UIColor colorWithRed:0.11 green:0.11 blue:0.18 alpha:1]
#define IC_ACCENT [UIColor colorWithRed:0.42 green:0.39 blue:1.00 alpha:1]
#define IC_GREEN [UIColor colorWithRed:0.20 green:0.85 blue:0.50 alpha:1]
#define IC_RED [UIColor colorWithRed:1.00 green:0.30 blue:0.35 alpha:1]
#define IC_TEXT [UIColor colorWithWhite:0.92 alpha:1]
#define IC_SUBTEXT [UIColor colorWithWhite:0.55 alpha:1]

@interface ICScriptsViewController () <UITableViewDataSource,
                                       UITableViewDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSMutableArray<NSString *> *scripts;
@property(nonatomic, strong) UILabel *statusBadge;
@property(nonatomic, strong) NSString *runningScript; // nil if idle
@end

@implementation ICScriptsViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Scripts";
  self.view.backgroundColor = IC_BG;

  // Navigation bar style
  UINavigationBarAppearance *nav = [UINavigationBarAppearance new];
  [nav configureWithOpaqueBackground];
  nav.backgroundColor = IC_SURFACE;
  nav.titleTextAttributes = @{NSForegroundColorAttributeName : IC_TEXT};
  self.navigationController.navigationBar.standardAppearance = nav;
  self.navigationController.navigationBar.scrollEdgeAppearance = nav;
  self.navigationController.navigationBar.tintColor = IC_ACCENT;

  // + button
  UIBarButtonItem *addBtn = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                           target:self
                           action:@selector(newScriptTapped)];
  self.navigationItem.rightBarButtonItem = addBtn;

  // Status badge (running / idle)
  self.statusBadge = [[UILabel alloc] init];
  self.statusBadge.text = @"⬤  idle";
  self.statusBadge.textColor = IC_SUBTEXT;
  self.statusBadge.font =
      [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithCustomView:self.statusBadge];

  // TableView setup
  self.scripts = [NSMutableArray array];
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

  // Pull-to-refresh
  UIRefreshControl *refresh = [UIRefreshControl new];
  [refresh addTarget:self
                action:@selector(loadScripts)
      forControlEvents:UIControlEventValueChanged];
  self.tableView.refreshControl = refresh;

  [self loadScripts];

  // Poll script status every second
  [NSTimer scheduledTimerWithTimeInterval:1.0
                                   target:self
                                 selector:@selector(pollStatus)
                                 userInfo:nil
                                  repeats:YES];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self loadScripts];
}

// ── Data
// ──────────────────────────────────────────────────────────────────────

- (void)loadScripts {
  NSURL *url = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://127.0.0.1:%d/api/script/list",
                                         kDaemonPort]];
  [[[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self.tableView.refreshControl endRefreshing];
          });
          return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d
                                                             options:0
                                                               error:nil];
        NSArray *list = json[@"scripts"] ?: @[];
        dispatch_async(dispatch_get_main_queue(), ^{
          [self.scripts removeAllObjects];
          [self.scripts addObjectsFromArray:list];
          [self.tableView reloadData];
          [self.tableView.refreshControl endRefreshing];
        });
      }] resume];
}

- (void)pollStatus {
  NSURL *url = [NSURL
      URLWithString:
          [NSString stringWithFormat:@"http://127.0.0.1:%d/api/script/status",
                                     kDaemonPort]];
  [[[NSURLSession sharedSession]
        dataTaskWithURL:url
      completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d)
          return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d
                                                             options:0
                                                               error:nil];
        NSString *status = json[@"status"] ?: @"idle";
        dispatch_async(dispatch_get_main_queue(), ^{
          if ([status isEqualToString:@"running"]) {
            self.statusBadge.text = @"⬤  running";
            self.statusBadge.textColor = IC_GREEN;
          } else if ([status isEqualToString:@"error"]) {
            self.statusBadge.text = @"⬤  error";
            self.statusBadge.textColor = IC_RED;
          } else {
            self.statusBadge.text = @"⬤  idle";
            self.statusBadge.textColor = IC_SUBTEXT;
          }
        });
      }] resume];
}

// ── Actions
// ───────────────────────────────────────────────────────────────────

- (void)newScriptTapped {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"New Script"
                       message:@"Enter script name (without .lua)"
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
    tf.placeholder = @"myscript";
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"Create"
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction *a) {
                        NSString *name = alert.textFields.firstObject.text;
                        if (!name.length)
                          return;
                        // Ensure .lua extension
                        if (![name hasSuffix:@".lua"])
                          name = [name stringByAppendingString:@".lua"];
                        NSString *tmpl = [NSString
                            stringWithFormat:
                                @"-- %@\n-- Created by "
                                @"IOSControl\n\nsys.log(\"Running %@\")\n",
                                name, name];
                        [self saveScript:name content:tmpl];
                        // BUG-3 fix: open Web Editor for the new script
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(0.5 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                              NSString *encodedName = [name
                                  stringByAddingPercentEncodingWithAllowedCharacters:
                                      NSCharacterSet
                                          .URLQueryAllowedCharacterSet];
                              NSString *urlStr =
                                  [NSString stringWithFormat:
                                                @"http://127.0.0.1:%d/static/"
                                                @"script_edit.html#%@",
                                                kDaemonPort, encodedName];
                              NSURL *url = [NSURL URLWithString:urlStr];
                              Class safariCls =
                                  NSClassFromString(@"SFSafariViewController");
                              if (safariCls && url) {
                                id vc = [[safariCls alloc] initWithURL:url];
                                [self presentViewController:vc
                                                   animated:YES
                                                 completion:nil];
                              }
                            });
                      }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)runScript:(NSString *)name {
  // Read content then POST to /api/script/run
  NSURL *readURL = [NSURL
      URLWithString:
          [NSString
              stringWithFormat:
                  @"http://127.0.0.1:%d/api/script/file?name=%@", kDaemonPort,
                  [name stringByAddingPercentEncodingWithAllowedCharacters:
                            NSCharacterSet.URLQueryAllowedCharacterSet]]];

  [[[NSURLSession sharedSession]
        dataTaskWithURL:readURL
      completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!d)
          return;
        NSString *code = [[NSString alloc] initWithData:d
                                               encoding:NSUTF8StringEncoding];
        if (!code.length)
          return;

        NSURL *runURL = [NSURL
            URLWithString:[NSString stringWithFormat:
                                        @"http://127.0.0.1:%d/api/script/run",
                                        kDaemonPort]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:runURL];
        req.HTTPMethod = @"POST";
        req.HTTPBody = [code dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
        [[[NSURLSession sharedSession]
            dataTaskWithRequest:req
              completionHandler:^(NSData *d2, NSURLResponse *r2, NSError *e2){
              }] resume];
      }] resume];
}

- (void)stopScript {
  NSURL *url = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://127.0.0.1:%d/api/script/stop",
                                         kDaemonPort]];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"POST";
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e){
        }] resume];
}

- (void)deleteScript:(NSString *)name {
  NSString *encoded = [name stringByAddingPercentEncodingWithAllowedCharacters:
                                NSCharacterSet.URLQueryAllowedCharacterSet];
  NSURL *url = [NSURL
      URLWithString:
          [NSString
              stringWithFormat:@"http://127.0.0.1:%d/api/script/file?name=%@",
                               kDaemonPort, encoded]];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"DELETE";
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self loadScripts];
          });
        }] resume];
}

- (void)saveScript:(NSString *)name content:(NSString *)content {
  NSString *encoded = [name stringByAddingPercentEncodingWithAllowedCharacters:
                                NSCharacterSet.URLQueryAllowedCharacterSet];
  NSURL *url = [NSURL
      URLWithString:
          [NSString
              stringWithFormat:@"http://127.0.0.1:%d/api/script/file?name=%@",
                               kDaemonPort, encoded]];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"PUT";
  req.HTTPBody = [content dataUsingEncoding:NSUTF8StringEncoding];
  [req setValue:@"text/plain" forHTTPHeaderField:@"Content-Type"];
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [self loadScripts];
          });
        }] resume];
}

// ── TableView
// ─────────────────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tv
    numberOfRowsInSection:(NSInteger)section {
  return self.scripts.count ?: 1; // show placeholder if empty
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
  UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"sc"];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:@"sc"];
  }
  cell.backgroundColor = IC_SURFACE;
  cell.textLabel.textColor = IC_TEXT;
  cell.detailTextLabel.textColor = IC_SUBTEXT;
  cell.selectionStyle = UITableViewCellSelectionStyleDefault;

  if (self.scripts.count == 0) {
    cell.textLabel.text = @"No scripts yet";
    cell.detailTextLabel.text = @"Tap + to create one";
    cell.textLabel.textColor = IC_SUBTEXT;
    cell.userInteractionEnabled = NO;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
  }

  NSString *name = self.scripts[ip.row];
  cell.textLabel.text = name;
  cell.detailTextLabel.text = @".lua";
  cell.userInteractionEnabled = YES;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  cell.imageView.image = [UIImage systemImageNamed:@"doc.text.fill"];
  cell.imageView.tintColor = IC_ACCENT;
  return cell;
}

- (CGFloat)tableView:(UITableView *)tv
    heightForRowAtIndexPath:(NSIndexPath *)ip {
  return 60;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
  [tv deselectRowAtIndexPath:ip animated:YES];
  if (self.scripts.count == 0)
    return;
  NSString *name = self.scripts[ip.row];

  // Action sheet: Run / Stop / Delete
  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:name
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  [sheet addAction:[UIAlertAction actionWithTitle:@"▶  Run Script"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) {
                                            [self runScript:name];
                                          }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"⏹  Stop Running Script"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *a) {
                                            [self stopScript];
                                          }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"🗑  Delete"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *a) {
                                            [self deleteScript:name];
                                          }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [self presentViewController:sheet animated:YES completion:nil];
}

// Swipe-to-delete
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
  if (self.scripts.count == 0)
    return nil;
  NSString *name = self.scripts[ip.row];
  UIContextualAction *del = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleDestructive
                          title:@"Delete"
                        handler:^(UIContextualAction *a, UIView *v,
                                  void (^done)(BOOL)) {
                          [self deleteScript:name];
                          done(YES);
                        }];
  del.image = [UIImage systemImageNamed:@"trash.fill"];
  return [UISwipeActionsConfiguration configurationWithActions:@[ del ]];
}

@end
