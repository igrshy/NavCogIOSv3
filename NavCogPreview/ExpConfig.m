/*******************************************************************************
 * Copyright (c) 2014, 2016  IBM Corporation, Carnegie Mellon University and others
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *******************************************************************************/
#import "ExpConfig.h"
#import "HLPDataUtil.h"
#import "ServerConfig+Preview.h"

@implementation ExpConfig

static ExpConfig *instance;

+ (instancetype)sharedConfig
{
    if (!instance) {
        instance = [[ExpConfig alloc] init];
    }
    return instance;
}

- (instancetype) init
{
    self = [super init];
    return self;
}

- (void)requestUserInfo:(NSString*)user_id withComplete:(void(^)(NSDictionary*))complete
{
    _user_id = user_id;
    NSString *server_host = [[ServerConfig sharedConfig] expServerHost];
    NSString *https = [[[ServerConfig sharedConfig].selected objectForKey:@"use_http"] boolValue] ? @"http": @"https";
    
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/user?id=%@",https, server_host, user_id]];
    
    [HLPDataUtil getJSON:url withCallback:^(NSObject *result) {
        if (result && [result isKindOfClass:NSDictionary.class]) {
            _userInfo = (NSDictionary*)result;
            complete(self.userInfo);
        } else {
            complete(nil);
        }
    }];
}


- (void)requestRoutesConfig:(void(^)(NSDictionary*))complete
{
    NSString *server_host = [[ServerConfig sharedConfig] expServerHost];
    NSString *https = [[[ServerConfig sharedConfig].selected objectForKey:@"use_http"] boolValue] ? @"http": @"https";
    NSString *routes_file_name = @"exp_routes.json";
    
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/%@",https, server_host, routes_file_name]];
    
    [HLPDataUtil getJSON:url withCallback:^(NSObject *result) {
        if (result && [result isKindOfClass:NSDictionary.class]) {
            _expRoutes = (NSDictionary*)result;
            complete(self.expRoutes);
            [[NSNotificationCenter defaultCenter] postNotificationName:EXP_ROUTES_CHANGED_NOTIFICATION object:self];
        } else {
            complete(nil);
        }
    }];
}

- (void)endExpStartAt:(double)startAt withLogFile:(NSString *)logFile withComplete:(void (^)())complete
{
    NSError *error;
    
    NSString *logFileName = [logFile lastPathComponent];
    NSString *logFileId = [NSString stringWithFormat:@"%@/%@", _user_id, logFileName];
    NSString *logContent = [NSString stringWithContentsOfFile:logFile encoding:NSUTF8StringEncoding error:&error];
    
    double endAt = [[NSDate date] timeIntervalSince1970];
    double duration = endAt - startAt;
    NSString *routeName = _currentRoute[@"name"];
    
    NSMutableDictionary *info = [_userInfo mutableCopy];
    if (info[@"_id"] == nil) {
        info[@"_id"] = _user_id;
    }
    
    NSMutableArray *routes = [@[] mutableCopy];
    if (!info[@"routes"]) {
        info[@"routes"] = @[];
    }
    BOOL flag = YES;
    for(NSDictionary *route in info[@"routes"]) {
        if ([route[@"name"] isEqualToString:routeName]) {
            flag = NO;
            break;
        }
    }
    if (flag) {
        info[@"routes"] = [info[@"routes"] arrayByAddingObject:@{@"name":routeName, @"limit":_currentRoute[@"limit"]}];
    }
    for(NSDictionary *route in info[@"routes"]) {
        if ([route[@"name"] isEqualToString:routeName]) {
            NSMutableDictionary *temp = [route mutableCopy];
            temp[@"elapsed_time"] = @([temp[@"elapsed_time"] doubleValue] + duration);
            if (!temp[@"activities"]) {
                temp[@"activities"] = @[];
            }
            temp[@"activities"] = [temp[@"activities"] arrayByAddingObject:
                                   @{
                                     @"start_at": @(startAt),
                                     @"end_at": @(endAt),
                                     @"duration": @(duration),
                                     @"log_file": logFileId
                                     }];
            [routes addObject:temp];
        } else {
            [routes addObject:route];
        }
    }
    info[@"routes"] = routes;

    NSString *server_host = [[ServerConfig sharedConfig] expServerHost];
    NSString *https = [[[ServerConfig sharedConfig].selected objectForKey:@"use_http"] boolValue] ? @"http": @"https";
    
    NSURL *logurl = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/log?id=%@",https, server_host, logFileId]];
    NSDictionary *logdic = @{
                              @"_id": logFileId,
                              @"user_id": _user_id,
                              @"created_at": @(startAt),
                              @"log": logContent
                              };
    
    NSData *logdata = [NSJSONSerialization dataWithJSONObject:logdic options:0 error:&error];
    
    NSURL *userurl = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/user?id=%@",https, server_host, _user_id]];
    NSData *userdata = [NSJSONSerialization dataWithJSONObject:info options:0 error:&error];
    
    [HLPDataUtil postRequest:logurl
                 contentType:@"application/json; charset=UTF-8"
                    withData:logdata
                    callback:^(NSData *response)
     {
         NSError *error;
         [NSJSONSerialization JSONObjectWithData:response options:0 error:&error];
         if (error) {
             NSString *res = [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding];
             NSLog(@"%@", res);
         } else {
             [HLPDataUtil postRequest:userurl
                          contentType:@"application/json; charset=UTF-8"
                             withData:userdata
                             callback:^(NSData *response)
              {
                  NSError *error;
                  [NSJSONSerialization JSONObjectWithData:response options:0 error:&error];
                  if (error) {
                      NSString *res = [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding];
                      NSLog(@"%@", res);
                  } else {
                      _userInfo = info;
                      complete();
                  }
             }];
         }
     }];
}

@end