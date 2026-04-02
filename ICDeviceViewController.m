// ICDeviceViewController.m — Tab 3: Live device info
// Polls /api/device/info every 3s, shows model/iOS/screen/memory/status

#import "ICDeviceViewController.h"

static const int kDaemonPort = 46952;

#define IC_BG [UIColor colorWithRed:0.06 green:0.06 blue:0.10 alpha:1]
#define IC_SURFACE [UIColor colorWithRed:0.11 green:0.11 blue:0.18 alpha:1]
#define IC_ACCENT [UIColor colorWithRed:0.42 green:0.39 blue:1.00 alpha:1]
#define IC_TEXT [UIColor colorWithWhite:0.92 alpha:1]
#define IC_SUBTEXT [UIColor colorWithWhite:0.55 alpha:1]
#define IC_GREEN [UIColor colorWithRed:0.20 green:0.85 blue:0.50 alpha:1]
#define IC_RED [UIColor colorWithRed:1.00 green:0.30 blue:0.35 alpha:1]

@interface ICDeviceViewController ()
@property(nonatomic, strong) NSMutableArray<UILabel *> *valueLabels;
@property(nonatomic, strong) UILabel *daemonStatus;
@property(nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation ICDeviceViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Device";
  self.view.backgroundColor = IC_BG;
  self.valueLabels = [NSMutableArray array];

  // Nav bar
  UINavigationBarAppearance *nav = [UINavigationBarAppearance new];
  [nav configureWithOpaqueBackground];
  nav.backgroundColor = IC_SURFACE;
  nav.titleTextAttributes = @{NSForegroundColorAttributeName : IC_TEXT};
  self.navigationController.navigationBar.standardAppearance = nav;
  self.navigationController.navigationBar.scrollEdgeAppearance = nav;
  self.navigationController.navigationBar.tintColor = IC_ACCENT;

  UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc]
      initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
              style:UIBarButtonItemStylePlain
             target:self
             action:@selector(fetchInfo)];
  self.navigationItem.rightBarButtonItem = refreshBtn;

  [self buildUI];
  [self fetchInfo];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  self.refreshTimer =
      [NSTimer scheduledTimerWithTimeInterval:3.0
                                       target:self
                                     selector:@selector(fetchInfo)
                                     userInfo:nil
                                      repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [self.refreshTimer invalidate];
  self.refreshTimer = nil;
}

// ── UI
// ────────────────────────────────────────────────────────────────────────

- (void)buildUI {
  UIScrollView *scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:scroll];

  UIView *container = [[UIView alloc] init];
  container.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:container];

  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [container.topAnchor constraintEqualToAnchor:scroll.topAnchor],
    [container.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [container.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
    [container.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
    [container.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
  ]];

  // Daemon status banner
  UIView *banner = [[UIView alloc] init];
  banner.backgroundColor = IC_SURFACE;
  banner.layer.cornerRadius = 14;
  banner.translatesAutoresizingMaskIntoConstraints = NO;
  [container addSubview:banner];

  UILabel *bannerTitle = [[UILabel alloc] init];
  bannerTitle.text = @"IOSControl Daemon";
  bannerTitle.textColor = IC_TEXT;
  bannerTitle.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  bannerTitle.translatesAutoresizingMaskIntoConstraints = NO;
  [banner addSubview:bannerTitle];

  self.daemonStatus = [[UILabel alloc] init];
  self.daemonStatus.text = @"⬤  Checking…";
  self.daemonStatus.textColor = IC_SUBTEXT;
  self.daemonStatus.font = [UIFont systemFontOfSize:14
                                             weight:UIFontWeightMedium];
  self.daemonStatus.translatesAutoresizingMaskIntoConstraints = NO;
  [banner addSubview:self.daemonStatus];

  [NSLayoutConstraint activateConstraints:@[
    [banner.topAnchor constraintEqualToAnchor:container.topAnchor constant:20],
    [banner.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                         constant:16],
    [banner.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                          constant:-16],
    [bannerTitle.topAnchor constraintEqualToAnchor:banner.topAnchor
                                          constant:14],
    [bannerTitle.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor
                                              constant:16],
    [self.daemonStatus.topAnchor
        constraintEqualToAnchor:bannerTitle.bottomAnchor
                       constant:4],
    [self.daemonStatus.leadingAnchor
        constraintEqualToAnchor:banner.leadingAnchor
                       constant:16],
    [self.daemonStatus.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor
                                                   constant:-14],
  ]];

  // Info cards
  NSArray *fields = @[
    @[ @"📱 Model", @"—" ],
    @[ @"🍎 iOS Version", @"—" ],
    @[ @"📺 Screen", @"—" ],
    @[ @"🧠 Memory Total", @"—" ],
    @[ @"💾 Memory Used", @"—" ],
    @[ @"🔢 Daemon PID", @"—" ],
    @[ @"🌐 Daemon Version", @"—" ],
  ];

  UIView *prevCard = banner;
  for (int i = 0; i < (int)fields.count; i++) {
    UIView *card = [self makeCard:fields[i][0] value:fields[i][1] tag:i];
    [container addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
      [card.topAnchor constraintEqualToAnchor:prevCard.bottomAnchor
                                     constant:12],
      [card.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                         constant:16],
      [card.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                          constant:-16],
    ]];
    if (i == (int)fields.count - 1) {
      [container.bottomAnchor constraintEqualToAnchor:card.bottomAnchor
                                             constant:30]
          .active = YES;
    }
    prevCard = card;
  }
}

- (UIView *)makeCard:(NSString *)label
               value:(NSString *)val
                 tag:(NSInteger)tag {
  UIView *card = [[UIView alloc] init];
  card.backgroundColor = IC_SURFACE;
  card.layer.cornerRadius = 12;
  card.translatesAutoresizingMaskIntoConstraints = NO;

  UILabel *keyLbl = [[UILabel alloc] init];
  keyLbl.text = label;
  keyLbl.textColor = IC_SUBTEXT;
  keyLbl.font = [UIFont systemFontOfSize:13];
  keyLbl.translatesAutoresizingMaskIntoConstraints = NO;

  UILabel *valLbl = [[UILabel alloc] init];
  valLbl.text = val;
  valLbl.textColor = IC_TEXT;
  valLbl.font = [UIFont monospacedSystemFontOfSize:15
                                            weight:UIFontWeightMedium];
  valLbl.translatesAutoresizingMaskIntoConstraints = NO;
  valLbl.tag = 1000 + tag;
  [self.valueLabels addObject:valLbl];

  [card addSubview:keyLbl];
  [card addSubview:valLbl];

  [NSLayoutConstraint activateConstraints:@[
    [keyLbl.topAnchor constraintEqualToAnchor:card.topAnchor constant:12],
    [keyLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                         constant:16],
    [valLbl.topAnchor constraintEqualToAnchor:keyLbl.bottomAnchor constant:2],
    [valLbl.leadingAnchor constraintEqualToAnchor:card.leadingAnchor
                                         constant:16],
    [valLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor
                                          constant:-16],
    [valLbl.bottomAnchor constraintEqualToAnchor:card.bottomAnchor
                                        constant:-12],
  ]];

  return card;
}

// ── Data
// ──────────────────────────────────────────────────────────────────────

- (void)fetchInfo {
  NSURL *url = [NSURL
      URLWithString:[NSString
                        stringWithFormat:@"http://127.0.0.1:%d/api/device/info",
                                         kDaemonPort]];
  NSURLRequest *req =
      [NSURLRequest requestWithURL:url
                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                   timeoutInterval:2.0];
  [[[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (!d || e) {
              self.daemonStatus.text = @"⬤  Offline";
              self.daemonStatus.textColor = IC_RED;
              return;
            }
            NSDictionary *info = [NSJSONSerialization JSONObjectWithData:d
                                                                 options:0
                                                                   error:nil];
            if (!info[@"ok"])
              return;

            self.daemonStatus.text = [NSString
                stringWithFormat:@"⬤  Running (port %d)", kDaemonPort];
            self.daemonStatus.textColor = IC_GREEN;

            CGFloat w = [info[@"screenWidth"] floatValue];
            CGFloat h = [info[@"screenHeight"] floatValue];
            NSArray *vals = @[
              info[@"model"] ?: @"—",
              [NSString stringWithFormat:@"%@ %@",
                                         info[@"systemName"] ?: @"iOS",
                                         info[@"systemVersion"] ?: @"—"],
              [NSString stringWithFormat:@"%.0f × %.0f", w, h],
              [NSString
                  stringWithFormat:@"%@ MB", info[@"totalMemoryMB"] ?: @"—"],
              [NSString
                  stringWithFormat:@"%@ MB", info[@"usedMemoryMB"] ?: @"—"],
              [NSString stringWithFormat:@"%@", info[@"pid"] ?: @"—"],
              @"v0.7.0",
            ];

            for (int i = 0;
                 i < (int)vals.count && i < (int)self.valueLabels.count; i++) {
              self.valueLabels[i].text = vals[i];
            }
          });
        }] resume];
}

@end
