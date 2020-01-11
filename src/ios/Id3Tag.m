//
//  Id3Tag.m
//  
//
//  Created by Leo Schubert on 11/21/17.
//  
//
//

@import Foundation;
@import UIKit;
@import AVFoundation;
@import AudioToolbox;
#import <assert.h>
#import <Cordova/CDVPlugin.h>

#define MYDEBUG(format, ...) \
  NSLog(@"<%s:%d> %s " format, \
  strrchr("/" __FILE__, '/') + 1, __LINE__, __PRETTY_FUNCTION__, ## __VA_ARGS__)

#define OBJCAST(CNAME,oo) \
({ id o=(oo);((o)==nil)?nil: \
([(o) isKindOfClass:CNAME.class]?((CNAME*)(o)):\
(CNAME*)my_internal_assert("OBJCAST failed:no object of " #CNAME ,strrchr("/" __FILE__, '/') + 1,__PRETTY_FUNCTION__,__LINE__));})

static NSObject* my_internal_assert(const char* msg,const char* file,const char* function,int line)
{
  NSLog(@"Assertion failed:%s,file:%s,func:%s,line:%d",msg,file,function,line);
  return nil;
}

static NSDictionary* errDict(NSString* err)
{
  return @{ @"error" : err };
}

#define CHK_DICTERR0(afd,a) if((a)) {AudioFileClose(afd);return errDict([NSString stringWithUTF8String:#a]);}
#define CHK_DICTERR(a,b) if((a)) {return errDict(b);}
static NSDictionary* getID3DictForURL(NSURL* url)
{
  AudioFileID     afd = nil;
  OSStatus        err = AudioFileOpenURL((__bridge CFURLRef) url, kAudioFileReadPermission, 0, &afd);
  CHK_DICTERR(err != noErr, @"AudioFileOpenURL failed");
  UInt32          size = 0;
  
  err = AudioFileGetPropertyInfo(afd, kAudioFilePropertyID3Tag, &size, NULL);
  CHK_DICTERR(err != noErr, @"AudioFileGetPropertyInfo failed");
  char           *tag = (char *)malloc(size);
  CHK_DICTERR(tag == NULL, @"malloc tag failed");
  err = AudioFileGetProperty(afd, kAudioFilePropertyID3Tag, &size, tag);
  CHK_DICTERR(err != noErr, @"AudioFileGetProperty ID3Tag failed");
  UInt32          tagsize = 0;
  UInt32          len = 0;
  err = AudioFormatGetProperty(kAudioFormatProperty_ID3TagSize, size, tag, &len, &tagsize);
  if (err != noErr) {
    CHK_DICTERR0(afd,err == kAudioFormatUnspecifiedError);
    CHK_DICTERR0(afd,err == kAudioFormatUnsupportedPropertyError);
    CHK_DICTERR0(afd,err == kAudioFormatBadPropertySizeError);
    CHK_DICTERR0(afd,err == kAudioFormatBadSpecifierSizeError);
    CHK_DICTERR0(afd,err == kAudioFormatUnsupportedDataFormatError);
    CHK_DICTERR0(afd,err == kAudioFormatUnknownFormatError);
    AudioFileClose(afd);
    return errDict(@"other audio format error");
  }
  CFDictionaryRef propDict = nil;
  UInt32          propSize = sizeof(propDict);
  err = AudioFileGetProperty(afd, kAudioFilePropertyInfoDictionary, &propSize, &propDict);
  CHK_DICTERR(err != noErr, @"AudioFileGetProperty dictionary failed");
  free(tag);
  AudioFileClose(afd);
  return (__bridge NSDictionary *) propDict;
}

@interface Id3Tag: CDVPlugin
{
  NSString* _callbackId;
}
@property (readonly,getter=getCallbackId) NSString* callbackId;
@end
@implementation Id3Tag;

- (void) getInfo: (CDVInvokedUrlCommand *) command {
  NSString * filePath = [command argumentAtIndex:0];
  NSURL* fileURL= [NSURL fileURLWithPath:filePath];
  NSDictionary * info = getID3DictForURL(fileURL);
  CDVCommandStatus status=(info[@"error"]!=nil)?CDVCommandStatus_ERROR:CDVCommandStatus_OK;
  CDVPluginResult * pluginResult = [CDVPluginResult resultWithStatus:status messageAsDictionary:info];
  [self.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
}

-(void)albumArtForURL:(NSURL*)url
{
  AVAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  if (asset == nil) {
    CDVCommandStatus err=CDVCommandStatus_ERROR;
    CDVPluginResult * pluginResult = [CDVPluginResult resultWithStatus:err messageAsString:[NSString stringWithFormat:@"No AVURLAsset for url:%@",url]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    return;
  }
  Id3Tag* __weak weakSelf=self;
  [asset loadValuesAsynchronouslyForKeys:@[@"commonMetadata"] completionHandler:^{
    NSArray *artworks = [AVMetadataItem metadataItemsFromArray:asset.commonMetadata
                                                       withKey:AVMetadataCommonKeyArtwork
                                                      keySpace:AVMetadataKeySpaceCommon];
    
    
    UIImage *albumImg=nil;
    for (AVMetadataItem *item in artworks) {
      NSString* kSpace=item.keySpace;
      if ([kSpace isEqualToString:AVMetadataKeySpaceID3]||
          [kSpace isEqualToString:AVMetadataKeySpaceiTunes]) {
        NSData* data=OBJCAST(NSData,item.value);
        albumImg = [UIImage imageWithData:data];
        break;
      }
    }
    [weakSelf returnAlbumImg:albumImg];
  }];
}

- (void) getMetaData: (CDVInvokedUrlCommand *) command 
{
  NSString * filePath = [command argumentAtIndex:0];
  NSURL* fileURL= [NSURL fileURLWithPath:filePath];
  _callbackId=command.callbackId;
  [self metaDataForURL:fileURL];
}

-(void)metaDataForURL:(NSURL*)url
{

  AVAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
  if (asset == nil) {
    CDVCommandStatus err=CDVCommandStatus_ERROR;
    CDVPluginResult * pluginResult = [CDVPluginResult resultWithStatus:err messageAsString:[NSString stringWithFormat:@"No AVURLAsset for url:%@",url]];
    [self.commandDelegate sendPluginResult:pluginResult callbackId:self.callbackId];
    return;
  }
  Id3Tag* __weak weakSelf=self;
  [asset loadValuesAsynchronouslyForKeys:@[@"commonMetadata",@"metadata"] completionHandler:^{
    [weakSelf handleAsset:asset];
   
  }];
}

-(void)checkKeys:(NSDictionary*)keys forArray:(NSMutableArray*)meta keySpace:(NSString*)keySpace result:(NSMutableDictionary*)result
{
  for(NSObject* o in keys.allKeys) {
    if ([o isKindOfClass:NSString.class]) {
      NSArray* arr=[AVMetadataItem metadataItemsFromArray:meta withKey:o keySpace:keySpace];
      for (AVMetadataItem* item in arr) {
        if (![item.value isKindOfClass:NSData.class]) {
          NSString* key=keys[o];
          result[key]=item.value;
          [meta removeObject:item];
          break;
        }
      }
    }
  }
}
                    
-(void)handleAsset:(AVAsset*)asset
{
#define MYCOMKEY(s,v)    AVMetadataCommonKey##s:v
#define MYITUNESKEY(s,v) AVMetadataiTunesMetadataKey##s:v
#define MYQTKEY(s,v)     AVMetadataQuickTimeUserDataKey##s:v
#define MYID3KEY(s,v)    AVMetadataID3MetadataKey##s:v
#define MYINTKEY(s,v)    @(s):v
  NSDictionary   *comkeys = @{
                              MYCOMKEY(Title,@"title"),
                              MYCOMKEY(Creator,@"creator"),
                              MYCOMKEY(Subject,@"subject"),
                              MYCOMKEY(Artist,@"artist"),
                              MYCOMKEY(AlbumName,@"albumTitle"),
                              MYCOMKEY(Author,@"author"),
                              MYCOMKEY(Copyrights,@"copyright")
                              };
  NSDictionary   *qtkeys = @{
                             MYQTKEY(Album,@"albumTitle"),
                             MYQTKEY(Artist,@"artist"),
                             MYQTKEY(Author,@"author"),
                             MYQTKEY(Composer,@"composer")
                             };
  NSDictionary   *itkeys = @{
                             MYITUNESKEY(Album,@"albumTitle"),
                             MYITUNESKEY(Artist,@"artist"),
                             MYITUNESKEY(UserComment,@"comment"),
                             MYITUNESKEY(CoverArt,@"coverArt"),
                             MYITUNESKEY(Copyright,@"copyright"),
                             MYITUNESKEY(ReleaseDate,@"releaseDate"),
                             MYITUNESKEY(EncodedBy,@"encodedBy"),
                             MYITUNESKEY(PredefinedGenre,@"genre"),
                             MYITUNESKEY(UserGenre,@"userGenre"),
                             MYITUNESKEY(SongName,@"title"),
                             MYINTKEY(-1452383891,@"title"),
                             MYITUNESKEY(TrackSubTitle,@"trackSubTitle"),
                             MYITUNESKEY(EncodingTool,@"encodedWith"),
                             MYITUNESKEY(Composer,@"composer"),
                             MYITUNESKEY(AlbumArtist,@"albumArtist"),
                             MYITUNESKEY(AccountKind,@"accountKind"),
                             MYITUNESKEY(AppleID,@"appleID"),
                             MYITUNESKEY(ArtistID,@"artistID"),
                             MYITUNESKEY(SongID,@"songID"),
                             MYITUNESKEY(DiscCompilation,@"discCompilation"),
                             MYITUNESKEY(DiscNumber,@"discNumber"),
                             MYITUNESKEY(GenreID,@"genreID"),
                             MYITUNESKEY(Grouping,@"grouping"),
                             MYITUNESKEY(PlaylistID,@"playlistID"),
                             MYITUNESKEY(ContentRating,@"contentRating"),
                             MYITUNESKEY(BeatsPerMin,@"bpm"),
                             MYITUNESKEY(TrackNumber,@"trackNumber"),
                             MYITUNESKEY(ArtDirector,@"artDirector"),
                             MYITUNESKEY(Arranger,@"arranger"),
                             MYITUNESKEY(Author,@"author"),
                             MYITUNESKEY(Lyrics,@"lyrics"),
                             MYITUNESKEY(Acknowledgement,@"acknowledgement"),
                             MYITUNESKEY(Conductor,@"conductor"),
                             MYITUNESKEY(Description,@"description"),
                             MYITUNESKEY(Director,@"director"),
                             MYITUNESKEY(EQ,@"eq"),
                             MYITUNESKEY(LinerNotes,@"linerNotes"),
                             MYITUNESKEY(RecordCompany,@"recordCompany"),
                             MYITUNESKEY(OriginalArtist,@"originalArtist"),
                             MYITUNESKEY(PhonogramRights,@"rights"),
                             MYITUNESKEY(Producer,@"producer"),
                             MYITUNESKEY(Performer,@"performer"),
                             MYITUNESKEY(Publisher,@"publisher"),
                             MYITUNESKEY(SoundEngineer,@"soundEngineer"),
                             MYITUNESKEY(Soloist,@"soloist"),
                             MYITUNESKEY(Credits,@"credits"),
                             MYITUNESKEY(Thanks,@"thanks"),
                             MYITUNESKEY(OnlineExtras,@"onlineExtras"),
                             MYITUNESKEY(ExecProducer,@"execProducer"),
                             MYINTKEY(1668313716,@"copyright")
                             };
  NSDictionary   *id3keys = @{
                             MYID3KEY(Composer,@"composer"),
                             MYID3KEY(Copyright,@"copyright"),
                             MYID3KEY(Time,@"time"),
                             MYID3KEY(Year,@"year"),
                             MYID3KEY(TrackNumber,@"track"),
                             MYID3KEY(OriginalArtist,@"artist"),
                             MYID3KEY(TitleDescription,@"title"),
                             MYID3KEY(BeatsPerMinute,@"bpm"),
                             MYID3KEY(LeadPerformer,@"leadPerformer"),
                             MYID3KEY(Band,@"band"),
                             MYID3KEY(ContentType,@"genre"),
                             MYID3KEY(RecordingTime,@"duration"),
                             MYID3KEY(EncodedBy,@"encodedBy"),
                             MYID3KEY(EncodedWith,@"encodedWith"),
                             MYID3KEY(Comments,@"comments"),
                             MYID3KEY(PartOfASet,@"partOfASet"),
                             MYID3KEY(AlbumTitle,@"albumTitle"),
                             MYID3KEY(OriginalAlbumTitle,@"originalAlbumTitle"),
                             MYID3KEY(Conductor,@"conductor"),
                             MYID3KEY(UserURL,@"url")
                             };
  NSMutableDictionary* mykeys=[NSMutableDictionary dictionary];
  NSMutableDictionary* dict=[NSMutableDictionary dictionary];
  NSMutableArray *meta = [NSMutableArray arrayWithArray:asset.commonMetadata];
  [self checkKeys:comkeys forArray:meta keySpace:AVMetadataKeySpaceCommon result:dict];
  meta=[NSMutableArray arrayWithArray:asset.metadata];
  [self checkKeys:qtkeys forArray:meta keySpace:AVMetadataKeySpaceQuickTimeUserData result:dict];
  [self checkKeys:itkeys forArray:meta keySpace:AVMetadataKeySpaceiTunes result:dict];
  [self checkKeys:id3keys forArray:meta keySpace:AVMetadataKeySpaceID3 result:dict];
  //[meta addObjectsFromArray:asset.metadata];
  for (AVMetadataItem *item in meta) {
    id keyID=item.commonKey!=nil?item.commonKey:item.key;
    NSObject* val=item.value;
    if (![val isKindOfClass:NSData.class]) {
      NSString* keyTrans=mykeys[keyID];
      if (keyTrans!=nil || [keyID isKindOfClass:NSString.class]) {
        NSString* key=(NSString*)keyID;
        dict[keyTrans!=nil?keyTrans:key]=item.value;
      } else {
        NSLog(@"No string:%@",keyID);
        NSString* key=[NSString stringWithFormat:@"%@",keyID];
        if (item.identifier!=nil) {
          key=item.identifier;
        }
        dict[key]=val;
      }
    }
  }
  [self returnDict:dict];
}

- (void)returnDict:(NSDictionary*)dict
{
  CDVCommandStatus status = CDVCommandStatus_OK;
  CDVPluginResult* pluginResult = [CDVPluginResult resultWithStatus:status messageAsDictionary:dict];
  [self.commandDelegate sendPluginResult: pluginResult callbackId:self.callbackId];
}

- (NSString*)getCallbackId
{
  NSString* cb=_callbackId;
  _callbackId=nil;
  return cb;
}

- (void)returnAlbumImg:(UIImage*)albumImg
{
  static int albumArtNo = 0;
  NSString *artFile = nil;
  CDVCommandStatus status = CDVCommandStatus_OK;
  if (albumImg != nil) {
    artFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"albumArt:%d.jpg", albumArtNo++]];
    [UIImageJPEGRepresentation(albumImg, 1.0) writeToFile:artFile atomically:YES];
  } else {
    status = CDVCommandStatus_ERROR;
    artFile = @"No album image found";
  }
  CDVPluginResult *pluginResult =[CDVPluginResult resultWithStatus:status messageAsString:artFile];
  [self.commandDelegate sendPluginResult: pluginResult callbackId:self.callbackId];
}

- (void) getAlbumArt: (CDVInvokedUrlCommand *) command 
{
  NSString * filePath = [command argumentAtIndex:0];
  NSURL* fileURL= [NSURL fileURLWithPath:filePath];
  _callbackId=command.callbackId;
  [self albumArtForURL:fileURL];
}

/*
- (AVMutableMetaDataItem*)itemForItunesKey:(NSString*)key value:(NSObject*)value
{
  AVMutableMetaDataItem* item=[AVMutableMetaDataItem metadataItem];
  item.key=key;
  item.keySpace=AVMetadataKeySpaceiTunes;
  item.value=value;
}

- (void) exportData: (CDVInvokedUrlCommand *) command
{
  NSURL* songURL= [NSURL fileURLWithPath:filePath];
  AVURLAsset *songURL = [AVURLAsset URLAssetWithURL:songurl options:nil];
  NSMutableArray* meta=[NSMutableArray array];
  [meta addObject:[self itemForItunesKey:AVMetadataiTunesMetadataKeyArtist value:@"MyArtist"]];


  AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:songURL presetName:AVAssetExportPresetAppleM4A];

  exporter.outputFileType = @"com.apple.m4a-audio";
  NSURL *exportURL = [NSURL fileURLWithPath:outputfile];
  exporter.outputURL  = exportURL;
  [exporter exportAsynchronouslyWithCompletionHandler:^{
     CDVPluginResult* result = nil;
     switch (exportStatus) {
         case AVAssetExportSessionStatusFailed:{
            NSError *exportError = exporter.error;
            NSLog(@"AVAssetExportSessionStatusFailed = %@",exportError);
            NSString *errmsg = [exportError description];
            result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:errmsg];
            break;
         }
         case AVAssetExportSessionStatusCompleted:{
              NSURL *audioURL = exportURL;
              result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsString:@"ok"];
              break;
         }
         case AVAssetExportSessionStatusCancelled:{
              NSLog(@"AVAssetExportSessionStatusCancelled");
              result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Cancelled"];
              break;
         }
         case AVAssetExportSessionStatusUnknown:{
              NSLog(@"AVAssetExportSessionStatusCancelled");
              result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Unknown"];
              break;
         }
         case AVAssetExportSessionStatusWaiting:{
              NSLog(@"AVAssetExportSessionStatusWaiting");
              result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Waiting"];
              break;
         }
         case AVAssetExportSessionStatusExporting:{
              NSLog(@"AVAssetExportSessionStatusExporting");
              result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Exporting"];
              break;
         }
         default:{
              NSLog(@"Didnt get any status");
              break;
         }
      }
    }];
*/
@end
