//
//  QuickViewModel.m
//  Application
//
//  Created by Dmitry Lobanov on 15/09/2019.
//

@import GitUpKit;
#import <GitUpKit/XLFacilityMacros.h>
#import "QuickViewModel.h"

@interface QuickViewModel ()

@property (weak, nonatomic) GCLiveRepository *repository;

@property (assign, nonatomic) NSUInteger index;
@property (strong, nonatomic) NSMutableArray *commits;

@property (strong, nonatomic) GCHistoryWalker *ancestors;
@property (strong, nonatomic) GCHistoryWalker *descendants;

#pragma mark - Protected
- (void)loadMoreAncestors;
- (void)loadMoreDescendants;
@end

@implementation QuickViewModel
#pragma mark - Loading
- (void)loadMoreAncestors {
  if (![_ancestors iterateWithCommitBlock:^(GCHistoryCommit* commit, BOOL* stop) {
    [_commits addObject:commit];
  }]) {
    _ancestors = nil;
  }
}

- (void)loadMoreDescendants {
  if (![_descendants iterateWithCommitBlock:^(GCHistoryCommit* commit, BOOL* stop) {
    [_commits insertObject:commit atIndex:0];
    _index += 1;  // We insert commits before the index too!
  }]) {
    _descendants = nil;
  }
}

#pragma mark - Checking
- (BOOL)hasPrevious {
  return _index + 1 < _commits.count;
}

- (BOOL)hasNext {
  return _index > 0;
}

#pragma mark - Moving
- (void)moveBackward {
  _index -= 1;
}

- (void)moveForward {
  _index += 1;
}

#pragma mark - State
- (void)enterWithHistoryCommit:(GCHistoryCommit *)commit commitList:(NSArray *)commitList onResult:(void(^)(GCHistoryCommit *,  NSArray * _Nullable))result {
  [_repository suspendHistoryUpdates];
  
  _commits = [NSMutableArray new];
  if (commitList) {
    [_commits addObjectsFromArray:commitList];
    _index = [_commits indexOfObjectIdenticalTo:commit];
    if (result) {
      result(commit, commitList);
    }
    XLOG_DEBUG_CHECK(_index != NSNotFound);
  }
  else {
    [_commits addObject:commit];
    _index = 0;
    _ancestors = [_repository.history walkerForAncestorsOfCommits:@[ commit ]];
    [self loadMoreAncestors];
    _descendants = [_repository.history walkerForDescendantsOfCommits:@[ commit ]];
    [self loadMoreDescendants];
    if (result) {
      result(commit, nil);
    }
  }
}

- (void)exit {
  _commits = nil;
  _ancestors = nil;
  _descendants = nil;
  
  // resume history updates for repository.
  [_repository resumeHistoryUpdates];
}

#pragma mark - Configurations
- (instancetype)configuredWithLiveRepository:(GCLiveRepository *)repository {
  _repository = repository;
  return self;
}
@end
