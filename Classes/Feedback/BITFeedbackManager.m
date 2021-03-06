#import "HockeySDK.h"
#import "HockeySDKPrivate.h"

#import "BITFeedbackManager.h"
#import "BITFeedbackMessageAttachment.h"
#import "BITFeedbackManagerPrivate.h"
#import "BITHockeyBaseManagerPrivate.h"

#import "BITHockeyAppClient.h"
#import "BITHockeyHelper.h"

#define kBITFeedbackUserDataAsked   @"HockeyFeedbackUserDataAsked"
#define kBITFeedbackDateOfLastCheck	@"HockeyFeedbackDateOfLastCheck"
#define kBITFeedbackMessages        @"HockeyFeedbackMessages"
#define kBITFeedbackToken           @"HockeyFeedbackToken"
#define kBITFeedbackUserID          @"HockeyFeedbackuserID"
#define kBITFeedbackName            @"HockeyFeedbackName"
#define kBITFeedbackEmail           @"HockeyFeedbackEmail"
#define kBITFeedbackLastMessageID   @"HockeyFeedbackLastMessageID"
#define kBITFeedbackAppID           @"HockeyFeedbackAppID"

@interface BITFeedbackManager ()

@property (nonatomic, strong) NSFileManager *fileManager;
@property (nonatomic, copy) NSString *settingsFile;

@property (nonatomic, strong) BITFeedbackWindowController *feedbackWindowController;

@property (nonatomic) BOOL didSetupDidBecomeActiveNotifications;
@property (nonatomic) BOOL networkRequestInProgress;

@end

@implementation BITFeedbackManager {
}

#pragma mark - Initialization

- (id)init {
  if ((self = [super init])) {
    _didAskUserData = NO;
    
    _requireUserName = BITFeedbackUserDataElementOptional;
    _requireUserEmail = BITFeedbackUserDataElementOptional;
    _showAlertOnIncomingMessages = YES;
    
    _disableFeedbackManager = NO;
    _didSetupDidBecomeActiveNotifications = NO;
    _networkRequestInProgress = NO;
    _lastCheck = nil;
    _token = nil;
    _lastMessageID = nil;
    _feedbackWindowController = nil;
    _lastRefreshDate = [NSDate distantPast];
    
    _feedbackList = [[NSMutableArray alloc] init];
    
    _fileManager = [[NSFileManager alloc] init];
    
    _settingsFile = [bit_settingsDir() stringByAppendingPathComponent:BITHOCKEY_FEEDBACK_SETTINGS];
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:BITHockeyNetworkDidBecomeReachableNotification object:nil];
  
  [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidBecomeActiveNotification object:nil];
  
}


- (void)didBecomeActiveActions {
  if (![self isFeedbackManagerDisabled]) {
    [self updateAppDefinedUserData];
    
    // wait at least 5 minutes since the last refresh before doing another auto update
    if ([[NSDate date] timeIntervalSinceDate:self.lastRefreshDate] > 60 * 5) {
      [self updateMessagesList];
    }
  }
}

- (void)setupDidBecomeActiveNotifications {
  if (!self.didSetupDidBecomeActiveNotifications) {
    NSNotificationCenter *dnc = [NSNotificationCenter defaultCenter];
    [dnc addObserver:self selector:@selector(didBecomeActiveActions) name:NSApplicationDidBecomeActiveNotification object:nil];
    [dnc addObserver:self selector:@selector(didBecomeActiveActions) name:BITHockeyNetworkDidBecomeReachableNotification object:nil];
    self.didSetupDidBecomeActiveNotifications = YES;
  }
}

- (void)cleanupDidBecomeActiveNotifications {
  [[NSNotificationCenter defaultCenter] removeObserver:self name:BITHockeyNetworkDidBecomeReachableNotification object:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self name:NSApplicationDidBecomeActiveNotification object:nil];
}

#pragma mark - Private methods

- (NSString *)uuidAsLowerCaseAndShortened {
  return [[bit_UUID() lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
}


#pragma mark - UI

- (void)showFeedbackWindow {
  if (!self.feedbackWindowController) {
    self.feedbackWindowController = [[BITFeedbackWindowController alloc] initWithManager:self];
  }
  
  [self.feedbackWindowController showWindow:self];
  [self.feedbackWindowController.window makeKeyAndOrderFront:self];
}


#pragma mark - Manager Control

- (void)startManager {
  if ([self.feedbackList count] == 0) {
    [self loadMessages];
  } else {
    [self updateAppDefinedUserData];
  }
  [self updateMessagesList];
  
  [self setupDidBecomeActiveNotifications];
}

- (void)updateMessagesList {
  if (self.networkRequestInProgress) return;
  
  NSArray *pendingMessages = [self messagesWithStatus:BITFeedbackMessageStatusSendPending];
  if ([pendingMessages count] > 0) {
    [self submitPendingMessages];
  } else {
    [self fetchMessageUpdates];
  }
}

- (void)updateMessagesListIfRequired {
  double now = [[NSDate date] timeIntervalSince1970];
  if ((now - [self.lastCheck timeIntervalSince1970] > 30)) {
    [self updateMessagesList];
  }
}

- (void)setUserName:(NSString *)userName {
  if (userName) {
    self.requireUserName = BITFeedbackUserDataElementDontShow;
  }
  
  [super setUserName:userName];
}

- (void)setUserEmail:(NSString *)userEmail {
  if (userEmail) {
    self.requireUserName = BITFeedbackUserDataElementDontShow;
  }
  
  [super setUserEmail:userEmail];
}

- (BOOL)updateUserIDUsingDelegate {
  BOOL availableViaDelegate = NO;
  
  NSString *userID = bit_stringValueFromKeychainForKey(kBITDefaultUserID);
  
  id<BITHockeyManagerDelegate> delegate = [BITHockeyManager sharedHockeyManager].delegate;
  if (delegate && [delegate respondsToSelector:@selector(userIDForHockeyManager:componentManager:)]) {
    userID = [delegate userIDForHockeyManager:[BITHockeyManager sharedHockeyManager]
                             componentManager:self] ?: userID;
  }
  
  if (userID) {
    availableViaDelegate = YES;
    self.userID = userID;
  }
  
  return availableViaDelegate;
}

- (BOOL)updateUserNameUsingDelegate {
  BOOL availableViaDelegate = NO;
  
  NSString *userName = bit_stringValueFromKeychainForKey(kBITDefaultUserName);
  
  id<BITHockeyManagerDelegate> delegate = [BITHockeyManager sharedHockeyManager].delegate;
  if (delegate && [delegate respondsToSelector:@selector(userNameForHockeyManager:componentManager:)]) {
    userName = [delegate userNameForHockeyManager:[BITHockeyManager sharedHockeyManager]
                                 componentManager:self] ?: userName;
  }
  
  if (userName) {
    availableViaDelegate = YES;
    self.userName = userName;
    self.requireUserName = BITFeedbackUserDataElementDontShow;
  }
  
  return availableViaDelegate;
}

- (BOOL)updateUserEmailUsingDelegate {
  BOOL availableViaDelegate = NO;
  
  NSString *userEmail = bit_stringValueFromKeychainForKey(kBITDefaultUserEmail);
  
  id<BITHockeyManagerDelegate> delegate = [BITHockeyManager sharedHockeyManager].delegate;
  if (delegate && [delegate respondsToSelector:@selector(userEmailForHockeyManager:componentManager:)]) {
    userEmail = [delegate userEmailForHockeyManager:[BITHockeyManager sharedHockeyManager]
                                   componentManager:self] ?: userEmail;
  }
  
  if (userEmail) {
    availableViaDelegate = YES;
    self.userEmail = userEmail;
    self.requireUserEmail = BITFeedbackUserDataElementDontShow;
  }
  
  return availableViaDelegate;
}

- (void)updateAppDefinedUserData {
  [self updateUserIDUsingDelegate];
  [self updateUserNameUsingDelegate];
  [self updateUserEmailUsingDelegate];
  
  // if both values are shown via the delegates, we never ever did ask and will never ever ask for user data
  if (self.requireUserName == BITFeedbackUserDataElementDontShow &&
      self.requireUserEmail == BITFeedbackUserDataElementDontShow) {
    self.didAskUserData = NO;
  }
}

#pragma mark - Local Storage

- (void)loadMessages {
  BOOL userIDViaDelegate = [self updateUserIDUsingDelegate];
  BOOL userNameViaDelegate = [self updateUserNameUsingDelegate];
  BOOL userEmailViaDelegate = [self updateUserEmailUsingDelegate];
  
  if (![self.fileManager fileExistsAtPath:self.settingsFile])
    return;
  
  NSData *codedData = [[NSData alloc] initWithContentsOfFile:self.settingsFile];
  if (codedData == nil) return;
  
  NSKeyedUnarchiver *unarchiver = nil;
  
  @try {
    unarchiver = [[NSKeyedUnarchiver alloc] initForReadingWithData:codedData];
  }
  @catch (NSException * __unused exception) {
    return;
  }
  
  if (!userIDViaDelegate) {
    if (!self.userID) {
      if ([unarchiver containsValueForKey:kBITFeedbackUserID])
        self.userID = [unarchiver decodeObjectForKey:kBITFeedbackUserID];
    }
  }
  
  if (!userNameViaDelegate) {
    if (!self.userName) {
      if ([unarchiver containsValueForKey:kBITFeedbackName])
        self.userName = [unarchiver decodeObjectForKey:kBITFeedbackName];
    }
  }
  
  if (!userEmailViaDelegate) {
    if (!self.userEmail) {
      if ([unarchiver containsValueForKey:kBITFeedbackEmail])
        self.userEmail = [unarchiver decodeObjectForKey:kBITFeedbackEmail];
    }
  }
  
  if ([unarchiver containsValueForKey:kBITFeedbackUserDataAsked])
    self.didAskUserData = YES;
  
  if ([unarchiver containsValueForKey:kBITFeedbackToken])
    self.token = [unarchiver decodeObjectForKey:kBITFeedbackToken];
  
  if ([unarchiver containsValueForKey:kBITFeedbackAppID]) {
    NSString *appID = [unarchiver decodeObjectForKey:kBITFeedbackAppID];
    
    // the stored thread is from another application identifier, so clear the token
    // which will cause the new posts to create a new thread on the server for the
    // current app identifier
    if ([appID compare:self.appIdentifier] != NSOrderedSame) {
      self.token = nil;
    }
  }
  
  if ([unarchiver containsValueForKey:kBITFeedbackDateOfLastCheck])
    self.lastCheck = [unarchiver decodeObjectForKey:kBITFeedbackDateOfLastCheck];
  
  if ([unarchiver containsValueForKey:kBITFeedbackLastMessageID])
    self.lastMessageID = [unarchiver decodeObjectForKey:kBITFeedbackLastMessageID];
  
  if ([unarchiver containsValueForKey:kBITFeedbackMessages]) {
    [self.feedbackList setArray:[unarchiver decodeObjectForKey:kBITFeedbackMessages] ?: @[]];
    
    [self sortFeedbackList];
    
    // inform the UI to update its data in case the list is already showing
    [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingFinished object:nil];
  }
  
  [unarchiver finishDecoding];
  
  if (!self.lastCheck) {
    self.lastCheck = [NSDate distantPast];
  }
}


- (void)saveMessages {
  [self sortFeedbackList];
  
  NSMutableData *data = [[NSMutableData alloc] init];
  NSKeyedArchiver *archiver = [[NSKeyedArchiver alloc] initForWritingWithMutableData:data];
  
  if (self.didAskUserData)
    [archiver encodeObject:@YES forKey:kBITFeedbackUserDataAsked];
  
  if (self.token)
    [archiver encodeObject:self.token forKey:kBITFeedbackToken];
  
  if (self.appIdentifier)
    [archiver encodeObject:self.appIdentifier forKey:kBITFeedbackAppID];
  
  if (self.userID)
    [archiver encodeObject:self.userID forKey:kBITFeedbackUserID];
  
  if (self.userName)
    [archiver encodeObject:self.userName forKey:kBITFeedbackName];
  
  if (self.userEmail)
    [archiver encodeObject:self.userEmail forKey:kBITFeedbackEmail];
  
  if (self.lastCheck)
    [archiver encodeObject:self.lastCheck forKey:kBITFeedbackDateOfLastCheck];
  
  if (self.lastMessageID)
    [archiver encodeObject:self.lastMessageID forKey:kBITFeedbackLastMessageID];
  
  [archiver encodeObject:self.feedbackList forKey:kBITFeedbackMessages];
  
  [archiver finishEncoding];
  [data writeToFile:self.settingsFile atomically:YES];
}


- (void)updateDidAskUserData {
  if (!self.didAskUserData) {
    self.didAskUserData = YES;
    
    [self saveMessages];
  }
}

#pragma mark - Messages

- (void)sortFeedbackList {
  [self.feedbackList sortUsingComparator:^(BITFeedbackMessage *obj1, BITFeedbackMessage *obj2) {
    NSDate *date1 = [obj1 date];
    NSDate *date2 = [obj2 date];
    
    // not send, in conflict and send in progress messages on top, sorted by date
    // read and unread on bottom, sorted by date
    // archived on the very bottom
    
    if ([obj1 status] >= BITFeedbackMessageStatusSendInProgress && [obj2 status] < BITFeedbackMessageStatusSendInProgress) {
      return NSOrderedAscending;
    } else if ([obj1 status] < BITFeedbackMessageStatusSendInProgress && [obj2 status] >= BITFeedbackMessageStatusSendInProgress) {
      return NSOrderedDescending;
    } else if ([obj1 status] == BITFeedbackMessageStatusArchived && [obj2 status] < BITFeedbackMessageStatusArchived) {
      return NSOrderedAscending;
    } else if ([obj1 status] < BITFeedbackMessageStatusArchived && [obj2 status] == BITFeedbackMessageStatusArchived) {
      return NSOrderedDescending;
    } else {
      return (NSInteger)[date1 compare:date2];
    }
  }];
}

- (NSUInteger)numberOfMessages {
  return [self.feedbackList count];
}

- (BITFeedbackMessage *)messageAtIndex:(NSUInteger)index {
  if ([self.feedbackList count] > index) {
    return [self.feedbackList objectAtIndex:index];
  }
  
  return nil;
}

- (BITFeedbackMessage *)messageWithID:(NSNumber *)messageID {
  __block BITFeedbackMessage *message = nil;
  
  [self.feedbackList enumerateObjectsUsingBlock:^(BITFeedbackMessage *objMessage, NSUInteger __unused messagesIdx, BOOL *stop) {
    if ([[objMessage messageID] isEqualToNumber:messageID]) {
      message = objMessage;
      *stop = YES;
    }
  }];
  
  return message;
}

- (NSArray *)messagesWithStatus:(BITFeedbackMessageStatus)status {
  NSMutableArray *resultMessages = [[NSMutableArray alloc] initWithCapacity:[self.feedbackList count]];
  
  [self.feedbackList enumerateObjectsUsingBlock:^(BITFeedbackMessage *objMessage, NSUInteger __unused messagesIdx, BOOL * __unused stop) {
    if ([objMessage status] == status) {
      [resultMessages addObject: objMessage];
    }
  }];
  
  return [NSArray arrayWithArray:resultMessages];
}

- (BITFeedbackMessage *)lastMessageHavingID {
  __block BITFeedbackMessage *message = nil;
  
  [self.feedbackList enumerateObjectsUsingBlock:^(BITFeedbackMessage *objMessage, NSUInteger __unused messagesIdx, BOOL *stop) {
    if ([[objMessage messageID] integerValue] != 0) {
      message = objMessage;
    } else {
      *stop = YES;
    }
  }];
  
  return message;
}

- (void)markSendInProgressMessagesAsPending {
  // make sure message that may have not been send successfully, get back into the right state to be send again
  [self.feedbackList enumerateObjectsUsingBlock:^(id objMessage, NSUInteger __unused messagesIdx, BOOL * __unused stop) {
    if ([(BITFeedbackMessage *)objMessage status] == BITFeedbackMessageStatusSendInProgress)
      [(BITFeedbackMessage *)objMessage setStatus:BITFeedbackMessageStatusSendPending];
  }];
}

- (void)markSendInProgressMessagesAsInConflict {
  // make sure message that may have not been send successfully, get back into the right state to be send again
  [self.feedbackList enumerateObjectsUsingBlock:^(id objMessage, NSUInteger __unused messagesIdx, BOOL * __unused stop) {
    if ([(BITFeedbackMessage *)objMessage status] == BITFeedbackMessageStatusSendInProgress)
      [(BITFeedbackMessage *)objMessage setStatus:BITFeedbackMessageStatusInConflict];
  }];
}

- (void)updateLastMessageID {
  BITFeedbackMessage *lastMessageHavingID = [self lastMessageHavingID];
  if (lastMessageHavingID) {
    if (!self.lastMessageID || [self.lastMessageID compare:[lastMessageHavingID messageID]] != NSOrderedSame)
      self.lastMessageID = [lastMessageHavingID messageID];
  }
}

- (BOOL)deleteMessageAtIndex:(NSUInteger)index {
  if (self.feedbackList && [self.feedbackList count] > index && [self.feedbackList objectAtIndex:index]) {
    [self.feedbackList removeObjectAtIndex:index];
    
    [self saveMessages];
    return YES;
  }
  
  return NO;
}

- (void)deleteAllMessages {
  [self.feedbackList removeAllObjects];
  
  [self saveMessages];
}


#pragma mark - User

- (BOOL)askManualUserDataAvailable {
  [self updateAppDefinedUserData];
  
  if (self.requireUserName == BITFeedbackUserDataElementDontShow &&
      self.requireUserEmail == BITFeedbackUserDataElementDontShow)
    return NO;
  
  return YES;
}

- (BOOL)requireManualUserDataMissing {
  [self updateAppDefinedUserData];
  
  if (self.requireUserName == BITFeedbackUserDataElementRequired && !self.userName)
    return YES;
  
  if (self.requireUserEmail == BITFeedbackUserDataElementRequired && !self.userEmail)
    return YES;
  
  return NO;
}

- (BOOL)optionalManualUserDataMissing {
  [self updateAppDefinedUserData];
  
  if (self.requireUserName == BITFeedbackUserDataElementOptional && !self.userName)
    return YES;
  
  if (self.requireUserEmail == BITFeedbackUserDataElementOptional && !self.userEmail)
    return YES;
  
  return NO;
}

- (BOOL)isManualUserDataAvailable {
  [self updateAppDefinedUserData];
  
  if ((self.requireUserName != BITFeedbackUserDataElementDontShow && self.userName) ||
      (self.requireUserEmail != BITFeedbackUserDataElementDontShow && self.userEmail))
    return YES;
  
  return NO;
}


#pragma mark - Networking

- (void)updateMessageListFromResponse:(NSDictionary *)jsonDictionary {
  if (!jsonDictionary) {
    // nil is used when the server returns 404, so we need to mark all existing threads as archives and delete the discussion token
    
    NSArray *messagesSendInProgress = [self messagesWithStatus:BITFeedbackMessageStatusSendInProgress];
    NSInteger pendingMessagesCount = [messagesSendInProgress count] + [[self messagesWithStatus:BITFeedbackMessageStatusSendPending] count];
    
    [self markSendInProgressMessagesAsPending];
    
    [self.feedbackList enumerateObjectsUsingBlock:^(id objMessage, NSUInteger __unused messagesIdx, BOOL * __unused stop) {
      if ([(BITFeedbackMessage *)objMessage status] != BITFeedbackMessageStatusSendPending)
        [(BITFeedbackMessage *)objMessage setStatus:BITFeedbackMessageStatusArchived];
    }];
    
    if ([self token]) {
      self.token = nil;
    }
    
    NSArray *messages = [self messagesWithStatus:BITFeedbackMessageStatusSendPending];
    NSInteger pendingMessagesCountAfterProcessing = [messages count];
    
    [self saveMessages];
    
    // check if this request was successful and we have more messages pending and continue if positive
    if (pendingMessagesCount > pendingMessagesCountAfterProcessing && pendingMessagesCountAfterProcessing > 0) {
      [self performSelector:@selector(submitPendingMessages) withObject:nil afterDelay:0.1];
    }
    
    return;
  }
  
  NSDictionary *feedback = [jsonDictionary objectForKey:@"feedback"];
  NSString *token = [jsonDictionary objectForKey:@"token"];
  if (feedback && token) {
    // update the thread token, which is not available until the 1st message was successfully sent
    self.token = token;
    
    self.lastCheck = [NSDate date];
    
    // add all new messages
    NSArray *feedMessages = [feedback objectForKey:@"messages"];
    
    // get the message that was currently sent if available
    NSArray *messagesSendInProgress = [self messagesWithStatus:BITFeedbackMessageStatusSendInProgress];
    
    NSArray *pendingMessages = [self messagesWithStatus:BITFeedbackMessageStatusSendPending];
    NSInteger pendingMessagesCount = [messagesSendInProgress count] + [pendingMessages count];
    
    __block BOOL newMessage = NO;
    NSMutableSet *returnedMessageIDs = [[NSMutableSet alloc] init];
    
    [feedMessages enumerateObjectsUsingBlock:^(NSDictionary * objMessage, NSUInteger __unused messagesIdx, BOOL * __unused stop) {
      NSNumber *messageID = [objMessage objectForKey:@"id"];
      if (messageID) {
        [returnedMessageIDs addObject:messageID];
        
        BITFeedbackMessage *thisMessage = [self messageWithID:messageID];
        if (!thisMessage) {
          // check if this is a message that was sent right now
          __block BITFeedbackMessage *matchingSendInProgressOrInConflictMessage = nil;
          
          // TODO: match messages in state conflict
          
          [messagesSendInProgress enumerateObjectsUsingBlock:^(id objSendInProgressMessage, NSUInteger __unused messagesSendInProgressIdx, BOOL *stop2) {
            if ([[objMessage objectForKey:@"token"] isEqualToString:[(BITFeedbackMessage *)objSendInProgressMessage token]]) {
              matchingSendInProgressOrInConflictMessage = objSendInProgressMessage;
              *stop2 = YES;
            }
          }];
          
          if (matchingSendInProgressOrInConflictMessage) {
            matchingSendInProgressOrInConflictMessage.date = [self parseRFC3339Date:[objMessage objectForKey:@"created_at"]];
            matchingSendInProgressOrInConflictMessage.messageID = messageID;
            matchingSendInProgressOrInConflictMessage.status = BITFeedbackMessageStatusRead;
          } else {
            if ([objMessage objectForKey:@"clean_text"] ||
                [objMessage objectForKey:@"text"] ||
                [objMessage objectForKey:@"attachments"]) {
              BITFeedbackMessage *message = [[BITFeedbackMessage alloc] init];
              message.text = [objMessage objectForKey:@"clean_text"] ?: [objMessage objectForKey:@"text"] ?: @"";
              message.name = [objMessage objectForKey:@"name"] ?: @"";
              message.email = [objMessage objectForKey:@"email"] ?: @"";
              
              message.date = [self parseRFC3339Date:[objMessage objectForKey:@"created_at"]] ?: [NSDate date];
              message.messageID = [objMessage objectForKey:@"id"];
              message.status = BITFeedbackMessageStatusUnread;
              
              for (NSDictionary *attachmentData in [objMessage objectForKey:@"attachments"]) {
                BITFeedbackMessageAttachment *newAttachment = [BITFeedbackMessageAttachment new];
                newAttachment.originalFilename = [attachmentData objectForKey:@"file_name"];
                newAttachment.identifier = [attachmentData objectForKey:@"id"];
                newAttachment.sourceURL = [attachmentData objectForKey:@"url"];
                newAttachment.contentType = [attachmentData objectForKey:@"content_type"];
                [message addAttachmentsObject:newAttachment];
              }
              
              [self.feedbackList addObject:message];
              
              newMessage = YES;
            }
          }
        } else {
          // we should never get any messages back that are already stored locally,
          // since we add the last_message_id to the request
        }
      }
    }];
    
    [self markSendInProgressMessagesAsPending];
    
    [self sortFeedbackList];
    [self updateLastMessageID];
    
    // we got a new incoming message, trigger user notification system
    if (newMessage) {
      // check if the latest message is from the users own email address, then don't show an alert since he answered using his own email
      BOOL latestMessageFromUser = NO;
      
      BITFeedbackMessage *latestMessage = [self lastMessageHavingID];
      if (self.userEmail && latestMessage.email && [self.userEmail compare:latestMessage.email] == NSOrderedSame)
        latestMessageFromUser = YES;
      
      if (!latestMessageFromUser && self.showAlertOnIncomingMessages) {
        id userNotificationClass = NSClassFromString(@"NSUserNotification");
        if (userNotificationClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
          NSUserNotification *notification = [[NSUserNotification alloc] init];
          notification.title = @"A new response to your feedback is available.";
          notification.informativeText = latestMessage.text;
          notification.soundName = NSUserNotificationDefaultSoundName;
          [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
#pragma clang diagnostic pop
        }
      }
    }
    
    pendingMessages = [self messagesWithStatus:BITFeedbackMessageStatusSendPending];
    NSInteger pendingMessagesCountAfterProcessing = [pendingMessages count];
    
    // check if this request was successful and we have more messages pending and continue if positive
    if (pendingMessagesCount > pendingMessagesCountAfterProcessing && pendingMessagesCountAfterProcessing > 0) {
      [self performSelector:@selector(submitPendingMessages) withObject:nil afterDelay:0.1];
    }
    
  } else {
    [self markSendInProgressMessagesAsPending];
  }
  
  [self saveMessages];
  
  return;
}

- (void)sendNetworkRequestWithHTTPMethod:(NSString *)httpMethod withMessage:(BITFeedbackMessage *)message completionHandler:(void (^)(NSError *err))completionHandler {
  NSString *boundary = @"----FOO";
  
  self.networkRequestInProgress = YES;
  // inform the UI to update its data in case the list is already showing
  [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingStarted object:nil];
  
  NSString *tokenParameter = @"";
  if ([self token]) {
    tokenParameter = [NSString stringWithFormat:@"/%@", [self token]];
  }
  NSMutableString *parameter = [NSMutableString stringWithFormat:@"api/2/apps/%@/feedback%@", [self encodedAppIdentifier], tokenParameter];
  
  NSString *lastMessageID = @"";
  if (!self.lastMessageID) {
    [self updateLastMessageID];
  }
  if (self.lastMessageID) {
    lastMessageID = [NSString stringWithFormat:@"&last_message_id=%li", (long)[self.lastMessageID integerValue]];
  }
  
  [parameter appendFormat:@"?format=json&bundle_version=%@&sdk=%@&sdk_version=%@%@",
   bit_URLEncodedString([[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"]),
   BITHOCKEY_NAME,
   BITHOCKEY_VERSION,
   lastMessageID
   ];
  
  // build request & send
  NSString *url = [NSString stringWithFormat:@"%@%@", self.serverURL, parameter];
  BITHockeyLogDebug(@"INFO: sending api request to %@", url);
  
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:(NSURL *)[NSURL URLWithString:url] cachePolicy:1 timeoutInterval:10.0];
  [request setHTTPMethod:httpMethod];
  [request setValue:@"Hockey/iOS" forHTTPHeaderField:@"User-Agent"];
  [request setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
  
  if (message) {
    NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", boundary];
    [request setValue:contentType forHTTPHeaderField:@"Content-type"];
    
    NSMutableData *postBody = [NSMutableData data];
    
    [postBody appendData:[BITHockeyAppClient dataWithPostValue:@"Apple" forKey:@"oem" boundary:boundary]];
    [postBody appendData:[BITHockeyAppClient dataWithPostValue:[BITSystemProfile systemVersionString] forKey:@"os_version" boundary:boundary]];
    [postBody appendData:[BITHockeyAppClient dataWithPostValue:[self getDevicePlatform] forKey:@"model" boundary:boundary]];
    [postBody appendData:[BITHockeyAppClient dataWithPostValue:[[[NSBundle mainBundle] preferredLocalizations] objectAtIndex:0] forKey:@"lang" boundary:boundary]];
    [postBody appendData:[BITHockeyAppClient dataWithPostValue:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] forKey:@"bundle_version" boundary:boundary]];
    [postBody appendData:[BITHockeyAppClient dataWithPostValue:[message text] forKey:@"text" boundary:boundary]];
    [postBody appendData:[BITHockeyAppClient dataWithPostValue:[message token] forKey:@"message_token" boundary:boundary]];
    
    NSString *installString = [BITSystemProfile deviceIdentifier];
    if (installString) {
      [postBody appendData:[BITHockeyAppClient dataWithPostValue:installString forKey:@"install_string" boundary:boundary]];
    }
    
    if (self.userID) {
      [postBody appendData:[BITHockeyAppClient dataWithPostValue:self.userID forKey:@"user_string" boundary:boundary]];
    }
    if (self.userName) {
      [postBody appendData:[BITHockeyAppClient dataWithPostValue:self.userName forKey:@"name" boundary:boundary]];
    }
    if (self.userEmail) {
      [postBody appendData:[BITHockeyAppClient dataWithPostValue:self.userEmail forKey:@"email" boundary:boundary]];
    }
    
    NSInteger attachmentIndex = 0;
    
    for (BITFeedbackMessageAttachment *attachment in message.attachments){
      NSString *key = [NSString stringWithFormat:@"attachment%ld", (long)attachmentIndex];
      
      NSString *filename = attachment.originalFilename;
      
      if (!filename) {
        filename = [NSString stringWithFormat:@"Attachment %ld", (long)attachmentIndex];
      }
      
      [postBody appendData:[BITHockeyAppClient dataWithPostValue:attachment.data forKey:key contentType:attachment.contentType boundary:boundary filename:filename]];
      
      attachmentIndex++;
    }
    
    [postBody appendData:(NSData *)[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    
    [request setHTTPBody:postBody];
  }
  __weak typeof (self) weakSelf = self;
  NSURLSessionConfiguration *sessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
  __block NSURLSession *session = [NSURLSession sessionWithConfiguration:sessionConfiguration];
  
  NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                          completionHandler: ^(NSData *data, NSURLResponse *response, NSError *error) {
                                            typeof (self) strongSelf = weakSelf;
                                            
                                            [session finishTasksAndInvalidate];
                                            
                                            [strongSelf handleFeedbackMessageResponse:response data:data error:error completion:completionHandler];
                                          }];
  [task resume];
}

- (void)handleFeedbackMessageResponse:(NSURLResponse *)response data:(NSData *)responseData error:(NSError * )err completion:(void (^)(NSError *err))completionHandler{
  self.networkRequestInProgress = NO;
  
  self.lastRefreshDate = [NSDate date];
  
  if (err) {
    [self reportError:err];
    [self markSendInProgressMessagesAsPending];
    completionHandler(err);
  } else {
    NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
    if (statusCode == 404) {
      // thread has been deleted, we archive it
      [self updateMessageListFromResponse:nil];
    } else if (statusCode == 409) {
      // we submitted a message that is already on the server, mark it as being in conflict and resolve it with another fetch
      
      if (!self.token) {
        // set the token to the first message token, since this is identical
        __block NSString *token = nil;
        
        [self.feedbackList enumerateObjectsUsingBlock:^(id objMessage, NSUInteger __unused messagesIdx, BOOL *stop) {
          if ([(BITFeedbackMessage *)objMessage status] == BITFeedbackMessageStatusSendInProgress) {
            token = [(BITFeedbackMessage *)objMessage token];
            *stop = YES;
          }
        }];
        
        if (token) {
          self.token = token;
        }
      }
      
      [self markSendInProgressMessagesAsInConflict];
      [self saveMessages];
      [self performSelector:@selector(fetchMessageUpdates) withObject:nil afterDelay:0.2];
    } else if ([responseData length]) {
      NSString *responseString = [[NSString alloc] initWithBytes:[responseData bytes] length:[responseData length] encoding: NSUTF8StringEncoding];
      BITHockeyLogDebug(@"INFO: Received API response: %@", responseString);
      
      if (responseString && [responseString dataUsingEncoding:NSUTF8StringEncoding]) {
        NSError *error = NULL;
        
        NSDictionary *feedDict = (NSDictionary *)[NSJSONSerialization JSONObjectWithData:(NSData *)[responseString dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
        
        // server returned empty response?
        if (error) {
          [self reportError:error];
        } else if (![feedDict count]) {
          [self reportError:[NSError errorWithDomain:kBITFeedbackErrorDomain
                                                code:BITFeedbackAPIServerReturnedEmptyResponse
                                            userInfo:@{NSLocalizedDescriptionKey: @"Server returned empty response."}]];
        } else {
          BITHockeyLogDebug(@"INFO: Received API response: %@", responseString);
          NSString *status = [feedDict objectForKey:@"status"];
          if ([status compare:@"success"] != NSOrderedSame) {
            [self reportError:[NSError errorWithDomain:kBITFeedbackErrorDomain
                                                  code:BITFeedbackAPIServerReturnedInvalidStatus
                                              userInfo:@{NSLocalizedDescriptionKey: @"Server returned invalid status."}]];
          } else {
            [self updateMessageListFromResponse:feedDict];
          }
        }
      }
    }
    
    [self markSendInProgressMessagesAsPending];
    completionHandler(err);
  }
}

- (void)fetchMessageUpdates {
  if ([self.feedbackList count] == 0 && !self.token) {
    // inform the UI to update its data in case the list is already showing
    [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingFinished object:nil];
    
    return;
  }
  
  [self sendNetworkRequestWithHTTPMethod:@"GET"
                             withMessage:nil
                       completionHandler:^(NSError * __unused err){
                         // inform the UI to update its data in case the list is already showing
                         [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingFinished object:nil];
                       }];
}

- (void)submitPendingMessages {
  if (self.networkRequestInProgress) {
    [self performSelector:@selector(submitPendingMessages) withObject:nil afterDelay:2.0];
    return;
  }
  
  // app defined user data may have changed, update it
  [self updateAppDefinedUserData];
  [self saveMessages];
  
  NSArray *pendingMessages = [self messagesWithStatus:BITFeedbackMessageStatusSendPending];
  
  if ([pendingMessages count] > 0) {
    // we send one message at a time
    BITFeedbackMessage *messageToSend = [pendingMessages objectAtIndex:0];
    
    [messageToSend setStatus:BITFeedbackMessageStatusSendInProgress];
    if (self.userID)
      [messageToSend setUserID:self.userID];
    if (self.userName)
      [messageToSend setName:self.userName];
    if (self.userEmail)
      [messageToSend setEmail:self.userEmail];
    
    NSString *httpMethod = @"POST";
    if ([self token]) {
      httpMethod = @"PUT";
    }
    
    [self sendNetworkRequestWithHTTPMethod:httpMethod
                               withMessage:messageToSend
                         completionHandler:^(NSError *err){
                           if (err) {
                             [self markSendInProgressMessagesAsPending];
                             
                             [self saveMessages];
                           }
                           
                           // inform the UI to update its data in case the list is already showing
                           [[NSNotificationCenter defaultCenter] postNotificationName:BITHockeyFeedbackMessagesLoadingFinished object:nil];
                         }];
  }
}

- (void)submitMessageWithText:(NSString *)text andAttachments:(NSArray *)attachments {
  BITFeedbackMessage *message = [[BITFeedbackMessage alloc] init];
  message.text = text;
  [message setStatus:BITFeedbackMessageStatusSendPending];
  [message setToken:[self uuidAsLowerCaseAndShortened]];
  [message setAttachments:attachments];
  [message setUserMessage:YES];
  
  [self.feedbackList addObject:message];
  
  [self submitPendingMessages];
}

@end
