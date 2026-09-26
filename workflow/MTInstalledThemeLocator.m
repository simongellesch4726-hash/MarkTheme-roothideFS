#import "MTInstalledThemeLocator.h"

#import <sys/stat.h>
#import <unistd.h>

#import "MTBootstrapPaths.h"

NSString *const MTInstalledThemeLocatorErrorDomain =
    @"com.hmmzzz.marktheme.installed-theme-locator";

// Where package managers place theme bundles, as logical paths that the
// bootstrap resolver maps onto the active prefix.
static NSArray<NSString *> *MTInstalledThemeLogicalRoots(void) {
    return @[
        @"/Library/Themes",
        @"/var/mobile/Library/Themes",
    ];
}

// The same locations as they exist on the real root filesystem. jbroot() has
// no notion of which logical paths live inside the bootstrap: it prefixes
// unconditionally, so /var/mobile/Library/Themes resolves to a path that
// cannot exist under either rootless or RootHide. /var/mobile is user data on
// the real root on every scheme, and a rootful or hybrid install can also
// leave themes at a bare /Library/Themes. Searching the literal paths
// alongside the resolved ones is what makes the feature work on every scheme;
// duplicates are collapsed by the caller.
static NSArray<NSString *> *MTInstalledThemeLiteralRoots(void) {
    return @[
        @"/var/mobile/Library/Themes",
        @"/Library/Themes",
    ];
}

@interface MTInstalledTheme ()
- (instancetype)initWithDisplayName:(NSString *)displayName
                        directoryURL:(NSURL *)directoryURL
                      searchRootPath:(NSString *)searchRootPath;
@end

@implementation MTInstalledTheme

- (instancetype)initWithDisplayName:(NSString *)displayName
                        directoryURL:(NSURL *)directoryURL
                      searchRootPath:(NSString *)searchRootPath {
    self = [super init];
    if (self == nil) return nil;
    _displayName = [displayName copy];
    _directoryURL = [directoryURL copy];
    _searchRootPath = [searchRootPath copy];
    return self;
}

@end

static NSString *_Nullable MTInstalledThemePackageName(
    NSString *directoryPath) {
    NSString *infoPath = [directoryPath stringByAppendingPathComponent:@"Info.plist"];
    NSData *data = [NSData dataWithContentsOfFile:infoPath options:NSDataReadingMappedIfSafe error:NULL];
    if (data.length == 0 || data.length > 64 * 1024) return nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:NULL];
    if (![plist isKindOfClass:NSDictionary.class]) return nil;
    NSString *packageName = plist[@"PackageName"];
    if (![packageName isKindOfClass:NSString.class]) return nil;
    NSString *trimmed = [packageName stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 ? trimmed : nil;
}

static NSURL *_Nullable MTInstalledThemeSuiteURL(
    NSArray<MTInstalledTheme *> *components) {
    if (components.count < 2) return nil;

    NSString *base = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"MarkTheme-InstalledSuites"];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:base
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:NULL]) {
        return nil;
    }
    NSString *suitePath = [base
        stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:suitePath
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:NULL]) {
        return nil;
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    for (MTInstalledTheme *component in components) {
        NSString *sourceRoot = component.directoryURL.path;
        NSString *name = component.directoryURL.lastPathComponent;
        NSString *destinationRoot = [suitePath stringByAppendingPathComponent:name];
        if (![manager createDirectoryAtPath:destinationRoot
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:NULL]) {
            [manager removeItemAtPath:suitePath error:NULL];
            return nil;
        }

        NSDirectoryEnumerator *enumerator =
            [manager enumeratorAtURL:component.directoryURL
                includingPropertiesForKeys:nil
                                 options:0
                            errorHandler:^BOOL(__unused NSURL *url,
                                               __unused NSError *error) {
            return YES;
        }];
        for (NSURL *url in enumerator) {
            NSString *relative = [url.path substringFromIndex:
                sourceRoot.length];
            while ([relative hasPrefix:@"/"]) {
                relative = [relative substringFromIndex:1];
            }
            if (relative.length == 0) continue;

            NSString *destination =
                [destinationRoot stringByAppendingPathComponent:relative];
            BOOL isDirectory = NO;
            if (![manager fileExistsAtPath:url.path isDirectory:&isDirectory]) {
                continue;
            }
            if (isDirectory) {
                if (![manager createDirectoryAtPath:destination
                         withIntermediateDirectories:YES
                                          attributes:nil
                                               error:NULL]) {
                    [manager removeItemAtPath:suitePath error:NULL];
                    return nil;
                }
                continue;
            }

            struct stat status = {0};
            if (lstat(url.path.fileSystemRepresentation, &status) != 0 ||
                !S_ISREG(status.st_mode)) {
                [manager removeItemAtPath:suitePath error:NULL];
                return nil;
            }
            if (link(url.path.fileSystemRepresentation,
                     destination.fileSystemRepresentation) != 0) {
                [manager removeItemAtPath:suitePath error:NULL];
                return nil;
            }
        }
    }
    return [NSURL fileURLWithPath:suitePath isDirectory:YES];
}

static NSUInteger MTInstalledThemeDirectoryFileCount(NSString *directoryPath) {
    NSDirectoryEnumerator *enumerator =
        [NSFileManager.defaultManager enumeratorAtURL:
            [NSURL fileURLWithPath:directoryPath isDirectory:YES]
            includingPropertiesForKeys:@[NSURLIsRegularFileKey]
            options:0
            errorHandler:^BOOL(__unused NSURL *url, __unused NSError *error) {
        return YES;
    }];
    NSUInteger count = 0;
    for (NSURL *url in enumerator) {
        NSNumber *isRegular = nil;
        [url getResourceValue:&isRegular forKey:NSURLIsRegularFileKey error:NULL];
        if (isRegular.boolValue) count++;
    }
    return count;
}

@implementation MTInstalledThemeLocator

- (instancetype)init {
    return [self initWithBootstrapResolver:
        MTBootstrapPathResolver.currentResolver];
}

- (instancetype)initWithBootstrapResolver:
        (nullable MTBootstrapPathResolver *)resolver {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    for (NSString *logicalPath in MTInstalledThemeLogicalRoots()) {
        NSString *resolved = resolver == nil ? nil
            : [resolver resolvedPathForLogicalPath:logicalPath error:NULL];
        if (resolved.length > 0 && ![roots containsObject:resolved]) {
            [roots addObject:resolved];
        }
    }
    for (NSString *literalPath in MTInstalledThemeLiteralRoots()) {
        if (![roots containsObject:literalPath]) [roots addObject:literalPath];
    }
    return [self initWithSearchRootPaths:roots];
}

- (instancetype)initWithSearchRootPaths:(NSArray<NSString *> *)searchRootPaths {
    NSParameterAssert(searchRootPaths != nil);
    self = [super init];
    if (self == nil) return nil;
    _searchRootPaths = [searchRootPaths copy];
    return self;
}

// A theme directory must be a real directory, not a symlink pointing outside
// the search root. The package manager owns these paths, so this is a
// consistency check on what is read, not a trust boundary.
static BOOL MTInstalledThemeDirectoryIsReadable(NSString *path) {
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) != 0) return NO;
    return S_ISDIR(status.st_mode);
}

// Two search roots can name the same directory: a resolved bootstrap path and
// its literal counterpart coincide on a rootful install, and /Library is a
// symlink on some setups. Identity is the (device, inode) pair, so the same
// theme is never offered twice under two spellings.
static NSString *_Nullable MTInstalledThemeIdentity(NSString *path) {
    struct stat status = {0};
    if (stat(path.fileSystemRepresentation, &status) != 0) return nil;
    return [NSString stringWithFormat:@"%llu:%llu",
        (unsigned long long)status.st_dev, (unsigned long long)status.st_ino];
}

- (NSArray<MTInstalledTheme *> *)locateInstalledThemes {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<MTInstalledTheme *> *candidates = [NSMutableArray array];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    NSMutableSet<NSString *> *seenRoots = [NSMutableSet set];
    for (NSString *rootPath in self.searchRootPaths) {
        if (!MTInstalledThemeDirectoryIsReadable(rootPath)) continue;
        NSString *rootIdentity = MTInstalledThemeIdentity(rootPath);
        if (rootIdentity != nil) {
            if ([seenRoots containsObject:rootIdentity]) continue;
            [seenRoots addObject:rootIdentity];
        }
        NSArray<NSString *> *names = [manager
            contentsOfDirectoryAtPath:rootPath error:NULL];
        for (NSString *name in names) {
            if (![name.lowercaseString hasSuffix:@".theme"] ||
                name.length <= 6 || [name hasPrefix:@"."]) {
                continue;
            }
            NSString *path = [rootPath stringByAppendingPathComponent:name];
            if (!MTInstalledThemeDirectoryIsReadable(path)) continue;
            NSString *identity = MTInstalledThemeIdentity(path) ?: path;
            if ([seenPaths containsObject:identity]) continue;
            [seenPaths addObject:identity];

            NSString *packageName = MTInstalledThemePackageName(path);
            NSString *displayName = packageName ?: [name substringToIndex:name.length - 6];
            [candidates addObject:[[MTInstalledTheme alloc]
                initWithDisplayName:displayName
                       directoryURL:[NSURL fileURLWithPath:path
                                               isDirectory:YES]
                     searchRootPath:rootPath]];
        }
    }

    // A SnowBoard/Anemone package can install several sibling .theme
    // directories that form one logical theme. PackageName is the explicit
    // package-level identity when present, so expose the suite once.
    // Keep the largest component as the import anchor; the directory import
    // pipeline gathers its matching sibling components.
    NSMutableDictionary<NSString *, NSMutableArray<MTInstalledTheme *> *> *groups =
        [NSMutableDictionary dictionary];
    for (MTInstalledTheme *candidate in candidates) {
        NSString *groupKey = MTInstalledThemePackageName(
            candidate.directoryURL.path);
        if (groupKey.length == 0) {
            groupKey = [@"path:" stringByAppendingString:candidate.directoryURL.path];
        }
        NSMutableArray<MTInstalledTheme *> *group = groups[groupKey];
        if (group == nil) {
            group = [NSMutableArray array];
            groups[groupKey] = group;
        }
        [group addObject:candidate];
    }

    NSMutableArray<MTInstalledTheme *> *result = [NSMutableArray array];
    for (NSString *groupKey in groups) {
        NSArray<MTInstalledTheme *> *components = groups[groupKey];
        MTInstalledTheme *anchor = components.firstObject;
        NSUInteger bestScore = 0;
        for (MTInstalledTheme *candidate in components) {
            NSUInteger score = MTInstalledThemeDirectoryFileCount(
                candidate.directoryURL.path);
            if (anchor == nil || score > bestScore) {
                anchor = candidate;
                bestScore = score;
            }
        }

        NSURL *suiteURL = MTInstalledThemeSuiteURL(components);
        NSURL *directoryURL = suiteURL ?: anchor.directoryURL;
        NSString *displayName = MTInstalledThemePackageName(
            anchor.directoryURL.path) ?: anchor.displayName;
        [result addObject:[[MTInstalledTheme alloc]
            initWithDisplayName:displayName
                   directoryURL:directoryURL
                 searchRootPath:anchor.searchRootPath]];
    }

    return [result sortedArrayUsingComparator:
        ^NSComparisonResult(MTInstalledTheme *left, MTInstalledTheme *right) {
            NSComparisonResult byName = [left.displayName
                localizedCaseInsensitiveCompare:right.displayName];
            if (byName != NSOrderedSame) return byName;
            return [left.directoryURL.path compare:right.directoryURL.path
                                            options:NSLiteralSearch];
        }];
}

@end
