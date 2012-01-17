#import "BeanstalkAccount.h"

@implementation BeanstalkAccount

+ (void)load { [Account registerClass:self]; }
+ (BOOL)requiresDomain { return YES; }
+ (NSString *)domainSuffix { return @".beanstalkapp.com"; }
+ (BOOL)requiresUsername { return YES; }
+ (BOOL)requiresPassword { return YES; }

- (void)validateWithPassword:(NSString *)password {
    
    NSString *URL = [NSString stringWithFormat:@"https://%@.beanstalkapp.com/api/users/current.json", domain];
    
    NSMutableURLRequest *URLRequest = [NSMutableURLRequest requestWithURLString:URL username:username password:password];
    URLRequest.HTTPShouldHandleCookies = NO;
    
    self.request = [SMWebRequest requestWithURLRequest:URLRequest delegate:self context:NULL];
    [request addTarget:self action:@selector(meRequestComplete:) forRequestEvents:SMWebRequestEventComplete];
    [request addTarget:self action:@selector(meRequestError:) forRequestEvents:SMWebRequestEventError];
    [request start];
}

- (void)meRequestComplete:(NSData *)data {
    
    NSDictionary *response = [data objectFromJSONData];
    NSDictionary *user = [response objectForKey:@"user"];
    
    NSString *changesets = [NSString stringWithFormat:@"https://%@.beanstalkapp.com/api/changesets.json", domain];
    Feed *changesetsFeed = [Feed feedWithURLString:changesets title:@"Changesets" account:self];
    changesetsFeed.author = [user objectForKey:@"id"]; // store author by unique identifier instead of name
    changesetsFeed.requiresBasicAuth = YES;

    NSString *releases = [NSString stringWithFormat:@"https://%@.beanstalkapp.com/api/releases.json", domain];
    Feed *releasesFeed = [Feed feedWithURLString:releases title:@"Releases" account:self];
    releasesFeed.author = [user objectForKey:@"id"]; // store author by unique identifier instead of name
    releasesFeed.requiresBasicAuth = YES;

    self.feeds = [NSArray arrayWithObjects:changesetsFeed, releasesFeed, nil];

    [self.delegate account:self validationDidCompleteWithPassword:nil];
}

- (NSURLRequest *)webRequest:(SMWebRequest *)webRequest willSendRequest:(NSURLRequest *)newRequest redirectResponse:(NSURLResponse *)redirectResponse {
    
    if (redirectResponse) {
        [self.delegate account:self validationDidFailWithMessage:@"The given Beanstalk domain could not be found." field:AccountFailingFieldDomain];
        self.request = nil; // cancel
        return nil;
    }
    else return newRequest;
}

- (void)meRequestError:(NSError *)error {
    NSLog(@"Error! %@", error);
    
    SMErrorResponse *response = [error.userInfo objectForKey:SMErrorResponseKey];
    NSString *message = nil;
    
    if ([[response.response.allHeaderFields objectForKey:@"Content-Type"] beginsWithString:@"application/json"]) {
        NSDictionary *data = [response.data objectFromJSONData];
        NSArray *errors = [data objectForKey:@"errors"];
        message = errors.count ? [errors objectAtIndex:0] : nil;
    }
    
    if (error.code == 500 && message)
        [self.delegate account:self validationDidFailWithMessage:message field:AccountFailingFieldUnknown];
    else if (error.code == 401)
        [self.delegate account:self validationDidFailWithMessage:@"Could not access the given Beanstalk domain. Please check your username and password." field:0];
    else
        [self.delegate account:self validationDidFailWithMessage:error.localizedDescription field:AccountFailingFieldUnknown];
}

+ (NSArray *)itemsForRequest:(SMWebRequest *)request data:(NSData *)data username:(NSString *)username password:(NSString *)password {
    if ([request.request.URL.host endsWithString:@".beanstalkapp.com"]) {
        
        NSMutableArray *items = [NSMutableArray array];
        
        // cache this, it's expensive to create (and not threadsafe)
        // we need to parse shit like "2011/09/12 13:24:05 +0800"
        NSDateFormatter *formatter = [[[NSDateFormatter alloc] init] autorelease];
        [formatter setDateFormat:@"yyyy'/'MM'/'dd HH':'mm':'ss ZZZ"];

        if ([request.request.URL.path isEqualToString:@"/api/changesets.json"]) {
            
            NSArray *changesets = [data objectFromJSONData];
            
            for (NSDictionary *changeset in changesets) {
                
                NSDictionary *revision = [changeset objectForKey:@"revision_cache"];
                NSNumber *repositoryIdentifier = [revision objectForKey:@"repository_id"];
                NSNumber *userIdentifier = [revision objectForKey:@"user_id"];
                NSString *date = [revision objectForKey:@"time"];
                NSString *message = [revision objectForKey:@"message"];
                NSString *repositoryName = nil;

                if (repositoryIdentifier) {
                    // go out and fetch the repository name since we only have its ID
                    NSString *repositoryLookup = [NSString stringWithFormat:@"https://meridian.beanstalkapp.com/api/repositories/%@.json", repositoryIdentifier];
                    NSData *data = [self extraDataWithContentsOfURL:[NSURL URLWithString:repositoryLookup] username:username password:password];
                    if (!data) return [NSArray array];
                    
                    NSDictionary *response = [data objectFromJSONData];
                    NSDictionary *repository = [response objectForKey:@"repository"];
                    repositoryName = [repository objectForKey:@"title"];
                }
                
                FeedItem *item = [[FeedItem new] autorelease];
                item.published = [formatter dateFromString:date];
                item.updated = item.published;
                item.authorIdentifier = [userIdentifier stringValue];
                item.author = [revision objectForKey:@"author"];
                item.content = message;
                item.title = [NSString stringWithFormat:@"%@ released to %@", item.author, repositoryName, message];
                item.link = [NSURL URLWithString:
                             [NSString stringWithFormat:@"https://%@.beanstalkapp.com/meridian/changesets/ba2c18cf9705a964294b39a59c299aa6743e58e0"]];
                [items addObject:item];
            }
        }
        else if ([request.request.URL.path isEqualToString:@"/api/releases.json"]) {

            NSArray *releases = [data objectFromJSONData];
            
            for (NSDictionary *releaseData in releases) {
                
                NSDictionary *release = [releaseData objectForKey:@"release"];
                NSNumber *repositoryIdentifier = [release objectForKey:@"repository_id"];
                NSNumber *userIdentifier = [release objectForKey:@"user_id"];
                NSString *date = [release objectForKey:@"updated_at"];
                NSString *comment = [release objectForKey:@"comment"];
                NSString *environment = [release objectForKey:@"environment_name"];
                NSString *state = [release objectForKey:@"state"];
                NSString *repositoryName = nil, *userName = nil;
                
                if (repositoryIdentifier) {
                    // go out and fetch the repository name since we only have its ID
                    NSString *repositoryLookup = [NSString stringWithFormat:@"https://meridian.beanstalkapp.com/api/repositories/%@.json", repositoryIdentifier];
                    NSData *data = [self extraDataWithContentsOfURL:[NSURL URLWithString:repositoryLookup] username:username password:password];
                    if (!data) return [NSArray array];
                    
                    NSDictionary *response = [data objectFromJSONData];
                    NSDictionary *repository = [response objectForKey:@"repository"];
                    repositoryName = [repository objectForKey:@"title"];
                }

                if (userIdentifier) {
                    // go out and fetch the user's name since we only have their ID
                    NSString *userLookup = [NSString stringWithFormat:@"https://meridian.beanstalkapp.com/api/users/%@.json", userIdentifier];
                    NSData *data = [self extraDataWithContentsOfURL:[NSURL URLWithString:userLookup] username:username password:password];
                    if (!data) return [NSArray array];
                    
                    NSDictionary *response = [data objectFromJSONData];
                    NSDictionary *user = [response objectForKey:@"user"];
                    userName = [NSString stringWithFormat:@"%@ %@", [user objectForKey:@"first_name"], [user objectForKey:@"last_name"]];
                }

                FeedItem *item = [[FeedItem new] autorelease];
                item.published = [formatter dateFromString:date];
                item.updated = item.published;
                item.authorIdentifier = [userIdentifier stringValue];
                item.author = userName;
                item.title = [NSString stringWithFormat:@"%@ deployed to %@ (%@)", item.author, environment, state, comment];
                item.content = comment;
                [items addObject:item];
            }
        }
        
        return items;
    }
    else return nil;
}

@end