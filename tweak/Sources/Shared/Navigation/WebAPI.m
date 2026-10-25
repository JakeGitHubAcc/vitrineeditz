#import "Shared/Lyrics/Lyrics.h"
#import "WebAPI.h"

static NSTimeInterval const kRequestTimeout = 8;

void SGWebAPI(NSString *method, NSString *path, void (^done)(NSInteger status, id answer)) {
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        NSString *bearer = headers[@"Authorization"] ?: headers[@"authorization"];
        if (!bearer.length) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(0, nil); });
            return;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"https://api.spotify.com/v1/" stringByAppendingString:path]]];
        request.HTTPMethod = method;
        request.timeoutInterval = kRequestTimeout;
        [request setValue:bearer forHTTPHeaderField:@"Authorization"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            id answer = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{ done(status, answer); });
        }] resume];
    });
}
