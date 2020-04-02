#import "BLE.h"
#include <stdio.h>
#include <sys/time.h>

@import CoreBluetooth;
@import Foundation;

/*
 BIG TODO LIST:
 
 Implement:
  new ID generation protocol
  token and contact logging
  conneciton timeout using a timer (done-ish)
  add delay to write from read
  add define based heavy debugging
  handle restore events
  properly understand how to handle RSSI
 */

//set this to enable high volume logging disable for release!
#define DBG_LOG
//set this to make the protocol to act in non-conforming, but extremely fast. good for developing.
#define USE_FAST_DEV_VALUES

//we let up to this many times of leeway for the timer subsystem to delay execution
#define TIMER_LEEWAY 5

//global config options

#ifdef USE_FAST_DEV_VALUES
static int64_t contact_log_interval_in_secs = 5; //active contact logging
static int64_t local_id_write_interval_in_secs = 10; //send my id to remote devices / passive logging
static int64_t remote_id_read_interval_in_secs = 20; //read remote id
static int64_t device_cache_ttl_in_secs = 1 * 60; //drop local cache on remote device
static int64_t crypto_id_update_schedule_in_secs = 15 * 60;
#else
static int64_t contact_log_interval_in_secs = 5 * 60; //active contact logging
static int64_t local_id_write_interval_in_secs = 10 * 60;
static int64_t remote_id_read_interval_in_secs = 15 * 60;
static int64_t device_cache_ttl_in_secs = 30 * 60;
static int64_t crypto_id_update_schedule_in_secs = 15 * 60;

#endif


static int64_t conn_start_timeout_in_seconds = 5;


static NSString *_serviceUUID;
static NSString *_characteristicUUID;

static FILE* _contactsLogFile;

//active contact means we reached out and read the ID of device
#define CONTACT_ACTIVE 1
//active contact means a device reached out to us and send their ID
#define CONTACT_PASSIVE 2


static int64_t get_now_secs(void)
{
  struct timeval tv = {0};
  if(gettimeofday(&tv, NULL))
    NSLog(@"gettimeofday failed with %d", errno);

  return ((int64_t)tv.tv_sec);
}

static dispatch_source_t create_recurring_timer(int64_t interval_sec, void (^block)(void))
{
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  if(timer)
  {
    dispatch_source_set_timer(timer,
                              dispatch_walltime(NULL, 0),
                              interval_sec * NSEC_PER_SEC,
                              interval_sec * NSEC_PER_SEC * TIMER_LEEWAY);

    dispatch_source_set_event_handler(timer, block);
    dispatch_resume(timer);
  }
  return timer;
}

static dispatch_source_t create_one_shot_timer(int64_t delay_in_secs, void (^block)(void))
{
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
  if(timer)
  {
    dispatch_source_set_timer(timer,
                              dispatch_walltime(NULL, delay_in_secs * NSEC_PER_SEC),
                              1 * NSEC_PER_SEC,
                              1 * NSEC_PER_SEC * TIMER_LEEWAY);

    __weak dispatch_source_t w_timer = timer;
      dispatch_source_set_event_handler(timer, ^{
      block();
      dispatch_source_t tmp = w_timer;
      if(tmp)
        dispatch_source_cancel(w_timer);
    });
    dispatch_resume(timer);
  }
  return timer;
}

@protocol BleLogger
-(void) logDebug: (id)payload;
-(void) logCritical: (id)payload;
-(NSData*)currentTokenData;
-(CBCentralManager *) cbc;
-(void) flushCache: (CBPeripheral*)peripheral;
-(void)logContact: (NSString *)token at:(time_t)at rssi:(int)rssi kind:(int)kind;
@end


typedef enum {
  OpIgnore,
  OpRequested,
  OpInProgress,
  OpDone
} OpStage;

@interface PeripheralContactHelper: NSObject<CBPeripheralDelegate>

-(instancetype)initWithPeripheral: (CBPeripheral*)peripheral logger: (id<BleLogger>)logger;

@property NSString *token;

//methods called by CBCentralManagerDelegate
-(void)didConnect;
-(void)didFailToConnect: (NSError*)error;
-(void)didScan:(NSDictionary<NSString *,id> *)data rssi:(int)rssi;

@end

#define OPS_COUNT 2
#define OP_READ 0
#define OP_WRITE 1


@implementation PeripheralContactHelper {
  CBPeripheral *_peripheral;
  __weak id<BleLogger> _logger;
  
  int64_t _creation_time;

  dispatch_source_t _read_timer;
  dispatch_source_t _write_timer;
  dispatch_source_t _cache_flush_timer;
  dispatch_source_t _timeout_timer;

  OpStage _ops[OPS_COUNT];
  bool _connectionInProgress;
  CBCharacteristic *_contact_characteristic;

  int64_t _lastContactFlush;
  int _rssi;
}

-(instancetype)initWithPeripheral: (CBPeripheral*)peripheral logger: (id<BleLogger>)logger
{
  _peripheral = peripheral;
  _logger = logger;
  //we set _lastContactFlush to force at least one tick before logging
  _creation_time = _lastContactFlush = get_now_secs();
  _rssi = INT_MIN;

  _peripheral.delegate = self;
  [self cancelConnection];

  //fresh new device, let's schedule IO
  __weak PeripheralContactHelper *w_self = self;

  _read_timer = create_recurring_timer(remote_id_read_interval_in_secs, ^ {
    [w_self queueRead];
  });

  _write_timer = create_recurring_timer(local_id_write_interval_in_secs, ^ {
    [w_self queueWrite];
  });

  _cache_flush_timer = create_one_shot_timer(device_cache_ttl_in_secs, ^{
    [w_self cache_timeout];
  });
  
  [_logger logDebug:[NSString stringWithFormat:@"new PCH for device %@", peripheral.identifier]];
  return self;
}

-(void)queueRead {
  [_logger logDebug:[NSString stringWithFormat:@"queue read for %@", _peripheral.identifier]];
  //only start if there isn't one in progress
  if(_ops[OP_READ] == OpIgnore)
    _ops[OP_READ] = OpRequested;
  [self beingConnectIfNeeded];
}

-(void)queueWrite {
  [_logger logDebug:[NSString stringWithFormat:@"queue write for %@", _peripheral.identifier]];
  if(_ops[OP_WRITE] == OpIgnore)
    _ops[OP_WRITE] = OpRequested;
  [self beingConnectIfNeeded];
}

-(void)cache_timeout {
  [_logger logDebug:[NSString stringWithFormat:@"cache timeout for %@", _peripheral.identifier]];
  dispatch_source_cancel(_read_timer);
  dispatch_source_cancel(_write_timer);
  [self cancelConnection];
  [_logger flushCache: _peripheral];
}

-(void)beingConnectIfNeeded {
  if(_connectionInProgress)
    return;
  switch(_peripheral.state)
  {
    case CBPeripheralStateConnected:
    case CBPeripheralStateConnecting:
      break;
    default: {
      [_logger.cbc connectPeripheral:_peripheral options:nil];

      __weak PeripheralContactHelper *w_self = self;
      _timeout_timer = create_one_shot_timer(conn_start_timeout_in_seconds, ^{
        [w_self checkForTimeout];
      });
      _connectionInProgress = true;

      break;
    }
  }
}

-(void) checkForTimeout {
  [_logger logDebug:[NSString stringWithFormat:@"connection timeout for %@", _peripheral.identifier]];
  [self cancelConnection];
}

-(void) cancelConnection {
  [_logger.cbc cancelPeripheralConnection:_peripheral];
  for(int i = 0; i < OPS_COUNT; ++i) {
    _ops[i] = OpIgnore;
  }
  if(_timeout_timer) {
    dispatch_source_cancel(_timeout_timer);
    _timeout_timer = nil;
  }
  _contact_characteristic = nil;
  _connectionInProgress = false;
}

-(void)updateIo
{
  int done_or_ignore = 0;
  
  for(int i = 0; i < OPS_COUNT; ++i) {
    switch(_ops[i]) {
    case OpIgnore: //nothing to do
        ++done_or_ignore;
        break;
    case OpRequested:
        if(_contact_characteristic) {
          if(i == OP_READ) {
             [_peripheral readValueForCharacteristic:_contact_characteristic];
          } else {
            [_peripheral writeValue:[_logger currentTokenData] forCharacteristic:_contact_characteristic type:CBCharacteristicWriteWithResponse];
          }
          _ops[i] = OpInProgress;
        } else {
          [self beingConnectIfNeeded];
        }
        break;
      case OpInProgress: //this is done by the completion cbs
        break;
      case OpDone:
        ++done_or_ignore;
        break;
    }
  }
  if(done_or_ignore == OPS_COUNT)
    [self cancelConnection];
}

-(void)didConnect
{
  [_logger logDebug:[NSString stringWithFormat:@"connect ok. discovering services of %@", _peripheral.identifier]];
  [_peripheral discoverServices:@[ [CBUUID UUIDWithString: _serviceUUID]]];
}

-(void)didFailToConnect: (NSError*)error
{
  [_logger logDebug:[NSString stringWithFormat:@"failed to connect to %@ due to %@", _peripheral.identifier, error]];
  [self cancelConnection];
}


//BLE callbacks

-(void)tryFlushContact
{
  int64_t now = get_now_secs();
  if((now - _lastContactFlush) > contact_log_interval_in_secs && _token != nil) {
    [_logger logContact: _token at:_lastContactFlush rssi:_rssi kind:CONTACT_ACTIVE];
    _lastContactFlush = now;
    _rssi = INT_MIN;
  }
}
     
-(void)didScan:(NSDictionary<NSString *,id> *)data rssi:(int)rssi
{
  _rssi = MAX(_rssi, rssi);
  [self tryFlushContact];
}

//Delegate callbacks

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error
{
  if(error)
  {
    [self cancelConnection];
    [_logger logDebug:[NSString stringWithFormat: @"discover services failed with %@", error]];
    return;
  }
  CBUUID *chr_id = [CBUUID UUIDWithString:_characteristicUUID];
  //TODO check service id
  for(CBService *s in peripheral.services) {
    if([s.UUID isEqual: [CBUUID UUIDWithString:_serviceUUID]]) {
      [peripheral discoverCharacteristics:@[chr_id] forService:s];
      break;
    }
  }
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error
{
  if(error) {
    [self cancelConnection];
    [_logger logDebug:[NSString stringWithFormat: @"discovered characteristics failed with %@", error]];
    return;
  }

  CBUUID *chr_id = [CBUUID UUIDWithString:_characteristicUUID];
  for(CBCharacteristic *chr in service.characteristics)
  {
    if([chr.UUID isEqual:chr_id]) {
      _contact_characteristic = chr;
      break;
    }
  }
  [self updateIo];
}

- (void)peripheral:(CBPeripheral *)peripheral didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
  if(error)
  {
    [_logger logDebug:[NSString stringWithFormat: @"[%lld] read %@ failed: %@", get_now_secs(), peripheral.identifier, error]];
    //XXX don't break connection on read failure as writes could be happening
  }
  else
  {
    NSString *uuid = [[[NSUUID alloc] initWithUUIDBytes:characteristic.value.bytes] UUIDString];
    [_logger logDebug:[NSString stringWithFormat: @"[%lld] read %@ => %@", get_now_secs(), peripheral.identifier, uuid]];

    self.token = uuid;
    [self tryFlushContact];
  }

  _ops[OP_READ] = OpDone;
  [self updateIo];
}

- (void)peripheral:(CBPeripheral *)peripheral didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error
{
  if(error) {
    [_logger logDebug:[NSString stringWithFormat: @"[%lld] write characteristic failed with %@", get_now_secs(), error]];
  } else {
      [_logger logDebug: [NSString stringWithFormat: @"[%lld] write success %@", get_now_secs(), peripheral.identifier]];
  }

  _ops[OP_WRITE] = OpDone;
  [self updateIo];
}

@end

@implementation BLE {
  CBCentralManager *cbCentralManager;
  CBPeripheralManager *cbPeripheralManager;

  NSUUID *currentToken;
  dispatch_source_t token_renew_timer;
  
  NSMutableDictionary<NSString*, PeripheralContactHelper*> *device_cache;
}

RCT_EXPORT_MODULE();

/**
 * React native module integration
 */
- (NSArray<NSString *> *)supportedEvents
{
  return @[@"onLifecycleEvent", @"onTokenChange", @"onContact"];
}


/**
 * BleLogger
 */
-(CBCentralManager *) cbc
{
  return self->cbCentralManager;
}

/**
 * Exported API
 */


RCT_EXPORT_METHOD(init_module: (NSString *)serviceUUID :(NSString *)characteristicUUID)
{
  if(_serviceUUID != nil)
    return;

  _serviceUUID = serviceUUID;
  _characteristicUUID = characteristicUUID;

  NSURL *url = [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
  url = [url URLByAppendingPathComponent:@"contacts.txt"];

  _contactsLogFile = fopen(url.path.UTF8String, "a");
  [self logCritical: [NSString stringWithFormat:@"BLE backend inited contact file is %@ did open %d", url.path, _contactsLogFile != NULL ]];
}

RCT_EXPORT_METHOD(start_ble)
{
  if(cbCentralManager != nil)
  {
    [self logCritical: @"BLE already inited" ];
    return;
  }

  NSDictionary *cbc_options = @{
  CBCentralManagerOptionRestoreIdentifierKey: @"tracedefense.scanner."
  };

  cbCentralManager = [[CBCentralManager alloc]
                    initWithDelegate: self
                    queue: dispatch_get_main_queue()
                    options: cbc_options];

  NSDictionary *cbp_options = @{
  CBPeripheralManagerOptionRestoreIdentifierKey: @"tracedefense.peripheral."
  };

  cbPeripheralManager = [[CBPeripheralManager alloc]
                       initWithDelegate: self
                       queue: dispatch_get_main_queue()
                       options: cbp_options];


  device_cache = [[NSMutableDictionary alloc] init];

  [self logCritical: @"BLE init successfull" ];
}

RCT_EXPORT_METHOD(stop_ble)
{
  if(cbCentralManager == nil)
  {
    [self logCritical: @"BLE not enabled" ];
    return;
  }

  if (cbCentralManager.isScanning)
  [cbCentralManager stopScan];

  cbCentralManager.delegate = nil;
  cbCentralManager = nil;

  if(cbPeripheralManager.isAdvertising)
  [cbPeripheralManager stopAdvertising];

  [cbPeripheralManager removeAllServices];

  cbPeripheralManager.delegate = nil;
  cbPeripheralManager = nil;
  device_cache = nil;

  [self logCritical: @"BLE stopped" ];
}

/**
 * Logging
 */

 -(void) flushCache: (CBPeripheral*)peripheral {
      
  }
-(void) logTokenChange: (NSString *)token at:(time_t)at  {
  [self sendEventWithName:@"onTokenChange" body:@[token, [NSNumber numberWithLong:at]]];
}

-(void) logContact: (NSString *)token at:(time_t)at rssi:(int)rssi kind:(int)kind {
  [self sendEventWithName:@"onContact" body:@[token, [NSNumber numberWithLong:at], [NSNumber numberWithInt:rssi], [NSNumber numberWithInt:kind]]];

  if(_contactsLogFile) {
    NSString *str = [NSString stringWithFormat:@"{\"uuid\":\"%s\" , \"timestamp\":%lld, \"rssi\":%d , \"kind\":%d }\n",
             (char*)token.UTF8String,
             (int64_t)at,
             rssi,
             kind];
    NSData *data = [str dataUsingEncoding:NSUTF8StringEncoding];
    fwrite(data.bytes, data.length, 1, _contactsLogFile);
    fflush(_contactsLogFile);
  }
}

-(void) logCritical: (id)payload {
  [self sendEventWithName:@"onLifecycleEvent" body:payload ];
  NSLog(@"TraceDefense::CRIT:: %@", payload);
}

-(void) logDebug: (id)payload {
#ifdef DBG_LOG
  [self sendEventWithName:@"onLifecycleEvent" body:payload ];
  NSLog(@"TraceDefense::INFO:: %@", payload);
#endif
}

/**
*CBCentralManagerDelegate Impl
*/
-(void)centralManagerDidUpdateState:(CBCentralManager *)central {
  [self logCritical:[NSString stringWithFormat:@"CBM State update: %ld", (long)central.state] ];

  if (central.state == CBManagerStatePoweredOn) {
    NSArray *services = @[ [CBUUID UUIDWithString: _serviceUUID] ];
      
    NSDictionary *options = @{
      CBCentralManagerScanOptionAllowDuplicatesKey: @1
    };
    
    [ cbCentralManager scanForPeripheralsWithServices: services options: options ];
    [self logCritical: @"BLE scan started"];
  } else {
    [self logCritical: @"Bluetooth not enabled"];
  }
}

- (void)centralManager:(CBCentralManager *)central willRestoreState:(NSDictionary<NSString *,id> *)dict {
  [self logCritical: @"restoring CBCentral state"];
}

-(void)centralManager:(CBCentralManager *)central
  didDiscoverPeripheral:(CBPeripheral *)peripheral
  advertisementData:(NSDictionary<NSString *,id> *)advertisementData
  RSSI:(NSNumber *)RSSI {

  PeripheralContactHelper *pch = device_cache[peripheral.identifier.UUIDString];
  if(!pch) {
    pch = [[PeripheralContactHelper alloc] initWithPeripheral:peripheral logger:self];
    device_cache[peripheral.identifier.UUIDString] = pch;
  }
  [pch didScan:advertisementData rssi:[RSSI intValue]];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral
{
  PeripheralContactHelper *pch = device_cache[peripheral.identifier.UUIDString];
  if(pch)
    [pch didConnect];
  else
    [self logDebug:[NSString stringWithFormat:@"didConnect: did not find PTD for %@", peripheral.identifier]];

}

- (void)centralManager:(CBCentralManager *)central didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error
{
  PeripheralContactHelper *pch = device_cache[peripheral.identifier.UUIDString];
  if(pch)
    [pch didFailToConnect: error];
  else
    [self logDebug:[NSString stringWithFormat:@"didFailConnect: did not find PTD for %@ err %@", peripheral.identifier, error]];

}

/**
 *CBPeripheralManagerDelegate Impl
 */

- (void)peripheralManager:(CBPeripheralManager *)peripheral willRestoreState:(NSDictionary<NSString *,id> *)dict
{
  [self logCritical:@"restoring CBPeripheralManager state"];
}


time_t lastTokenUpdate;

-(NSData*)currentTokenData
{
  time_t now = get_now_secs();
  if((now - lastTokenUpdate) > crypto_id_update_schedule_in_secs) {
    NSUUID *newToken = [NSUUID UUID];
    [self logDebug:[NSString stringWithFormat:@"Updating token from %@ to %@", currentToken, newToken]];
    currentToken = newToken;
    [self logTokenChange:[newToken UUIDString] at:now
    ];
    lastTokenUpdate = now;
  }

  uuid_t uuid;
  [currentToken getUUIDBytes: (u_char*)&uuid];
  return [NSData dataWithBytes:&uuid length:16];
}

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral
{
  [self logCritical:[NSString stringWithFormat:@"CBP State update: %ld", (long)peripheral.state] ];

  if (peripheral.state == CBPeripheralManagerStatePoweredOn)
  {

    CBUUID *characteristicUUID = [CBUUID UUIDWithString: _characteristicUUID];
    CBCharacteristicProperties properties = CBCharacteristicPropertyRead | CBCharacteristicPropertyWrite;
    CBAttributePermissions permissions = CBAttributePermissionsReadable | CBAttributePermissionsWriteable;
    
    CBMutableCharacteristic *service_characteristic = [[CBMutableCharacteristic alloc]
                                     initWithType:characteristicUUID
                                     properties:properties
                                     value:nil
                                     permissions:permissions];

    CBMutableService *the_service = [[CBMutableService alloc] initWithType:[CBUUID UUIDWithString: _serviceUUID] primary:YES];
    [the_service setCharacteristics: @[service_characteristic]];

    [peripheral removeAllServices];
    [peripheral addService:the_service];
    [self logDebug:@"CBP service added"];
  }
  else
  {
    [self logCritical:@"CBP Bluetooth peripheral not enabled"];
  }
}


- (void)peripheralManager:(CBPeripheralManager *)peripheral didAddService:(CBService *)service error:(NSError *)error
{
  
  if(error != nil)
  {
    [self logCritical:[NSString stringWithFormat: @"CBP add service failed due to %@", error]];
  }
  else
  {
    [cbPeripheralManager startAdvertising:@{
      CBAdvertisementDataLocalNameKey: @"tracedefense.app.",
      CBAdvertisementDataServiceUUIDsKey: @[ [CBUUID UUIDWithString:_serviceUUID] ]
    }];
    [self logCritical:@"CBP service advertising started"];
  }
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error
{
  if(error != nil)
  {
    [self logCritical:[NSString stringWithFormat: @"CBP start advertising failed due to %@", error] ];
  }
  else
  {
    [self logCritical:@"CBP start advertising success"];
  }
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveReadRequest:(CBATTRequest *)request
{
  request.value = [self currentTokenData];
  [peripheral respondToRequest:request withResult:CBATTErrorSuccess];
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral didReceiveWriteRequests:(NSArray<CBATTRequest *> *)requests
{
  for(CBATTRequest *req in requests)
  {
//    req.central.identifier;
    if(req.value == nil) {
      [peripheral respondToRequest:req withResult:CBATTErrorUnlikelyError];
      [self logDebug:@"Bad write request with no data"];
      continue;
    }

    if(req.value.length != 16) {
      [peripheral respondToRequest:req withResult:CBATTErrorUnlikelyError];
      [self logDebug:[NSString stringWithFormat:@"Bad write request with wrong data size %ld", req.value.length]];
      continue;
    }

    NSString *uuid = [[[NSUUID alloc] initWithUUIDBytes:req.value.bytes] UUIDString];
    [self logDebug:[NSString stringWithFormat:@"Received remove token: %@", uuid]];
    [self logContact:uuid at:get_now_secs() rssi:INT_MIN kind:CONTACT_PASSIVE];
    [peripheral respondToRequest:req withResult:CBATTErrorSuccess];
  }
}

@end

