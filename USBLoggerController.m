/*
 * Copyright � 1998-2012 Apple Inc.  All rights reserved.
 *
 * @APPLE_LICENSE_HEADER_START@
 *
 * This file contains Original Code and/or Modifications of Original Code
 * as defined in and that are subject to the Apple Public Source License
 * Version 2.0 (the 'License'). You may not use this file except in
 * compliance with the License. Please obtain a copy of the License at
 * http://www.opensource.apple.com/apsl/ and read it before using this
 * file.
 *
 * The Original Code and all software distributed under the License are
 * distributed on an 'AS IS' basis, WITHOUT WARRANTY OF ANY KIND, EITHER
 * EXPRESS OR IMPLIED, AND APPLE HEREBY DISCLAIMS ALL SUCH WARRANTIES,
 * INCLUDING WITHOUT LIMITATION, ANY WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE, QUIET ENJOYMENT OR NON-INFRINGEMENT.
 * Please see the License for the specific language governing rights and
 * limitations under the License.
 *
 * @APPLE_LICENSE_HEADER_END@
 */


#import "USBLoggerController.h"

@implementation LoggerEntry
#define NUM_FRESH_ENTRIES 20000
static NSMutableArray * freshEntries = nil;
static int remainingFreshEntries = 0;

+ (void)initialize {
    freshEntries = [[NSMutableArray alloc] initWithCapacity:NUM_FRESH_ENTRIES];
    [self replenishFreshEntries];
}

+ (void)replenishFreshEntries {
    LoggerEntry *temp;
    int i;
    
    [freshEntries removeAllObjects];
    
    for (i=0; i<NUM_FRESH_ENTRIES; i++) {
        temp = [[LoggerEntry alloc] init];
        [freshEntries addObject:temp];
        [temp release];
    }
    
    remainingFreshEntries = NUM_FRESH_ENTRIES;
}

+ (LoggerEntry *)cachedFreshEntry {
    if (remainingFreshEntries <= 0) {
        [self replenishFreshEntries];
    }
    remainingFreshEntries--;
    return [freshEntries objectAtIndex: remainingFreshEntries];
}

- init {
    return [self initWithText:nil level:-1];
}

- initWithText:(NSString *)text level:(int)level {
    if (self = [super init]) {
        _text = [text retain];
        _level = level;
    }
    return self;
}

- (void)setText:(NSString *)text level:(int)level {
    [_text release];
    _text = [text retain];
    _level = level;
}

- (NSString *)text {
    return _text;
}

- (int)level {
    return _level;
}

@end

@implementation USBLoggerController

- init {
    if (self = [super init]) {
        _outputLines = [[NSMutableArray alloc] init];
        _currentFilterString = nil;
        _outputBuffer = [[NSMutableString alloc] init];
        _bufferLock = [[NSLock alloc] init];
        _outputLock = [[NSLock alloc] init];;
    }
    return self;
}

- (void)dealloc {
    if (_logger != nil) {
        [_logger invalidate];
        [_logger release];
    }
    [_outputLines release];
    [_currentFilterString release];
    [_outputBuffer release];
    [_bufferLock release];
    [_outputLock release];
    [super dealloc];
}

- (void)awakeFromNib {
    [LoggerOutputTV setFont:[NSFont fontWithName:@"Monaco" size:10]];
    [FilterProgressIndicator setUsesThreadedAnimation:YES];
    
    if ([[[NSUserDefaults standardUserDefaults] objectForKey:@"USBLoggerLoggingLevel"] intValue] != 0) {
        [LoggingLevelPopUp selectItemAtIndex:[[[NSUserDefaults standardUserDefaults] objectForKey:@"USBLoggerLoggingLevel"] intValue]-1];
    }
    
    _klogKextisPresent = [self isKlogKextPresent];
    _klogKextIsCorrectRevision = [self isKlogCorrectRevision];
    
    _refreshTimer = [[NSTimer scheduledTimerWithTimeInterval: (NSTimeInterval) LOGGER_REFRESH_INTERVAL
            target: self selector: @selector(handlePendingOutput:) userInfo: nil repeats: YES] retain];

    [self setupRecentSearchesMenu];
}

- (void)setupRecentSearchesMenu {
    // we can only do this if we're running on 10.3 or later (where FilterTextField is an NSSearchField instance)
    if ([FilterTextField respondsToSelector: @selector(setRecentSearches:)]) {
        NSMenu *cellMenu = [[NSMenu alloc] initWithTitle:@"Search Menu"];
        NSMenuItem *recentsTitleItem, *norecentsTitleItem, *recentsItem, *separatorItem, *clearItem;
        id searchCell = [FilterTextField cell];

        [FilterTextField setRecentsAutosaveName:@"logger_output_filter"];
        [searchCell setMaximumRecents:10];

        recentsTitleItem = [[NSMenuItem alloc] initWithTitle:@"Recent Searches" action: nil keyEquivalent:@""];
        [recentsTitleItem setTag:NSSearchFieldRecentsTitleMenuItemTag];
        [cellMenu insertItem:recentsTitleItem atIndex:0];
        [recentsTitleItem release];
        norecentsTitleItem = [[NSMenuItem alloc] initWithTitle:@"No recent searches" action: nil keyEquivalent:@""];
        [norecentsTitleItem setTag:NSSearchFieldNoRecentsMenuItemTag];
        [cellMenu insertItem:norecentsTitleItem atIndex:1];
        [norecentsTitleItem release];
        recentsItem = [[NSMenuItem alloc] initWithTitle:@"Recents" action: nil keyEquivalent:@""];
        [recentsItem setTag:NSSearchFieldRecentsMenuItemTag];
        [cellMenu insertItem:recentsItem atIndex:2];
        [recentsItem release];
        separatorItem = (NSMenuItem *)[NSMenuItem separatorItem];
        [separatorItem setTag:NSSearchFieldRecentsTitleMenuItemTag];
        [cellMenu insertItem:separatorItem atIndex:3];
        clearItem = [[NSMenuItem alloc] initWithTitle:@"Clear" action: nil keyEquivalent:@""];
        [clearItem setTag:NSSearchFieldClearRecentsMenuItemTag];
        [cellMenu insertItem:clearItem atIndex:4];
        [clearItem release];
        [searchCell setSearchMenuTemplate:cellMenu];
        [cellMenu release];
    }
}

- (IBAction)ChangeLoggingLevel:(id)sender
{
    if (_logger != nil) {
        [_logger setDebuggerOptions:-1 setLevel:true level:[[sender selectedItem] tag] setType:false type:0];
    }
    [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithInt:[[sender selectedItem] tag]] forKey:@"USBLoggerLoggingLevel"];
}

- (IBAction)ClearOutput:(id)sender
{
    [_outputLock lock];
    [_outputLines removeAllObjects];
    [LoggerOutputTV setString:@""];
    [_outputLock unlock];
}

- (IBAction)MarkOutput:(id)sender {
// PHT   NSCalendarDate *currentDate;
// PHT
// PHT   currentDate = [NSCalendarDate date];
// PHT   [currentDate setCalendarFormat:@"%b %d %H:%M:%S"];
// PHT   [self appendOutput:[NSString stringWithFormat:@"\n\t\t**** %@ ****\n\n",currentDate] atLevel:[NSNumber numberWithInt:0]];
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];                // PHT
    dateFormatter.dateStyle = NSDateFormatterMediumStyle;                           // PHT
    NSString *formattedDateString = [dateFormatter stringFromDate:[NSDate date]];   // PHT
    [self appendOutput:[NSString stringWithFormat:@"\n\t\t**** %@ ****\n\n", formattedDateString] atLevel:0];  //PHT
}

/*- (IBAction)SaveOutput:(id)sender
{
    NSSavePanel *sp = [NSSavePanel savePanel];
    int result;
    
    [sp setRequiredFileType:@"txt"];
    result = [sp runModalForDirectory:NSHomeDirectory() file:@"USB Log"];
    if (result == NSOKButton) {
        NSString *finalString;
        
        [_outputLock lock];
        
        finalString = [LoggerOutputTV string];
        
        if (![finalString writeToFile:[sp filename] atomically:YES encoding:NSUTF8StringEncoding error:NULL])
            NSBeep();
        
        [_outputLock unlock];
    }
}*/

- (IBAction)SaveOutput:(id)sender
{
    NSSavePanel *sp = [NSSavePanel savePanel];
    [sp setAllowedFileTypes:[NSArray arrayWithObjects:@"txt", nil]];
    [sp setDirectoryURL:[NSURL URLWithString:NSHomeDirectory()]];
    [sp setNameFieldStringValue:@"USB Log"];
    [sp setExtensionHidden:NO];
    [sp beginSheetModalForWindow:[NSApp mainWindow] completionHandler:^(NSInteger returnCode){
        
//        if (returnCode==NSOKButton)
        if (returnCode==NSModalResponseOK)
        {
            NSString *finalString;
            
            [_outputLock lock];
            
            finalString = [LoggerOutputTV string];
                
            if (![finalString writeToURL:[sp URL] atomically:YES encoding:NSUTF8StringEncoding error:NULL])
            {
                NSBeep();
            }
            [_outputLock unlock];
        }
    }];
}

- (IBAction)Start:(id)sender {
    if (!_klogKextisPresent) {
// PHT int result = NSRunAlertPanel (@"Missing Kernel Extension",
// PHT @"The required kernel extension \"KLog.kext\" is not installed.
// PHT Would you like to install it now?", @"Install", @"Cancel", nil);
        NSAlert *alert = [[NSAlert alloc] init];            // PHT
        [alert addButtonWithTitle:@"Install"];              // PHT
        [alert addButtonWithTitle:@"Cancel"];               // PHT
        [alert setAlertStyle:NSCriticalAlertStyle];         // PHT
        alert.messageText = @"Missing Kernel Extension";    // PHT
        alert.informativeText = @"The required kernel extension \"KLog.kext\" is not installed. Would you like to install it now?";             // PHT
        NSModalResponse result = [alert runModal];          // PHT
        [alert release];                                    // PHT
        
// PHT  if (result == NSAlertDefaultReturn) {
        if (result == NSAlertFirstButtonReturn) {           // PHT
            //try to install
            if ([self installKLogKext] != YES) {
                // error occured while installing, so return
                return;
            } else {
				_klogKextisPresent = YES;
// BUG PHT TO DO if revision is wrong (my test case) then this ignores it
                _klogKextIsCorrectRevision = YES;
			}
        } else {
            // user does not want to install KLog.kext, so return
            return;
        }
    } else if ( !_klogKextIsCorrectRevision ) {
// PHT int result = NSRunAlertPanel (@"Wrong revision for Kernel Extension",
// PHT @"The required kernel extension \"KLog.kext\" is not the right revision.
// PHT Would you like to upgrade it now?", @"Upgrade", @"Cancel", nil);
        NSAlert *alert = [[NSAlert alloc] init];            // PHT
        [alert addButtonWithTitle:@"Upgrade"];              // PHT
        [alert addButtonWithTitle:@"Cancel"];               // PHT
        [alert setAlertStyle:NSCriticalAlertStyle];         // PHT
        alert.messageText = @"Wrong revision for Kernel Extension";    // PHT
        alert.informativeText = @"The required kernel extension \"KLog.kext\" is not the right revision. Would you like to upgrade it now?";                                           // PHT
        NSModalResponse result = [alert runModal];           // PHT
        [alert release];                                     // PHT
        
// PHT  if (result == NSAlertDefaultReturn) {
        if (result == NSAlertFirstButtonReturn) {            // PHT
            //try to install
            if ([self removeAndinstallKLogKext] != YES) {
                // error occured while installing, so return
                return;
            } else {
                
// PHT NSRunAlertPanel (@"Need to Restart", @"The required kernel extension \"KLog.kext\" was installed.
// PHT Please quit and restart.", @"OK", nil, nil);
                NSAlert *alert = [[NSAlert alloc] init];            // PHT
                [alert addButtonWithTitle:@"OK"];                   // PHT
                [alert setAlertStyle:NSCriticalAlertStyle];         // PHT
                alert.messageText = @"Need to Restart";             // PHT
                alert.informativeText = @"The required kernel extension \"KLog.kext\" was installed. Please quit and restart.";                                      // PHT
                [alert runModal];                                   // PHT
                [alert release];                                    // PHT
                
				_klogKextIsCorrectRevision = NO;
				return;
			}
        } else {
            // user does not want to install KLog.kext, so return
            return;
		}
    }
    
    if ([DumpCheckBox state] == NSOnState) 
    {
        NSSavePanel *sp;
// PHT        NSCalendarDate *currentDate = [NSCalendarDate date];
        NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];                // PHT
        dateFormatter.dateStyle = NSDateFormatterMediumStyle;                           // PHT
        NSString *formattedDateString = [dateFormatter stringFromDate:[NSDate date]];   // PHT

        sp = [NSSavePanel savePanel];
        [sp setAllowedFileTypes:[NSArray arrayWithObjects:@"txt", nil]];
        
        [sp setDirectoryURL:[NSURL URLWithString:NSHomeDirectory()]];
        [sp setNameFieldStringValue:@"USB Log"];
        [sp setExtensionHidden:NO];
        [sp beginSheetModalForWindow:[NSApp mainWindow] completionHandler:^(NSInteger returnCode){
            //        if (returnCode==NSOKButton)
            if (returnCode==NSModalResponseOK)
            {
                NSString *theFileName;
                theFileName = [[sp URL] path];
        
                _dumpingFile = fopen ([theFileName cStringUsingEncoding:NSUTF8StringEncoding],"w");
        if (_dumpingFile == NULL) {
// PHT  [self appendOutput:[NSString stringWithFormat:@"%@: Error - unable to open the file %@\n\n",currentDate,theFileName] atLevel:[NSNumber numberWithInt:0]];
            [self appendOutput:[NSString stringWithFormat:@"%@: Error - unable to open the file %@\n\n",formattedDateString,theFileName] atLevel:[NSNumber numberWithInt:0]];   // PHT
        } else {
// PHT   [currentDate setCalendarFormat:@"%b %d %H:%M:%S"];
// PHT    [self appendOutput:[NSString stringWithFormat:@"%@: Saving output to file %@\n\n",currentDate,theFileName]
// PHT      atLevel:[NSNumber numberWithInt:0]];
            
            NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];                // PHT
            dateFormatter.dateStyle = NSDateFormatterMediumStyle;                           // PHT
            NSString *formattedDateString = [dateFormatter stringFromDate:[NSDate date]];   // PHT
            [self appendOutput:[NSString stringWithFormat:@"%@: Saving output to file %@\n\n",formattedDateString,theFileName]
                atLevel:0]; //PHT
        }
                [self actuallyStartLogging];
            }
        }];
        }
    else
    {
        [self actuallyStartLogging];
    }
}

- (void) actuallyStartLogging {
    if (_logger == nil) {
        _logger = [[USBLogger alloc] initWithListener:self level:[[LoggingLevelPopUp selectedItem] tag]];
        
    }
    [_logger beginLogging];
    
    [DumpCheckBox setEnabled:NO];
    [StartStopButton setAction:@selector(Stop:)];
    [StartStopButton setTitle:@"Stop"];
}

- (IBAction)Stop:(id)sender {
    if (_dumpingFile != NULL) {
        fclose(_dumpingFile);
        _dumpingFile = NULL;
    }
    
    if (_logger != nil) {
        [_logger invalidate];
        [_logger release];
        _logger = nil;
    }
    
    [StartStopButton setAction:@selector(Start:)];
    [StartStopButton setTitle:@"Start"];
    [DumpCheckBox setEnabled:YES];
}

- (IBAction)ToggleDumping:(id)sender {
}

- (IBAction)FilterOutput:(id)sender {
    NSRange endMarker;
    NSScroller *scroller = [[LoggerOutputTV enclosingScrollView] verticalScroller];
    BOOL isScrolledToEnd = (![scroller isEnabled] || [scroller floatValue] == 1);
    
    NSEnumerator *lineEnumerator = [_outputLines objectEnumerator];
    LoggerEntry *thisEntry;
    NSString *text;
    NSMutableString *finalOutput = [[NSMutableString alloc] init];
    
    [_currentFilterString release];
    if (![[sender stringValue] isEqualToString:@""]) {
        _currentFilterString = [[sender stringValue] retain];
    } else {
        _currentFilterString = nil;
    }
    
    [_outputLock lock];

    [LoggerOutputTV setString:@""];
    
    //endMarker = NSMakeRange([[LoggerOutputTV string] length], 0);
    
    [FilterProgressIndicator startAnimation:self];
    while (thisEntry = [lineEnumerator nextObject]) {
        text = [thisEntry text];
        if (_currentFilterString == nil || [text rangeOfString:_currentFilterString options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [finalOutput appendString:text];
            //[LoggerOutputTV replaceCharactersInRange:endMarker withString:text];
            //endMarker.location += [text length];
        }
    }

    [LoggerOutputTV replaceCharactersInRange:NSMakeRange(0, [[LoggerOutputTV string] length]) withString:finalOutput];
    [FilterProgressIndicator stopAnimation:self];
    
    if (isScrolledToEnd) {
        endMarker = NSMakeRange([[LoggerOutputTV string] length], 0);
        [LoggerOutputTV scrollRangeToVisible:endMarker];
    }
    [LoggerOutputTV setNeedsDisplay:YES];
    [_outputLock unlock];
    [finalOutput release];
}

- (BOOL)isKlogKextPresent {
		return [[NSFileManager defaultManager] fileExistsAtPath:@"/System/Library/Extensions/KLog.kext"];
	}
	
- (BOOL)isKlogCorrectRevision {
    NSBundle	* klogBundle = [NSBundle bundleWithPath:@"/System/Library/Extensions/KLog.kext"];
    
    if ( klogBundle == nil)
        return NO;
    
    NSDictionary *plist = [klogBundle infoDictionary];
    uint32_t version = [[plist valueForKey:@"CFBundleNumericVersion"] intValue];
    if ( (version < 0x03600000) && (version != 0) )
        return NO;
    else
        return YES;
}
	
- (BOOL)installKLogKext {
    NSString *              sourcePath = [[NSBundle mainBundle] pathForResource:@"KLog" ofType:@"kext"];
    NSString *              destPath = [NSString pathWithComponents:[NSArray arrayWithObjects:@"/",@"System",@"Library",@"Extensions",@"KLog.kext",nil]];
    NSString *              permRepairPath = [[NSBundle mainBundle] pathForResource:@"SetKLogPermissions" ofType:@"sh"];
    
    AuthorizationRights     myRights;
    AuthorizationItem       myItems[1];
    AuthorizationRef        authorizationRef;
    OSStatus                err;

// PHT Is the kext in the NSProberV2 Bundle?
    if ([[NSFileManager defaultManager] fileExistsAtPath:sourcePath] == NO) {

// PHT	NSRunAlertPanel (@"Missing Source File", @"\"KLog.kext\" could not be installed because it is missing
// PHT   from the application bundle.", @"Okay", nil, nil);

        NSAlert *alert = [[NSAlert alloc] init];            // PHT
        [alert addButtonWithTitle:@"OK"];                   // PHT
        [alert setAlertStyle:NSCriticalAlertStyle];         // PHT
        alert.messageText = @"Missing Source File";         // PHT
        alert.informativeText = @"\"KLog.kext\" could not be installed because it is missing from the application bundle."; // PHT
        [alert runModal];                                   // PHT
        [alert release];                                    // PHT
        
        return NO;
    }
    
// PHT The kext exists in the Bundle
    myItems[0].name = kAuthorizationRightExecute;
    myItems[0].valueLength = 0;
    myItems[0].value = NULL;
    myItems[0].flags = 0;
    
    myRights.count = sizeof(myItems) / sizeof(myItems[0]);
    myRights.items = myItems;
    
    err = AuthorizationCreate (&myRights, kAuthorizationEmptyEnvironment, kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights, &authorizationRef);
    
    if (err == errAuthorizationSuccess) {
        char *  cpArgs[4];
        char *  shArgs[2];
        char *  kextloadArgs[2];
        int     status;
        
        cpArgs[0] = "-r";
        cpArgs[1] = (char *)[sourcePath cStringUsingEncoding:NSUTF8StringEncoding];
        cpArgs[2] = (char *)[destPath cStringUsingEncoding:NSUTF8StringEncoding];
        cpArgs[3] = NULL;
    
// PHT Try to copy it to the /Systems/Library/Extensions folder
        err = AuthorizationExecuteWithPrivileges(authorizationRef, "/bin/cp", 0, cpArgs, NULL);
        if (err) return NO;
        
        shArgs[0] = (char *)[permRepairPath cStringUsingEncoding:NSUTF8StringEncoding];
        shArgs[1] = NULL;
        
// PHT Try to set the Kext privileges
        err = AuthorizationExecuteWithPrivileges(authorizationRef, "/bin/sh", 0, shArgs, NULL);
        if (err) return NO;
        
        kextloadArgs[0] = (char *)[destPath cStringUsingEncoding:NSUTF8StringEncoding];
        kextloadArgs[1] = NULL;
        
// PHT Try to load Kext into kernel
        err = AuthorizationExecuteWithPrivileges(authorizationRef, "/sbin/kextload", 0, kextloadArgs, NULL);
// PHT TO DO We want to capture what is written to the console log
// PHT TO DO because the err variable is returning 0 all the time
// PHT TO DO even though executing "sbin/kextload" does write to the console log
        if (err) return NO;
        
        while (wait(&status) != -1) {
            // wait for forked process to terminate
        }
        
        AuthorizationFree(authorizationRef, kAuthorizationFlagDestroyRights);
        return YES;
    } else {
        return NO;
    }
}
	
	- (BOOL)removeAndinstallKLogKext {
		NSString *              sourcePath = [[NSBundle mainBundle] pathForResource:@"KLog" ofType:@"kext"];
		NSString *              destPath = [NSString pathWithComponents:[NSArray arrayWithObjects:@"/",@"System",@"Library",@"Extensions",@"KLog.kext",nil]];
		NSString *              permRepairPath = [[NSBundle mainBundle] pathForResource:@"SetKLogPermissions" ofType:@"sh"];
		
		AuthorizationRights     myRights;
		AuthorizationItem       myItems[1];
		AuthorizationRef        authorizationRef;
		OSStatus                err;
		
		if ([[NSFileManager defaultManager] fileExistsAtPath:sourcePath] == NO) {
// PHT	 NSRunAlertPanel (@"Missing Source File", @"\"KLog.kext\" could not be installed because it is missing
// PHT   from the application bundle.", @"Okay", nil, nil);
            NSAlert *alert = [[NSAlert alloc] init];            // PHT
            [alert addButtonWithTitle:@"OK"];                   // PHT
            [alert setAlertStyle:NSCriticalAlertStyle];         // PHT
            alert.messageText = @"Missing Source File";         // PHT
            alert.informativeText = @"\"KLog.kext\" could not be installed because it is missing from the application bundle."; // PHT
            [alert runModal];                                   // PHT
            [alert release];                                    // PHT
			
            return NO;
		}
        
// PHT The kext exists in the bundle
		myItems[0].name = kAuthorizationRightExecute;
		myItems[0].valueLength = 0;
		myItems[0].value = NULL;
		myItems[0].flags = 0;
		
		myRights.count = sizeof(myItems) / sizeof(myItems[0]);
		myRights.items = myItems;
		
		err = AuthorizationCreate (&myRights, kAuthorizationEmptyEnvironment, kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights, &authorizationRef);
		
		if (err == errAuthorizationSuccess) {
			char *  cpArgs[4];
			char *  shArgs[2];
			char *  kextloadArgs[2];
			int     status;
			
// PHT Remove it from /System/Library/Extensions
			cpArgs[0] = (char *)[destPath cStringUsingEncoding:NSUTF8StringEncoding];
			cpArgs[1] = "/private/tmp";
			cpArgs[2] = NULL;
			cpArgs[3] = NULL;
			
			err = AuthorizationExecuteWithPrivileges(authorizationRef, "/bin/mv", 0, cpArgs, NULL);
			if (err) return NO;
			
// PHT try to copy it to the /Systems/Library/Extensions folder
			cpArgs[0] = "-r";
			cpArgs[1] = (char *)[sourcePath cStringUsingEncoding:NSUTF8StringEncoding];
			cpArgs[2] = (char *)[destPath cStringUsingEncoding:NSUTF8StringEncoding];
			cpArgs[3] = NULL;
			
			err = AuthorizationExecuteWithPrivileges(authorizationRef, "/bin/cp", 0, cpArgs, NULL);
			if (err) return NO;
			
			shArgs[0] = (char *)[permRepairPath cStringUsingEncoding:NSUTF8StringEncoding];
			shArgs[1] = NULL;
// PHT Try to set the Kext privileges
			err = AuthorizationExecuteWithPrivileges(authorizationRef, "/bin/sh", 0, shArgs, NULL);
			if (err) return NO;
			
			kextloadArgs[0] = (char *)[destPath cStringUsingEncoding:NSUTF8StringEncoding];
			kextloadArgs[1] = NULL;
            
// BUG PHT  Whoever wrote this forgot the call to ketload.
// BUG PHT  The next two lines copied from method installKLogKext.
            err = AuthorizationExecuteWithPrivileges(authorizationRef, "/sbin/kextload", 0, kextloadArgs, NULL); // PHT
            if (err) return NO; // PHT

			while (wait(&status) != -1) {
				// wait for forked process to terminate
			}
			
			AuthorizationFree(authorizationRef, kAuthorizationFlagDestroyRights);
			return YES;
		} else {
			return NO;
		}
	}

- (NSArray *)logEntries {
    return _outputLines;
}

- (NSArray *)displayedLogLines {
    return [[LoggerOutputTV string] componentsSeparatedByString:@"\n"];
}

- (void)scrollToVisibleLine:(NSString *)line {
    NSRange textRange = [[LoggerOutputTV string] rangeOfString:line];
    
    if (textRange.location != NSNotFound) {
        [LoggerOutputTV scrollRangeToVisible:textRange];
        [LoggerOutputTV setSelectedRange:textRange];
        [[LoggerOutputTV window] makeFirstResponder:LoggerOutputTV];
        [[LoggerOutputTV window] makeKeyAndOrderFront:self];
    }
}

- (void)handlePendingOutput:(NSTimer *)timer {
    if ([_bufferLock tryLock]) {
        if ([_outputLock tryLock]) {
            if ([_outputBuffer length] > 0) {
                NSRange endMarker = NSMakeRange([[LoggerOutputTV string] length], 0);
                NSScroller *scroller = [[LoggerOutputTV enclosingScrollView] verticalScroller];
                BOOL isScrolledToEnd = (![scroller isEnabled] || [scroller floatValue] == 1);
                
                [LoggerOutputTV replaceCharactersInRange:endMarker withString:_outputBuffer];
                
                if (isScrolledToEnd) {
                    endMarker.location += [_outputBuffer length];
                    [LoggerOutputTV scrollRangeToVisible:endMarker];
                }
                
                [_outputBuffer setString:@""];
                
                [LoggerOutputTV setNeedsDisplay:YES];
            }
            [_outputLock unlock];
        }
        [_bufferLock unlock];
    }
}

- (void)appendOutput:(NSString *)aString atLevel:(NSNumber *)level {
    LoggerEntry *entry = [[LoggerEntry alloc] initWithText:aString level:[level intValue]];

    [_outputLock lock];
    [_outputLines addObject:entry];
    [_outputLock unlock];
    
    [entry release];

    if (_dumpingFile != NULL) {
        fprintf(_dumpingFile, "@%s", [aString cStringUsingEncoding:NSUTF8StringEncoding]);
        fflush(_dumpingFile);
    }
    
    [_bufferLock lock];
    if (_currentFilterString == nil || [aString rangeOfString:_currentFilterString options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [_outputBuffer appendString:aString];
    }
    [_bufferLock unlock];
}

- (void)appendLoggerEntry:(LoggerEntry *)entry {
    NSString *text = [entry text];
    [_outputLock lock];
    [_outputLines addObject:entry];
    [_outputLock unlock];
    
    if (_dumpingFile != NULL) {
        fprintf(_dumpingFile, "@%s", [text cStringUsingEncoding:NSUTF8StringEncoding]);
        fflush(_dumpingFile);
    }
    
    [_bufferLock lock];
    if (_currentFilterString == nil || [text rangeOfString:_currentFilterString options:NSCaseInsensitiveSearch].location != NSNotFound) {
        [_outputBuffer appendString:text];
    }
    [_bufferLock unlock];
}

- (void)usbLoggerTextAvailable:(NSString *)text forLevel:(int)level {
    LoggerEntry *entry = [LoggerEntry cachedFreshEntry];
    [entry setText:text level:level];
    
    [self performSelectorOnMainThread:@selector(appendLoggerEntry:) withObject:entry waitUntilDone:NO];
}

@end


