#import <Cocoa/Cocoa.h>

@class ConnectionGatePanel;

@protocol ConnectionGatePanelDelegate <NSObject>
- (void)connectionGateDidComplete:(ConnectionGatePanel *)gate;
@end

@interface ConnectionGatePanel : NSViewController
@property (nonatomic, weak) id<ConnectionGatePanelDelegate> delegate;
@end
