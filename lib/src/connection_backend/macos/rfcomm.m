// Thin C-callable wrapper around IOBluetooth's RFCOMM API.
//
// On current macOS versions IOBluetooth is backed by CoreBluetooth, and channel events (open
// complete, incoming data, close) are delivered on the main thread's run loop regardless of which
// thread opened the channel. Opening a channel blocks until that event arrives, so the process must
// keep its main run loop running (see scq_main_run_loop_run). The functions here may be called from
// any thread except the main thread (they block waiting for main thread events). Callbacks into
// Rust are invoked on the main thread and must not block.

#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

#include <stdint.h>
#include <string.h>

typedef void (*scq_device_cb)(void *ctx, const char *name, const uint8_t mac[6]);
typedef void (*scq_service_cb)(void *ctx, const uint8_t uuid[16], uint8_t channel_id);
typedef void (*scq_data_cb)(void *ctx, const uint8_t *data, size_t len);
typedef void (*scq_closed_cb)(void *ctx);

#define SCQ_OK 0
#define SCQ_ERR_DEVICE_NOT_FOUND 1
#define SCQ_ERR_IO 3

// ---------------------------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------------------------

static IOBluetoothDevice *scq_find_device(const uint8_t mac[6]) {
    BluetoothDeviceAddress address;
    memcpy(address.data, mac, 6);
    return [IOBluetoothDevice deviceWithAddress:&address];
}

// Extracts all 128-bit UUIDs from the ServiceClassIDList attribute of an SDP record.
static NSArray<NSData *> *scq_record_uuids(IOBluetoothSDPServiceRecord *record) {
    NSMutableArray<NSData *> *uuids = [NSMutableArray array];
    IOBluetoothSDPDataElement *classIdList =
        [record getAttributeDataElement:kBluetoothSDPAttributeIdentifierServiceClassIDList];
    if (classIdList == nil) {
        return uuids;
    }
    // IOBluetooth flattens single element sequences, so this is either a sequence of UUIDs or a
    // bare UUID.
    NSArray *elements = [classIdList getTypeDescriptor] == kBluetoothSDPDataElementTypeUUID
                            ? @[ classIdList ]
                            : [classIdList getArrayValue];
    for (IOBluetoothSDPDataElement *element in elements) {
        IOBluetoothSDPUUID *uuid = [element getUUIDValue];
        if (uuid == nil) {
            continue;
        }
        IOBluetoothSDPUUID *uuid128 = [uuid getUUIDWithLength:16];
        if (uuid128 != nil && uuid128.length == 16) {
            [uuids addObject:[NSData dataWithBytes:uuid128.bytes length:16]];
        }
    }
    return uuids;
}

// ---------------------------------------------------------------------------------------------
// SDP query (used when the cached service list is empty)
// ---------------------------------------------------------------------------------------------

@interface SCQSDPQueryTarget : NSObject
@property(nonatomic, strong) dispatch_semaphore_t semaphore;
@property(nonatomic, assign) IOReturn status;
@end

@implementation SCQSDPQueryTarget
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    self.status = status;
    dispatch_semaphore_signal(self.semaphore);
}
@end

static void scq_refresh_services(IOBluetoothDevice *device) {
    SCQSDPQueryTarget *target = [[SCQSDPQueryTarget alloc] init];
    target.semaphore = dispatch_semaphore_create(0);
    if ([NSThread isMainThread]) {
        // The completion is delivered on the main thread, so we can't wait for it here
        return;
    }
    if ([device performSDPQuery:target] == kIOReturnSuccess) {
        dispatch_semaphore_wait(target.semaphore,
                                dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    }
}

// ---------------------------------------------------------------------------------------------
// Channel
// ---------------------------------------------------------------------------------------------

@interface SCQChannel : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property(nonatomic, strong) IOBluetoothRFCOMMChannel *channel;
@property(nonatomic, strong) IOBluetoothDevice *device;
@property(nonatomic, assign) scq_data_cb dataCallback;
@property(nonatomic, assign) scq_closed_cb closedCallback;
@property(nonatomic, assign) void *context;
@property(nonatomic, assign) BOOL closed;
@property(nonatomic, strong) dispatch_semaphore_t openSemaphore;
@property(nonatomic, assign) IOReturn openStatus;
@end

@implementation SCQChannel

- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)rfcommChannel status:(IOReturn)error {
    self.openStatus = error;
    dispatch_semaphore_signal(self.openSemaphore);
}

// `closed` is guarded by @synchronized(self) so that once scq_rfcomm_close returns, no callback
// can be running or start running with a dangling context.

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)rfcommChannel
                     data:(void *)dataPointer
                   length:(size_t)dataLength {
    @synchronized(self) {
        if (!self.closed) {
            self.dataCallback(self.context, (const uint8_t *)dataPointer, dataLength);
        }
    }
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)rfcommChannel {
    @synchronized(self) {
        if (!self.closed) {
            self.closed = YES;
            self.closedCallback(self.context);
        }
    }
}

- (void)close {
    @synchronized(self) {
        self.closed = YES;
        [self.channel setDelegate:nil];
        [self.channel closeChannel];
        self.channel = nil;
    }
}

@end

// ---------------------------------------------------------------------------------------------
// Public C API
// ---------------------------------------------------------------------------------------------

// Lists paired devices that are currently connected.
void scq_bt_connected_devices(scq_device_cb callback, void *ctx) {
    @autoreleasepool {
        NSArray *devices = [IOBluetoothDevice pairedDevices];
        for (IOBluetoothDevice *device in devices) {
            if (![device isConnected]) {
                continue;
            }
            const BluetoothDeviceAddress *address = [device getAddress];
            if (address == NULL) {
                continue;
            }
            NSString *name = [device name];
            const char *cName = name != nil ? [name UTF8String] : "";
            callback(ctx, cName, address->data);
        }
    }
}

// Lists the RFCOMM services advertised by the device as (uuid, channel id) pairs. A service with
// multiple UUIDs in its class id list is reported once per UUID.
int scq_bt_rfcomm_services(const uint8_t mac[6], scq_service_cb callback, void *ctx) {
    @autoreleasepool {
        IOBluetoothDevice *device = scq_find_device(mac);
        if (device == nil) {
            return SCQ_ERR_DEVICE_NOT_FOUND;
        }
        NSArray *services = [device services];
        if (services == nil || services.count == 0) {
            scq_refresh_services(device);
            services = [device services];
        }
        for (IOBluetoothSDPServiceRecord *record in services) {
            BluetoothRFCOMMChannelID channelId = 0;
            if ([record getRFCOMMChannelID:&channelId] != kIOReturnSuccess) {
                continue;
            }
            for (NSData *uuid in scq_record_uuids(record)) {
                callback(ctx, (const uint8_t *)uuid.bytes, channelId);
            }
        }
        return SCQ_OK;
    }
}

// Opens an RFCOMM channel. Returns an opaque handle, or NULL on failure with `error_out` set.
void *scq_rfcomm_open(const uint8_t mac[6],
                      uint8_t channel_id,
                      scq_data_cb data_callback,
                      scq_closed_cb closed_callback,
                      void *ctx,
                      int *error_out) {
    @autoreleasepool {
        IOBluetoothDevice *device = scq_find_device(mac);
        if (device == nil) {
            *error_out = SCQ_ERR_DEVICE_NOT_FOUND;
            return NULL;
        }
        SCQChannel *wrapper = [[SCQChannel alloc] init];
        wrapper.device = device;
        wrapper.dataCallback = data_callback;
        wrapper.closedCallback = closed_callback;
        wrapper.context = ctx;

        // The sync variant needs a run loop on the calling thread, so open asynchronously and wait
        // for the completion event, which arrives on the main thread.
        wrapper.openSemaphore = dispatch_semaphore_create(0);
        wrapper.openStatus = kIOReturnError;
        IOBluetoothRFCOMMChannel *channel = nil;
        IOReturn result = [device openRFCOMMChannelAsync:&channel
                                           withChannelID:channel_id
                                                delegate:wrapper];
        if (result != kIOReturnSuccess || channel == nil) {
            *error_out = SCQ_ERR_IO;
            return NULL;
        }
        wrapper.channel = channel;
        if (dispatch_semaphore_wait(wrapper.openSemaphore,
                                    dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC)) != 0 ||
            wrapper.openStatus != kIOReturnSuccess) {
            [wrapper close];
            *error_out = SCQ_ERR_IO;
            return NULL;
        }
        *error_out = SCQ_OK;
        return (void *)CFBridgingRetain(wrapper);
    }
}

// Writes `len` bytes as a single RFCOMM frame where possible (splitting at the channel MTU).
int scq_rfcomm_write(void *handle, const uint8_t *data, size_t len) {
    @autoreleasepool {
        SCQChannel *wrapper = (__bridge SCQChannel *)handle;
        IOBluetoothRFCOMMChannel *channel = wrapper.channel;
        if (wrapper.closed || channel == nil) {
            return SCQ_ERR_IO;
        }
        BluetoothRFCOMMMTU mtu = [channel getMTU];
        IOReturn result = kIOReturnSuccess;
        size_t offset = 0;
        while (offset < len && result == kIOReturnSuccess) {
            size_t chunk = len - offset;
            if (mtu > 0 && chunk > mtu) {
                chunk = mtu;
            }
            result = [channel writeSync:(void *)(data + offset) length:(UInt16)chunk];
            offset += chunk;
        }
        return result == kIOReturnSuccess ? SCQ_OK : SCQ_ERR_IO;
    }
}

// Closes the channel and releases the handle. The callbacks will not be invoked after this returns.
void scq_rfcomm_close(void *handle) {
    @autoreleasepool {
        SCQChannel *wrapper = (__bridge_transfer SCQChannel *)handle;
        [wrapper close];
    }
}

// Runs the main thread's run loop until scq_main_run_loop_stop is called. Must be called from the
// main thread.
void scq_main_run_loop_run(void) {
    // CFRunLoopRun returns immediately if there are no input sources, so add a dummy one
    [[NSRunLoop mainRunLoop] addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
    CFRunLoopRun();
}

// Stops a run loop started with scq_main_run_loop_run. May be called from any thread.
void scq_main_run_loop_stop(void) {
    CFRunLoopStop(CFRunLoopGetMain());
}
