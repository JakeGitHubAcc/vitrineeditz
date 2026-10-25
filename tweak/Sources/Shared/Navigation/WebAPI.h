// Spotify's Web API (api.spotify.com/v1), asked as the signed-in app with its own bearer token
// (SGSpclientHeaders, Shared/Lyrics/Lyrics.h): the local files' artist sheet and the Records page.
#import <Foundation/Foundation.h>

// `path` is under /v1/, query and all. `done` on main with the HTTP status and the JSON answer (nil for
// none); the status is 0 when the app's token is not known yet or the request never reached the server.
void SGWebAPI(NSString *method, NSString *path, void (^done)(NSInteger status, id answer));
