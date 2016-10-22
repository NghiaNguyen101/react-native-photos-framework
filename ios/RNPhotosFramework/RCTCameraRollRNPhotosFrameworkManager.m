#import "RCTCameraRollRNPhotosFrameworkManager.h"
#import "RCTUtils.h"
#import "PHCachingImageManagerInstance.h"
#import "RCTConvert.h"
#import "RCTImageLoader.h"
#import "RCTLog.h"
#import "RCTUtils.h"
#import "RCTConvert+RNPhotosFramework.h"
@import Photos;

@implementation RCTCameraRollRNPhotosFrameworkManager
RCT_EXPORT_MODULE()

@synthesize bridge = _bridge;
NSString *const RNPHotoFrameworkErrorUnableToLoad = @"RNPHOTOSFRAMEWORK_UNABLE_TO_LOAD";
NSString *const RNPHotoFrameworkErrorUnableToSave = @"RNPHOTOSFRAMEWORK_UNABLE_TO_SAVE";

static id ObjectOrNull(id object)
{
    return object ?: [NSNull null];
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_queue_create("com.facebook.React.ReactNaticePhotosFramework", DISPATCH_QUEUE_SERIAL);
}

RCT_EXPORT_METHOD(createCollection:(NSString *)collectionName
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    if(collectionName == nil) {
        reject(@"collection name cannot be null", nil, nil);
    }
    [self createAlbumWithTitle:collectionName andCompleteBLock:^(BOOL success, NSError * _Nullable error, NSString * _Nullable localIdentifier) {
        if(success) {
            resolve(@{
                      @"localIdentifier" : localIdentifier
                    });
        }else{
            reject([NSString stringWithFormat:@"Error creating album named %@", collectionName], nil, error);
        }
    }];

}

RCT_EXPORT_METHOD(getPhotos:(NSDictionary *)params
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    NSString * cacheKey = [RCTConvert NSString:params[@"_cacheKey"]];
    NSString * collectionLocalIdentifier = [RCTConvert NSString:params[@"collectionLocalIdentifier"]];

    NSUInteger startIndex = [RCTConvert NSInteger:params[@"startIndex"]];
    NSUInteger endIndex = [RCTConvert NSInteger:params[@"endIndex"]];
    CGSize prepareForSizeDisplay = [RCTConvert CGSize:params[@"prepareForSizeDisplay"]];
    CGFloat prepareScale = [RCTConvert CGFloat:params[@"prepareScale"]];
    
    PHFetchResult<PHAsset *> *assetsFetchResult = [self getAssetsForParams:params andCacheKey:cacheKey andCollectionLocalIdentifier:collectionLocalIdentifier];
    
    NSArray<PHAsset *> *assets = [self getAssetsForFetchResult:assetsFetchResult startIndex:startIndex endIndex:endIndex];
    
    PHCachingImageManager *cacheManager = [PHCachingImageManagerInstance sharedCachingManager];
    
    if(prepareForSizeDisplay.width != 0 && prepareForSizeDisplay.height != 0) {
        if(prepareScale < 0.1) {
            prepareScale = 2;
        }
        [cacheManager startCachingImagesForAssets:assets targetSize:CGSizeApplyAffineTransform(prepareForSizeDisplay, CGAffineTransformMakeScale(prepareScale, prepareScale)) contentMode:PHImageContentModeAspectFill options:nil];
    }
    
    resolve([self assetsArrayToUriArray:assets]);
}


-(PHFetchResult<PHAsset *> *) getAssetsForParams:(NSDictionary *)params andCacheKey:(NSString *)cacheKey andCollectionLocalIdentifier:(NSString *)collectionLocalIdentifier   {
    if(collectionLocalIdentifier == nil){
        return [self getAssetsForParams:params andCacheKey:cacheKey];
    }
    PHFetchOptions *options = [self getFetchOptionsFromParams:[RCTConvert NSDictionary:params[@"fetchOptions"]]];
    PHAssetCollection *collection = [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[collectionLocalIdentifier] options:nil].firstObject;
    return [PHAsset fetchAssetsInAssetCollection:collection options:options];
}

-(PHFetchResult<PHAsset *> *) getAssetsForParams:(NSDictionary *)params andCacheKey:(NSString *)cacheKey  {
    if(cacheKey == nil) {
        return [self getAssetsForParams:params];
    }
    return [RCTCameraRollRNPhotosFrameworkManager getFetchResultFromCacheWithuuid:cacheKey];
}

-(PHFetchResult<PHAsset *> *) getAssetsForParams:(NSDictionary *)params {
    PHFetchOptions *options = [self getFetchOptionsFromParams:[RCTConvert NSDictionary:params[@"fetchOptions"]]];
    return [PHAsset fetchAssetsWithOptions:options];
}

RCT_EXPORT_METHOD(getCollections:(NSDictionary *)params
                  resolve:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    
    NSMutableArray *responseArray = [NSMutableArray new];
    NSArray *multipleAlbumsQuery = [RCTConvert NSArray:params[@"albums"]];
    for(int i = 0; i < multipleAlbumsQuery.count;i++) {
        NSDictionary *albumsQuery = [multipleAlbumsQuery objectAtIndex:i];
        PHFetchResult<PHAssetCollection *> *albums = [self getAlbumsWithParams:albumsQuery];
        BOOL cacheAssets = [RCTConvert BOOL:albumsQuery[@"prepareForEnumeration"]];
        NSMutableDictionary *multipleAlbumsResponse = [self generateAlbumsResponseFromParams:albumsQuery andAlbums:albums andCacheAssets:cacheAssets];
        if(cacheAssets) {
            NSString *uuid = [RCTCameraRollRNPhotosFrameworkManager cacheFetchResultAndReturnUUID:albums];
            [multipleAlbumsResponse setObject:uuid forKey:@"_cacheKey"];
        }
        [responseArray addObject:multipleAlbumsResponse];
    }
    resolve(responseArray);
}



-(NSMutableDictionary *)generateAlbumsResponseFromParams:(NSDictionary *)params andAlbums:(PHFetchResult<PHAssetCollection *> *)albums andCacheAssets:(BOOL)cacheAssets {
    
    NSMutableDictionary *collectionDictionary = [NSMutableDictionary new];
    NSString * typeString = params[@"type"];
    NSString * subTypeString = params[@"subType"];
    
    if(typeString != nil && subTypeString != nil) {
        if(typeString == nil) {
            typeString = @"album";
        }
        if(subTypeString == nil) {
            subTypeString = @"any";
        }
        [collectionDictionary setObject:typeString forKey:@"type"];
        [collectionDictionary setObject:subTypeString forKey:@"subType"];
    }

    RNPFAssetCountType countType = [RCTConvert RNPFAssetCountType:params[@"assetCount"]];
    NSMutableArray *albumsArray = [NSMutableArray arrayWithCapacity:albums.count];
    
    for(PHCollection *collection in albums)
    {
        if ([collection isKindOfClass:[PHAssetCollection class]])
        {
            PHAssetCollection *phAssetCollection = (PHAssetCollection *)collection;
            NSMutableDictionary *albumDictionary = [NSMutableDictionary new];
            NSString * typeString = params[@"type"];
            NSString * subTypeString = params[@"subType"];
            
            [albumDictionary setObject:phAssetCollection.localizedTitle forKey:@"title"];
            [albumDictionary setObject:phAssetCollection.localIdentifier forKey:@"localIdentifier"];
            [albumDictionary setObject:ObjectOrNull(phAssetCollection.startDate) forKey:@"startDate"];
            [albumDictionary setObject:ObjectOrNull(phAssetCollection.endDate) forKey:@"endDate"];
            [albumDictionary setObject:ObjectOrNull(phAssetCollection.approximateLocation) forKey:@"approximateLocation"];
            [albumDictionary setObject:ObjectOrNull(phAssetCollection.localizedLocationNames) forKey:@"localizedLocationNames"];

            if(cacheAssets || countType == RNPFAssetCountTypeExact) {
                PHFetchResult<PHAsset *> * assets = [self getAssetForCollection:collection andFetchParams:params];
                [albumDictionary setObject:@(assets.count) forKey:@"assetCount"];
                if(cacheAssets) {
                   NSString *uuid = [RCTCameraRollRNPhotosFrameworkManager cacheFetchResultAndReturnUUID:assets];
                   [albumDictionary setObject:uuid forKey:@"_cacheKey"];
                }
                
            }else if(countType == RNPFAssetCountTypeEstimated) {
                [albumDictionary setObject:@([phAssetCollection estimatedAssetCount]) forKey:@"assetCount"];
            }
            
            [albumsArray addObject:albumDictionary];
        }
    }
    [collectionDictionary setObject:albumsArray forKey:@"albums"];
    return collectionDictionary;
}

-(PHFetchResult<PHAsset *> *) getAssetForCollection:(PHAssetCollection *)collection andFetchParams:(NSDictionary *)params {
    NSDictionary *fetchOptions = [RCTConvert NSDictionary:params[@"fetchOptions"]];
    PHFetchOptions *options = [self getFetchOptionsFromParams:fetchOptions];
    return  [PHAsset fetchAssetsInAssetCollection:collection options:options];
}

-(PHFetchOptions *)getFetchOptionsFromParams:(NSDictionary *)params {
    if(params == nil) {
        return nil;
    }
    PHFetchOptions *options = [[PHFetchOptions alloc] init];
    options.includeAssetSourceTypes = [RCTConvert PHAssetSourceTypes:params[@"sourceTypes"]];
    options.includeHiddenAssets = [RCTConvert BOOL:params[@"includeHiddenAssets"]];
    options.includeAllBurstAssets = [RCTConvert BOOL:params[@"includeAllBurstAssets"]];
    options.fetchLimit = [RCTConvert int:params[@"fetchLimit"]];
    options.wantsIncrementalChangeDetails = [RCTConvert BOOL:params[@"wantsIncrementalChangeDetails"]];
    options.predicate = [self getPredicate:params];
    
    BOOL sortAscending = [RCTConvert BOOL:params[@"sortAscending"]];
    NSString *sortDescriptorKey = [RCTConvert NSString:params[@"sortDescriptorKey"]];
    if(sortDescriptorKey != nil) {
        options.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:sortDescriptorKey ascending:sortAscending]];
    }
    return options;
}

-(NSPredicate *) getPredicate:(NSDictionary *)params  {
    NSPredicate *mediaTypePredicate = [self getMediaTypePredicate:params];
    
    NSPredicate *subTypePredicate = [self getMediaSubTypePredicate:params];
    if(mediaTypePredicate && subTypePredicate) {
        return [NSCompoundPredicate andPredicateWithSubpredicates:@[mediaTypePredicate, subTypePredicate]];
    }
    return mediaTypePredicate != nil ? mediaTypePredicate : subTypePredicate;
}

-(NSPredicate *) getMediaTypePredicate:(NSDictionary *)params {
    NSMutableArray * mediaTypes = [RCTConvert PHAssetMediaTypes:params[@"mediaTypes"]];
    if(mediaTypes == nil) {
        return nil;
    }
    return [NSPredicate predicateWithFormat:@"mediaType in %@", mediaTypes];
}

-(NSPredicate *) getMediaSubTypePredicate:(NSDictionary *)params {
    NSMutableArray * mediaSubTypes = [RCTConvert PHAssetMediaSubtypes:params[@"mediaSubTypes"]];
    if(mediaSubTypes == nil) {
        return nil;
    }
    NSMutableArray *arrayWithPredicates = [NSMutableArray arrayWithCapacity:mediaSubTypes.count];

    for(int i = 0; i < mediaSubTypes.count;i++) {
        PHAssetMediaSubtype mediaSubType = [[mediaSubTypes objectAtIndex:i] intValue];
        [arrayWithPredicates addObject:[NSPredicate predicateWithFormat:@"((mediaSubtype & %d) == %d)", mediaSubType, mediaSubType]];
    }
    
    return [NSCompoundPredicate orPredicateWithSubpredicates:arrayWithPredicates];
}

-(NSMutableArray<PHAsset *> *) getAssetsForFetchResult:(PHFetchResult *)assetsFetchResult startIndex:(NSUInteger)startIndex endIndex:(NSUInteger)endIndex {
  
  NSMutableArray<PHAsset *> *assets = [NSMutableArray new];
  [assetsFetchResult enumerateObjectsUsingBlock:^(PHAsset *asset, NSUInteger index, BOOL *stop) {
    if(index >= startIndex){
      [assets addObject:asset];
    }
    if(index >= endIndex){
      *stop = YES;
    }
  }];
  return assets;
}

-(NSArray<NSDictionary *> *) assetsArrayToUriArray:(NSArray<PHAsset *> *)assetsArray {
  NSMutableArray *uriArray = [NSMutableArray arrayWithCapacity:assetsArray.count];
  for(int i = 0;i < assetsArray.count;i++) {
    PHAsset *asset =[assetsArray objectAtIndex:i];
    [uriArray addObject:@{
                          @"uri" : [asset localIdentifier],
                          @"width" : @([asset pixelWidth]),
                          @"height" : @([asset pixelHeight])
                          }];
  }
  return uriArray;
}

-(PHFetchResult<PHAssetCollection *> *)getAlbumsWithParams:(NSDictionary *)params {
    NSString * typeString = params[@"type"];
    NSString * subTypeString = params[@"subType"];
    if(typeString == nil && subTypeString == nil) {
        return [self getTopUserAlbums:params];
    }
    PHAssetCollectionType type = [RCTConvert PHAssetCollectionType:typeString];
    PHAssetCollectionSubtype subType = [RCTConvert PHAssetCollectionSubtype:subTypeString];
    NSDictionary *fetchOptions = [RCTConvert NSDictionary:params[@"fetchOptions"]];
    PHFetchOptions *options = [self getFetchOptionsFromParams:params];
    PHFetchResult<PHAssetCollection *> *albums = [PHAssetCollection fetchAssetCollectionsWithType:type subtype:subType options:options];
    return albums;
}

-(PHFetchResult<PHAssetCollection *> *)getTopUserAlbums:(NSDictionary *)params
{
    PHFetchOptions *options = [self getFetchOptionsFromParams:params];
    PHFetchResult<PHAssetCollection *> *topLevelUserCollections = [PHCollectionList fetchTopLevelUserCollectionsWithOptions:options];
    return topLevelUserCollections;
}

+(NSString *) cacheFetchResultAndReturnUUID:(PHFetchResult *)fetchResult{
    NSString *uuid = [[NSUUID UUID] UUIDString];
    NSMutableDictionary<NSString *, PHFetchResult *> *previousFetchResults = [RCTCameraRollRNPhotosFrameworkManager previousFetches];
    [previousFetchResults setObject:fetchResult forKey:uuid];
    return uuid;
}

+(PHFetchResult *) getFetchResultFromCacheWithuuid:(NSString *)uuid {
    NSMutableDictionary<NSString *, PHFetchResult *> *previousFetchResults = [RCTCameraRollRNPhotosFrameworkManager previousFetches];
    return [previousFetchResults objectForKey:uuid];
}

+(NSMutableDictionary<NSString *, PHFetchResult *> *) previousFetches {
    static NSMutableDictionary<NSString *, PHFetchResult *> *fetchResults;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fetchResults = [[NSMutableDictionary alloc] init];
    });
    return fetchResults;
}



//CREATE ALBUM:

-(void)saveImage:(NSURLRequest *)request
            type:(NSString *)type
            toCollection:(PHFetchResult<PHAssetCollection *> *)collection
         resolve:(RCTPromiseResolveBlock)resolve
          reject:(RCTPromiseRejectBlock)reject{
    if ([type isEqualToString:@"video"]) {
        // It's unclear if thread-safe
        dispatch_async(dispatch_get_main_queue(), ^{
        
        });
    } else {
        [_bridge.imageLoader loadImageWithURLRequest:request
                                            callback:^(NSError *loadError, UIImage *loadedImage) {
                                                if (loadError) {
                                                    reject(RNPHotoFrameworkErrorUnableToLoad, nil, loadError);
                                                    return;
                                                }
                                                // It's unclear if writeImageToSavedPhotosAlbum is thread-safe
                                                dispatch_async(dispatch_get_main_queue(), ^{
                                                    
                                                
                                                });
                                            }];
    }
}

-(PHFetchResult<PHAssetCollection *> *)getAlbumTiteled:(NSString *)title {
    PHFetchOptions *fetchOptions = [[PHFetchOptions alloc] init];
    fetchOptions.predicate = [NSPredicate predicateWithFormat:@"title = %@", title];
    PHAssetCollection *collection = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
                                                          subtype:PHAssetCollectionSubtypeAny
                                                          options:fetchOptions].firstObject;
    return collection;
}

-(void) createAlbumWithTitle:(NSString *)title andCompleteBLock:(nullable void(^)(BOOL success, NSError *__nullable error, NSString *__nullable localIdentifier))completeBlock {
    __block PHObjectPlaceholder *placeholder;

    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        
        PHAssetCollectionChangeRequest *createAlbum = [PHAssetCollectionChangeRequest creationRequestForAssetCollectionWithTitle:title];
        placeholder = [createAlbum placeholderForCreatedAssetCollection];
        
    } completionHandler:^(BOOL success, NSError *error) {
        PHAssetCollection *collection;
        if (success)
        {
            PHFetchResult *collectionFetchResult = [PHAssetCollection fetchAssetCollectionsWithLocalIdentifiers:@[placeholder.localIdentifier] options:nil];
            collection = collectionFetchResult.firstObject;
        }
        completeBlock(success, error, collection.localIdentifier);
    }];
}

- (void) saveImage:(UIImage *)image toAlbum:(PHCollection *)album andCompleteBLock:(nullable void(^)(BOOL success, NSError *__nullable error, NSString *__nullable localIdentifier))completeBlock {
    __block PHObjectPlaceholder *placeholder;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHFetchResult *photosAsset;
        PHAssetChangeRequest *assetRequest = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        placeholder = [assetRequest placeholderForCreatedAsset];
        photosAsset = [PHAsset fetchAssetsInAssetCollection:album options:nil];
        PHAssetCollectionChangeRequest *albumChangeRequest = [PHAssetCollectionChangeRequest changeRequestForAssetCollection:album assets:photosAsset];
        [albumChangeRequest addAssets:@[placeholder]];
        
    } completionHandler:^(BOOL success, NSError *error) {
        completeBlock(success, error, placeholder.localIdentifier);
    }];
}

@end
