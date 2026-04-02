// ICConsoleViewController.m — Tab 2: Live daemon log console
// Polls /api/system/log every 1s, auto-scrolls, search, clear

#import "ICConsoleViewController.h"

static const int kDaemonPort = 46952;

#define IC_BG [UIColor colorWithRed:0.06 green:0.06 blue:0.10 alpha:1]
#define IC_SURFACE [UIColor colorWithRed:0.11 green:0.11 blue:0.18 alpha:1]
#define IC_ACCENT [UIColor colorWithRed:0.42 green:0.39 blue:1.00 alpha:1]
#define IC_TEXT [UIColor colorWithWhite:0.92 alpha:1]
#define IC_SUBTEXT [UIColor colorWithWhite:0.55 alpha:1]
#define IC_GREEN [UIColor colorWithRed:0.20 green:0.85 blue:0.50 alpha:1]
#define IC_YELLOW [UIColor colorWithRed:1.00 green:0.80 blue:0.20 alpha:1]
#define IC_RED [UIColor colorWithRed:1.00 green:0.30 blue:0.35 alpha:1]

@interface ICConsoleViewController ()
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, assign) BOOL isPaused;
@property(nonatomic, strong) NSString *lastLog;
@end

@implementation ICConsoleViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Console";
  self.view.backgroundColor = IC_BG;

  // Nav bar
  UINavigationBarAppearance *nav = [UINavigationBarAppearance new];
  [nav configureWithOpaqueBackground];
  nav.backgroundColor = IC_SURFACE;
  nav.titleTextAttributes = @{NSForegroundColorAttributeName : IC_TEXT};
  self.navigationController.navigationBar.standardAppearance = nav;
  self.navigationController.navigationBar.scrollEdgeAppearance = nav;
  self.navigationController.navigationBar.tintColor = IC_ACCENT;

  // Toolbar buttons
  UIBarButtonItem *clearBtn =
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"]
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(clearLog)];
  UIBarButtonItem *pauseBtn = [[UIBarButtonItem alloc]
      initWithImage:[UIImage systemImageNamed:@"pause.fill"]
              style:UIBarButtonItemStylePlain
             target:self
             action:@selector(togglePause)];
  pauseBtn.tag = 99;
  self.navigationItem.rightBarButtonItems = @[ clearBtn, pauseBtn ];

  // Log TextView (monospace, dark, selectable)
  self.logView = [[UITextView alloc] init];
  self.logView.backgroundColor = [UIColor colorWithRed:0.04
                                                 green:0.04
                                                  blue:0.08
                                                 alpha:1];
  self.logView.textColor = IC_TEXT;
  self.logView.font = [UIFont monospacedSystemFontOfSize:11.5
                                                  weight:UIFontWeightRegular];
  self.logView.editable = NO;
  self.logView.selectable = YES;
  self.logView.dataDetectorTypes = UIDataDetectorTypeNone;
  self.logView.translatesAutoresizingMaskIntoConstraints = NO;
  self.logView.contentInset = UIEdgeInsetsMake(8, 8, 8, 8);
  self.logView.layer.cornerRadius = 0;
  [self.view addSubview:self.logView];

  // Info label at top
  UILabel *hint = [[UILabel alloc] init];
  hint.text = @"  📡 Live daemon log";
  hint.backgroundColor = IC_SURFACE;
  hint.textColor = IC_SUBTEXT;
  hint.font = [UIFont systemFontOfSize:12];
  hint.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:hint];

  [NSLayoutConstraint activateConstraints:@[
    [hint.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [hint.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [hint.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [hint.heightAnchor constraintEqualToConstant:28],
    [self.logView.topAnchor constraintEqualToAnchor:hint.bottomAnchor],
    [self.logView.leadingAnchor
        constraintEqualToAnchor:self.view.leadingAnchor],
    [self.logView.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    [self.logView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
  ]];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                    target:self
                                                  selector:@selector(fetchLog)
                                                  userInfo:nil
                                                   repeats:YES];
  [self fetchLog];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [self.pollTimer invalidate];
  self.pollTimer = nil;
}

- (void)fetchLog {
  if (self.isPaused)
    return;
  NSURL *url = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://127.0.0.1:%d/api/system/log",
                                         kDaemonPort]];
  NSURLRequest *req =
      [NSURLRequest requestWithURL:url
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:1.5];
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          if (!d)
            return;
          NSString *text = [[NSString alloc] initWithData:d
                                                 encoding:NSUTF8StringEncoding];
          if ([text isEqualToString:self.lastLog])
            return; // no change
          self.lastLog = text;
          dispatch_async(dispatch_get_main_queue(), ^{
            // Colorize log lines
            NSMutableAttributedString *attr =
                [[NSMutableAttributedString alloc] init];
            NSArray *lines = [text componentsSeparatedByString:@"\n"];
            UIFont *font =
                [UIFont monospacedSystemFontOfSize:11.5
                                            weight:UIFontWeightRegular];

            for (NSString *line in lines) {
              UIColor *color = IC_TEXT;
              if ([line containsString:@"❌"] ||
                  [line containsString:@"Error"] ||
                  [line containsString:@"error"]) {
                color = IC_RED;
              } else if ([line containsString:@"⚠️"] ||
                         [line containsString:@"Warn"]) {
                color = IC_YELLOW;
              } else if ([line containsString:@"✅"] ||
                         [line containsString:@"🚀"] ||
                         [line containsString:@"🎮"]) {
                color = IC_GREEN;
              } else if ([line containsString:@"💬"] ||
                         [line containsString:@"[Lua]"]) {
                color = IC_ACCENT;
              } else if ([line hasPrefix:@"["]) {
                // timestamp lines
                color = IC_SUBTEXT;
              }
              NSDictionary *attrs = @{
                NSFontAttributeName : font,
                NSForegroundColorAttributeName : color
              };
              [attr appendAttributedString:
                        [[NSAttributedString alloc]
                            initWithString:[line stringByAppendingString:@"\n"]
                                attributes:attrs]];
            }

            self.logView.attributedText = attr;
            // Auto-scroll to bottom
            NSRange end = NSMakeRange(attr.length > 0 ? attr.length - 1 : 0, 1);
            [self.logView scrollRangeToVisible:end];
          });
        }] resume];
}

- (void)clearLog {
  NSURL *url = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://127.0.0.1:%d/api/system/log",
                                         kDaemonPort]];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"DELETE";
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          dispatch_async(dispatch_get_main_queue(), ^{
            self.lastLog = nil;
            self.logView.text = @"";
          });
        }] resume];
}

- (void)togglePause {
  self.isPaused = !self.isPaused;
  UIBarButtonItem *btn = self.navigationItem.rightBarButtonItems.lastObject;
  btn.image =
      [UIImage systemImageNamed:self.isPaused ? @"play.fill" : @"pause.fill"];
  btn.tintColor = self.isPaused ? [UIColor systemOrangeColor] : IC_ACCENT;
}

@end
