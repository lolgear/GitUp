//  Copyright (C) 2015-2019 Pierre-Olivier Latour <info@pol-online.net>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

#if !__has_feature(objc_arc)
#error This file requires ARC
#endif

#import "GIQuickViewController.h"
#import "GIDiffContentsViewController.h"
#import "GIDiffFilesViewController.h"
#import "GIViewController+Utilities.h"
#import "NSView+Embedding.h"

#import "GIInterface.h"
#import "XLFacilityMacros.h"

@interface GIQuickViewController () <GIDiffContentsViewControllerDelegate, GIDiffFilesViewControllerDelegate>
@property(nonatomic, weak) IBOutlet NSView* infoView;
@property(nonatomic, weak) IBOutlet NSScrollView* infoScrollView;
@property(nonatomic, weak) IBOutlet NSTextField* sha1TextField;
@property(nonatomic, weak) IBOutlet NSTextField* messageTextField;
@property(nonatomic, weak) IBOutlet NSTextField* authorTextField;
@property(nonatomic, weak) IBOutlet NSTextField* authorDateTextField;
@property(nonatomic, weak) IBOutlet NSTextField* committerTextField;
@property(nonatomic, weak) IBOutlet NSTextField* committerDateTextField;
@property(nonatomic, weak) IBOutlet NSView* contentsView;
@property(nonatomic, weak) IBOutlet NSView* filesView;
@property(nonatomic, weak) IBOutlet NSBox* separatorBox;
@property(nonatomic, weak) IBOutlet GIDualSplitView* mainSplitView;
@property(nonatomic, weak) IBOutlet GIDualSplitView* infoSplitView;

@property(nonatomic, weak) id <GIQuickViewControllerDelegate> delegate;

@property(nonatomic, copy) void(^willShowContextualMenu)(NSMenu *menu, GCDiffDelta *delta, GCIndexConflict *conflict);
@end

@implementation GIQuickViewController {
  GIDiffContentsViewController* _diffContentsViewController;
  GIDiffFilesViewController* _diffFilesViewController;
  NSDateFormatter* _dateFormatter;
  BOOL _disableFeedbackLoop;
  GCDiff* _diff;
}

#pragma mark - Initialization
- (instancetype)initWithRepository:(GCLiveRepository*)repository {
  if ((self = [super initWithRepository:repository])) {
    _dateFormatter = [[NSDateFormatter alloc] init];
    _dateFormatter.dateStyle = NSDateFormatterShortStyle;
    _dateFormatter.timeStyle = NSDateFormatterShortStyle;
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:NSSplitViewDidResizeSubviewsNotification object:nil];
}

#pragma mark - Compute sizes
- (void)_recomputeInfoViewFrame {
  NSRect frame = _infoView.frame;
  NSSize size = [(NSTextFieldCell*)_messageTextField.cell cellSizeForBounds:NSMakeRect(0, 0, _messageTextField.frame.size.width, HUGE_VALF)];
  CGFloat delta = ceil(size.height) - _messageTextField.frame.size.height;
  _infoView.frame = NSMakeRect(0, 0, frame.size.width, frame.size.height + delta);
}

- (void)_splitViewDidResizeSubviews:(NSNotification*)notification {
  if (!self.liveResizing) {
    [self _recomputeInfoViewFrame];
  }
}

#pragma mark - View Lifecycle
- (void)loadView {
  [super loadView];

  _diffContentsViewController = [[GIDiffContentsViewController alloc] initWithRepository:self.repository];
  _diffContentsViewController.delegate = self;
  _diffContentsViewController.emptyLabel = NSLocalizedString(@"No differences", nil);
//  [_contentsView replaceWithView:_diffContentsViewController.view];

  _diffFilesViewController = [[GIDiffFilesViewController alloc] initWithRepository:self.repository];
  _diffFilesViewController.delegate = self;
//  [_filesView replaceWithView:_diffFilesViewController.view];

  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_splitViewDidResizeSubviews:) name:NSSplitViewDidResizeSubviewsNotification object:_mainSplitView];
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_splitViewDidResizeSubviews:) name:NSSplitViewDidResizeSubviewsNotification object:_infoSplitView];
  
  [_contentsView embedView:_diffContentsViewController.view];
  [_filesView embedView:_diffFilesViewController.view];
}

#pragma mark - GIViewController
- (void)viewDidFinishLiveResize {
  [self _recomputeInfoViewFrame];
}

#pragma mark - Message Utilities
static inline void _AppendStringWithoutTrailingWhiteSpace(NSMutableString* string, NSString* append, NSRange range) {
  NSCharacterSet* set = [NSCharacterSet whitespaceCharacterSet];
  while (range.length) {
    if (![set characterIsMember:[append characterAtIndex:(range.location + range.length - 1)]]) {
      break;
    }
    range.length -= 1;
  }
  [string appendString:[append substringWithRange:range]];
}

static NSString* _CleanUpCommitMessage(NSString* message) {
  NSMutableString* string = [[NSMutableString alloc] init];
  NSRange range = NSMakeRange(0, message.length);
  NSCharacterSet* set = [NSCharacterSet alphanumericCharacterSet];
  while (range.length > 0) {
    NSRange subrange = [message rangeOfString:@"\n" options:0 range:range];
    if (subrange.location == NSNotFound) {
      _AppendStringWithoutTrailingWhiteSpace(string, message, range);
      break;
    }
    NSUInteger count = 0;
    while ((subrange.location + count < range.location + range.length) && ([message characterAtIndex:(subrange.location + count)] == '\n')) {
      ++count;
    }

    _AppendStringWithoutTrailingWhiteSpace(string, message, NSMakeRange(range.location, subrange.location - range.location));
    if (count > 1) {
      [string appendString:@"\n\n"];
    } else if (range.location + range.length - subrange.location - count > 0) {
      unichar nextCharacter = [message characterAtIndex:(subrange.location + 1)];
      if ([set characterIsMember:nextCharacter]) {
        [string appendString:@" "];
      } else {
        [string appendString:@"\n"];
      }
    }

    range = NSMakeRange(subrange.location + count, range.location + range.length - subrange.location - count);
  }
  return string;
}

#pragma mark - Accessors
- (void)setCommit:(GCHistoryCommit*)commit {
  if (commit != _commit) {
    _commit = commit;
    if (_commit) {
      _messageTextField.stringValue = _CleanUpCommitMessage(_commit.message);
      [self _recomputeInfoViewFrame];

      _sha1TextField.stringValue = _commit.SHA1;

      _authorDateTextField.stringValue = [NSString stringWithFormat:@"%@ (%@)", [_dateFormatter stringFromDate:_commit.authorDate], GIFormatDateRelativelyFromNow(_commit.authorDate, NO)];
      _committerDateTextField.stringValue = [NSString stringWithFormat:@"%@ (%@)", [_dateFormatter stringFromDate:_commit.committerDate], GIFormatDateRelativelyFromNow(_commit.committerDate, NO)];

      CGFloat authorFontSize = _authorTextField.font.pointSize;
      NSMutableAttributedString* author = [[NSMutableAttributedString alloc] init];
      [author beginEditing];
      [author appendString:_commit.authorName withAttributes:@{NSFontAttributeName : [NSFont boldSystemFontOfSize:authorFontSize]}];
      [author appendString:@" " withAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:authorFontSize]}];
      [author appendString:_commit.authorEmail withAttributes:nil];
      [author endEditing];
      _authorTextField.attributedStringValue = author;

      CGFloat committerFontSize = _committerTextField.font.pointSize;
      NSMutableAttributedString* committer = [[NSMutableAttributedString alloc] init];
      [committer beginEditing];
      [committer appendString:_commit.committerName withAttributes:@{NSFontAttributeName : [NSFont boldSystemFontOfSize:committerFontSize]}];
      [committer appendString:@" " withAttributes:@{NSFontAttributeName : [NSFont systemFontOfSize:committerFontSize]}];
      [committer appendString:_commit.committerEmail withAttributes:nil];
      [committer endEditing];
      _committerTextField.attributedStringValue = committer;

      NSError* error;
      _diff = [self.repository diffCommit:_commit
                               withCommit:_commit.parents.firstObject  // Use main line
                              filePattern:nil
                                  options:(self.repository.diffBaseOptions | kGCDiffOption_FindRenames)
                        maxInterHunkLines:self.repository.diffMaxInterHunkLines
                          maxContextLines:self.repository.diffMaxContextLines
                                    error:&error];
      if (!_diff) {
        [self presentError:error];
      }
      [_diffContentsViewController setDeltas:_diff.deltas usingConflicts:nil];
      [_diffFilesViewController setDeltas:_diff.deltas usingConflicts:nil];
    } else {
      _sha1TextField.stringValue = @"";
      _authorTextField.stringValue = @"";
      _authorDateTextField.stringValue = @"";
      _committerTextField.stringValue = @"";
      _committerDateTextField.stringValue = @"";
      _messageTextField.stringValue = @"";

      _diff = nil;
      [_diffContentsViewController setDeltas:nil usingConflicts:nil];
      [_diffFilesViewController setDeltas:nil usingConflicts:nil];
    }
  }
}

#pragma mark - GIDiffContentsViewControllerDelegate
- (void)diffContentsViewControllerDidScroll:(GIDiffContentsViewController*)scroll {
  if (!_disableFeedbackLoop) {
    _diffFilesViewController.selectedDelta = [_diffContentsViewController topVisibleDelta:NULL];
  }
}

- (NSMenu*)diffContentsViewController:(GIDiffContentsViewController*)controller willShowContextualMenuForDelta:(GCDiffDelta*)delta conflict:(GCIndexConflict*)conflict {
  XLOG_DEBUG_CHECK(conflict == nil);
  NSMenu* menu = [self contextualMenuForDelta:delta withConflict:nil allowOpen:NO];

  [menu addItem:[NSMenuItem separatorItem]];

  if (GC_FILE_MODE_IS_FILE(delta.newFile.mode)) {
    [menu addItemWithTitle:NSLocalizedString(@"Restore File to This Version…", nil)
                     block:^{
                       [self restoreFile:delta.canonicalPath toCommit:_commit];
                     }];
  } else {
    [menu addItemWithTitle:NSLocalizedString(@"Restore File to This Version…", nil) block:NULL];
  }
  
  if (self.willShowContextualMenu) {
    self.willShowContextualMenu(menu, delta, conflict);
  }
  
  return menu;
}

#pragma mark - GIDiffFilesViewControllerDelegate
- (void)diffFilesViewController:(GIDiffFilesViewController*)controller willSelectDelta:(GCDiffDelta*)delta {
  _disableFeedbackLoop = YES;
  [_diffContentsViewController setTopVisibleDelta:delta offset:0];
  _disableFeedbackLoop = NO;
}

- (BOOL)diffFilesViewController:(GIDiffFilesViewController*)controller handleKeyDownEvent:(NSEvent*)event {
  return [self handleKeyDownEvent:event forSelectedDeltas:_diffFilesViewController.selectedDeltas withConflicts:nil allowOpen:NO];
}

@end

#import "GICommitListViewController.h"
@interface GIQuickViewControllerWithCommitsList () <GICommitListViewControllerDelegate>
@property (strong, nonatomic, readonly) GICommitListViewController *leftController;
@property (strong, nonatomic, readonly) GIQuickViewController *rightController;

@property (strong, nonatomic, readwrite) NSLayoutConstraint *hiddenConstraint;
@property (strong, nonatomic, readwrite) NSLayoutConstraint *revealedConstraint;
@end

@implementation GIQuickViewControllerWithCommitsList

#pragma mark - Accessors
- (GICommitListViewController *)leftController {
  return self.childViewControllers.firstObject;
}

- (GIQuickViewController *)rightController {
  return self.childViewControllers.lastObject;
}

#pragma mark - Check
- (BOOL)isHistoryShown {
  return self.leftController.results.count > 0;
}

#pragma mark - Actions
- (void)toggleLeftView {
  BOOL shouldReveal = self.isHistoryShown;
  self.hiddenConstraint.active = !shouldReveal;
  self.revealedConstraint.active = shouldReveal;
  [self.view setNeedsLayout:YES];
//  [self.view setNeedsDisplay:YES];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
    context.duration = 0.25;
    context.allowsImplicitAnimation = YES;
    [self.view layout];
//    [self.view displayIfNeeded];
  } completionHandler:^{
  }];
}

#pragma mark - Layout
- (void)addConstraints {
  if (@available(macOS 10.11, *)) {
    NSView *leftView = self.leftController.view;
    if (leftView.superview != nil) {
      NSView *superview = leftView.superview;
      NSArray *constraints = @[
                               [leftView.leftAnchor constraintEqualToAnchor:superview.leftAnchor],
                               [leftView.topAnchor constraintEqualToAnchor:superview.topAnchor],
                               [leftView.bottomAnchor constraintEqualToAnchor:superview.bottomAnchor],
                               [leftView.widthAnchor constraintEqualToAnchor:superview.widthAnchor multiplier:0.3]
                               ];
      [NSLayoutConstraint activateConstraints:constraints];
    }

    NSView *rightView = self.rightController.view;
    if (rightView.superview != nil) {
      NSView *superview = rightView.superview;
      self.hiddenConstraint = [rightView.leftAnchor constraintEqualToAnchor:superview.leftAnchor];
      self.revealedConstraint = [rightView.leftAnchor constraintEqualToAnchor:leftView.rightAnchor];
      NSArray *constraints = @[
                               [rightView.topAnchor constraintEqualToAnchor:superview.topAnchor],
                               [rightView.bottomAnchor constraintEqualToAnchor:superview.bottomAnchor],
                               [rightView.rightAnchor constraintEqualToAnchor:superview.rightAnchor],
                               ];
      [NSLayoutConstraint activateConstraints:constraints];
    }
    
    [self toggleLeftView];
  } else {
    NSView *leftView = self.leftController.view;
    if (leftView.superview != nil) {
      NSView *superview = leftView.superview;
      NSArray *constraints = @[
        [NSLayoutConstraint constraintWithItem:leftView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:superview attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0.0],
        [NSLayoutConstraint constraintWithItem:leftView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:superview attribute:NSLayoutAttributeWidth multiplier:0.3 constant:0.0]
      ];
      NSArray *verticalConstraints = [NSLayoutConstraint constraintsWithVisualFormat:@"V:|[view]|" options:0 metrics:nil views:@{@"view": leftView}];
      [NSLayoutConstraint activateConstraints:[constraints arrayByAddingObjectsFromArray:verticalConstraints]];
    }
    NSView *rightView = self.rightController.view;
    if (rightView.superview != nil) {
      NSView *superview = rightView.superview;
      self.hiddenConstraint = [NSLayoutConstraint constraintWithItem:rightView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:superview attribute:NSLayoutAttributeLeft multiplier:1.0 constant:0.0];
      self.revealedConstraint = [NSLayoutConstraint constraintWithItem:rightView attribute:NSLayoutAttributeLeft relatedBy:NSLayoutRelationEqual toItem:leftView attribute:NSLayoutAttributeRight multiplier:1.0 constant:0.0];
      NSArray *constraints = @[
        [NSLayoutConstraint constraintWithItem:rightView attribute:NSLayoutAttributeRight relatedBy:NSLayoutRelationEqual toItem:superview attribute:NSLayoutAttributeRight multiplier:1.0 constant:0.0],
      ];
      NSArray *verticalConstraints = [NSLayoutConstraint constraintsWithVisualFormat:@"V:|[view]|" options:0 metrics:nil views:@{@"view": rightView}];
      [NSLayoutConstraint activateConstraints:[constraints arrayByAddingObjectsFromArray:verticalConstraints]];
    }
  }
}

#pragma mark - View Lifecycle
- (void)loadView {
  self.view = [[GIView alloc] initWithFrame:NSScreen.mainScreen.frame];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  NSViewController *leftController = ({
    GICommitListViewController *commitsList = [[GICommitListViewController alloc] initWithRepository:self.repository];
    // setup?
    commitsList.delegate = self;
    commitsList;
  });
  NSViewController *rightController = ({
    GIQuickViewController *quickView = [[GIQuickViewController alloc] initWithRepository:self.repository];
    // setup?
    __weak typeof(self) weakSelf = self;
    quickView.willShowContextualMenu = ^(NSMenu *menu, GCDiffDelta *delta, GCIndexConflict *conflict) {
      [weakSelf willShowContextualMenu:menu delta:delta conflict:conflict];
    };
    quickView;
  });

  [self addChildViewController:leftController];
  [self addChildViewController:rightController];
  [self.view addSubview:leftController.view];
  [self.view addSubview:rightController.view];
  
  leftController.view.translatesAutoresizingMaskIntoConstraints = NO;
  rightController.view.translatesAutoresizingMaskIntoConstraints = NO;
  [self addConstraints];
}

- (void)setCommit:(GCHistoryCommit *)commit {
  if (self.rightController.commit.autoIncrementID != commit.autoIncrementID || self.rightController.commit == nil) {
    self.rightController.commit = commit;
  }
  if (self.leftController.selectedCommit.autoIncrementID != commit.autoIncrementID || self.leftController.selectedCommit == nil) {
     self.leftController.selectedCommit = commit;
  }
}

#pragma mark - Getters / Setters
- (GCHistoryCommit *)commit {
  return self.rightController.commit;
}

- (void)setDelegate:(id<GIQuickViewControllerDelegate>)delegate {
  self.rightController.delegate = delegate;
}

- (id<GIQuickViewControllerDelegate>)delegate {
  return self.rightController.delegate;
}

- (void)setList:(NSArray<GCHistoryCommit *> *)list {
  self.leftController.results = list;
  [self toggleLeftView];
}

- (NSArray<GCHistoryCommit *> *)list {
  NSMutableArray* result = [NSMutableArray new];
  for (GCHistoryCommit* element in self.leftController.results) {
    if ([element isKindOfClass:GCHistoryCommit.class]) {
      [result addObject:element];
    }
  }
  return [result copy];
}

#pragma mark - CommitListControllerDelegate
- (void)commitListViewControllerDidChangeSelection:(GICommitListViewController *)controller {
  // we should reload data in quickview.
  self.rightController.commit = controller.selectedCommit;
  [self.rightController.delegate quickViewDidSelectCommit:self.rightController.commit commitsList:nil];
  // TODO: add quick view model.
  // also we should update QuickViewModel to be in touch with toolbar...
}

#pragma mark - GIViewController
- (void)viewDidFinishLiveResize {
  [self.leftController viewDidFinishLiveResize];
  [self.rightController viewDidFinishLiveResize];
}

#pragma mark - Contextual Menu Handling
- (void)willShowContextualMenu:(NSMenu *)menu delta:(GCDiffDelta *)delta conflict:(GCIndexConflict *)conflict {
  if (GC_FILE_MODE_IS_FILE(delta.newFile.mode)) {
    if (self.isHistoryShown) {
      __weak typeof(self) weakSelf = self;
      [menu addItemWithTitle:NSLocalizedString(@"Hide file history...", nil) block:^{
        [weakSelf.delegate quickViewWantsToShowSelectedCommitsList:nil selectedCommit:weakSelf.commit];
      }];
    }
    else {
      __weak typeof(self) weakSelf = self;
      [menu addItemWithTitle:NSLocalizedString(@"Show file history...", nil) block:^{
        // git log
        // show selected files history.
        [weakSelf getSelectedCommitsForFilesMatchingPaths:@[delta.canonicalPath] result:^(NSArray *commits) {
          NSMutableArray *result = [NSMutableArray new];
          for (GCCommit *commit in commits) {
            GCHistoryCommit *historyCommit = [weakSelf.repository.history historyCommitForCommit:commit];
            [result addObject:historyCommit];
          }
          [weakSelf.delegate quickViewWantsToShowSelectedCommitsList:[result copy] selectedCommit:result.firstObject];
        }];
      }];
    }
  }
}

@end
