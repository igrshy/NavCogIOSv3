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

#import "POIManager.h"
#import "HLPDataUtil.h"
#import "NavDataStore.h"
#import "ServerConfig+FingerPrint.h"
#import <Mantle.h>

#define DIST 500

@implementation POIManager {
    HLPLocation *lastLocation;
    NSArray *cachedFeatures;
    NSMutableDictionary<NSString*, HLPNode*> *facilityNodeMap;
}

static POIManager *instance;

+(instancetype)sharedManager {
    if (!instance) {
        instance = [[POIManager alloc] init];
    }
    return instance;
}

- (NSArray*)filteredPOIsAt:(HLPLocation*)loc
{
    NSMutableArray *temp = [@[] mutableCopy];
    for(HLPObject* o in cachedFeatures) {
        if ([o isKindOfClass:HLPPOI.class]) {
            HLPPOI *poi = (HLPPOI*)o;
            if (isnan(loc.floor) || isnan(poi.height) || loc.floor == poi.height){
                [temp addObject:o];
            }
        }
        else if ([o isKindOfClass:HLPFacility.class]) {
            HLPFacility *f = (HLPFacility*)o;
            HLPNode *n = facilityNodeMap[f._id];
            if (isnan(loc.floor) ||
                (n && n.height == loc.floor) ||
                (!n && !isnan(f.height) && f.height == loc.floor)) {
                [temp addObject:o];
            }
        }
    }
    return temp;
}

- (void)initCenter:(HLPLocation*)loc
{
    NSLog(@"initCenter %@", loc);
    if (lastLocation && [loc distanceTo:lastLocation] < 200) {
        if (loc.floor != lastLocation.floor) {
            [_delegate manager:self didPOIsLoaded:[self filteredPOIsAt:loc]];
            lastLocation = loc;
        }
        return;
    }
    NavDataStore *nds = [NavDataStore sharedDataStore];
    [HLPDataUtil loadLandmarksAtLat:loc.lat Lng:loc.lng inDist:DIST forUser:nds.userID withLang:nds.userLanguage withCallback:^(NSArray<HLPObject *> *result) {
        [HLPDataUtil loadNodeMapForUser:nds.userID withLang:nds.userLanguage WithCallback:^(NSArray<HLPObject *> *result) {
            cachedFeatures = result;
            [self loadPOIs];
        }];
    }];
    lastLocation = loc;
}

- (void)loadPOIs
{
    NavDataStore *nds = [NavDataStore sharedDataStore];
    
    [_delegate didStartLoading];
    [HLPDataUtil loadFeaturesForUser:nds.userID withLang:nds.userLanguage WithCallback:^(NSArray<HLPObject *> *result) {
        cachedFeatures = [cachedFeatures arrayByAddingObjectsFromArray:result];
        facilityNodeMap = [@{} mutableCopy];
        NSMutableDictionary* nodeMap = [@{} mutableCopy];
        for(HLPObject* o in cachedFeatures) {
            if ([o isKindOfClass:HLPNode.class]) {
                nodeMap[o._id] = o;
            }
        }
        for(HLPObject* o in cachedFeatures) {
            if ([o isKindOfClass:HLPEntrance.class]) {
                HLPEntrance* e = (HLPEntrance*)o;
                facilityNodeMap[e.forFacilityID] = nodeMap[e.forNodeID];
            }
        }
        [_delegate manager:self didPOIsLoaded:[self filteredPOIsAt:lastLocation]];
    }];
}

- (BOOL)checkName:(NSObject*)obj
{
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dic = (NSDictionary*)obj;
        BOOL result = false;
        for(NSString *key in dic) {
            result = result || [self checkName:dic[key]];
        }
        return result;
    } else if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray*)obj;
        BOOL result = false;
        for(NSObject *o in arr) {
            result = result || [self checkName:o];
        }
        return result;
    } else if ([obj isKindOfClass:NSString.class]) {
        return [@"@name" isEqualToString:(NSString*)obj];
    }
    return NO;
}

- (NSObject*) substitute:(NSObject*)obj withOptions:(NSDictionary*)options
{
    if ([obj isKindOfClass:NSDictionary.class]) {
        NSDictionary *dic = (NSDictionary*)obj;
        NSMutableDictionary *temp = [@{} mutableCopy];
        for(NSString *key in dic) {
            if ([key isEqualToString:@"_title"]) continue;
            temp[key] = [self substitute:dic[key] withOptions:options];
        }
        return temp;
    } else if ([obj isKindOfClass:NSArray.class]) {
        NSArray *arr = (NSArray*)obj;
        NSMutableArray *temp = [@[] mutableCopy];
        for(NSObject *o in arr) {
            [temp addObject:[self substitute:o withOptions:options]];
        }
        return temp;
    } else if ([obj isKindOfClass:NSString.class]){
        if (options[obj]) {
            return options[obj];
        }
        return obj;
    }
    return obj;
}

- (NSURL*) urlForEditorAPI
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *server = [ud stringForKey:@"selected_hokoukukan_server"];
    NSString *context = [ud stringForKey:@"hokoukukan_server_context"];
    NSString *https = [ud boolForKey:@"https_connection"]?@"https":@"http";
    return [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@/%@api/editor", https, server, context]];
}

- (void)addPOI:(NSDictionary *)poi at:(HLPLocation*)location withOptions:(NSDictionary *)options
{
    if ([self checkName:poi] && !options[@"@name"]) {
        [_delegate manager:self requestInfo:@"@name" forPOI:poi at:location];
        return;
    }
    
    NSString* (^idgen)(NSDictionary*) = ^(NSDictionary* dic) {
        long t = [[NSDate date] timeIntervalSince1970] * 1000;
        return [NSString stringWithFormat:@"NavCogFP_poi_%ld", t];
    };
    NSString *genid = idgen(poi);
    int height = location.floor >= 0 ? location.floor+1 : location.floor;
    
    NSDictionary *temp = (NSDictionary*)[self substitute:poi withOptions:
                          [@{
                            @"@lat":@(location.lat),
                            @"@lng":@(location.lng),
                            @"@id":genid,
                            @"@toolname":@"NavCogFP",
                            @"@height":[@(height) stringValue]
                            } mtl_dictionaryByAddingEntriesFromDictionary:options]];
    NSLog(@"%@", temp);
    NSError *error;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[temp] options:0 error:&error];
    NSString *insert = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    [HLPDataUtil postRequest:[self urlForEditorAPI]
                    withData:@{
                               @"editor_api_key":[[ServerConfig sharedConfig] mapEditorKey],
                               @"user":[NavDataStore sharedDataStore].userID,
                               @"action":@"editdata",
                               @"insert":insert
                               }
                    callback:^(NSData *response) {
                        NSLog(@"%@", [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding]);
                        
                        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
                        NSDictionary *temp2 = [temp mtl_dictionaryByAddingEntriesFromDictionary:result[@"insert"][0]];
                        
                        NSError *error;
                        HLPObject *p = [MTLJSONAdapter modelOfClass:HLPObject.class fromJSONDictionary:temp2 error:&error];
                        if (error) {
                            NSLog(@"%@", error);
                            return;
                        }
                        cachedFeatures = [cachedFeatures arrayByAddingObjectsFromArray:@[p]];
                        [_delegate manager:self didPOIsLoaded:[self filteredPOIsAt:lastLocation]];
                    }];
}


- (void)removePOI:(HLPGeoJSONFeature *)poi
{
    if (![poi isKindOfClass:HLPObject.class]) {
        return;
    }
    HLPObject* obj = (HLPObject*)poi;
    
    NSError *error;
    NSDictionary *dict = [MTLJSONAdapter JSONDictionaryFromModel:poi error:&error];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[dict] options:0 error:&error];
    NSString *remove = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    
    [HLPDataUtil postRequest:[self urlForEditorAPI]
                    withData:@{
                               @"editor_api_key":[[ServerConfig sharedConfig] mapEditorKey],
                               @"user":[NavDataStore sharedDataStore].userID,
                               @"action":@"editdata",
                               @"remove":remove
                               }
                    callback:^(NSData *response) {
                        NSLog(@"%@", [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding]);
                        cachedFeatures = [cachedFeatures filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id _Nullable evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
                            if ([evaluatedObject isKindOfClass:HLPObject.class]) {
                                return ![((HLPObject*)evaluatedObject)._id isEqualToString:obj._id];
                            }
                            return YES;
                        }]];
                        [_delegate manager:self didPOIsLoaded:[self filteredPOIsAt:lastLocation]];
                    }];
}

@end
