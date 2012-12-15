#import <Foundation/Foundation.h>
#include <CoreFoundation/CoreFoundation.h>

#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <stdio.h>
#include <signal.h>
#include <getopt.h>

#include "MobileDevice.h"

typedef enum {
    OP_NONE,
    OP_LIST_DEVICES,
    OP_UPLOAD_FILE,
    OP_LIST_FILES
} operation_t;

typedef struct am_device * AMDeviceRef;

static bool found_device = false, debug = false, verbose = false, quiet = false;
static NSString *app_path = nil;
static NSString *device_id = nil;
static NSString *doc_file_path = nil;
static NSString *target_filename = nil;
static NSString *bundle_id = nil;
static NSString *args = nil;

static int timeout = 0;

static operation_t operation = OP_NONE;

void Log(NSString *format, ...) {
    va_list argList;
    va_start(argList, format);
    NSString *message = [[NSString alloc] initWithFormat:format
                                               arguments:argList];
    printf("%s", [message UTF8String]);
    va_end(argList);
}

static void read_dir(service_conn_t afcFd, afc_connection* afc_conn_p, const char* dir)
{
    char *dir_ent;
    
    afc_connection afc_conn;
    if (!afc_conn_p) {
        afc_conn_p = &afc_conn;
        AFCConnectionOpen(afcFd, 0, &afc_conn_p);
        
    }
    
    Log(@"%s\n", dir);
    
    afc_dictionary afc_dict;
    afc_dictionary* afc_dict_p = &afc_dict;
    AFCFileInfoOpen(afc_conn_p, dir, &afc_dict_p);
    
    afc_directory afc_dir;
    afc_directory* afc_dir_p = &afc_dir;
    afc_error_t err = AFCDirectoryOpen(afc_conn_p, dir, &afc_dir_p);
    
    if (err != 0)
    {
        // Couldn't open dir - was probably a file
        return;
    }
    
    while(true) {
        AFCDirectoryRead(afc_conn_p, afc_dir_p, &dir_ent);
        
        if (!dir_ent)
            break;
        
        if (strcmp(dir_ent, ".") == 0 || strcmp(dir_ent, "..") == 0)
            continue;
        
        char* dir_joined = malloc(strlen(dir) + strlen(dir_ent) + 2);
        strcpy(dir_joined, dir);
        if (dir_joined[strlen(dir)-1] != '/')
            strcat(dir_joined, "/");
        strcat(dir_joined, dir_ent);
        read_dir(afcFd, afc_conn_p, dir_joined);
        free(dir_joined);
    }
    
    AFCDirectoryClose(afc_conn_p, afc_dir_p);
}

// Used to send files to app-specific sandbox (Documents dir)
service_conn_t start_house_arrest_service(AMDeviceRef device) {
    AMDeviceConnect(device);
    assert(AMDeviceIsPaired(device));
    assert(AMDeviceValidatePairing(device) == 0);
    assert(AMDeviceStartSession(device) == 0);
    
    service_conn_t houseFd;
    
    if (AMDeviceStartHouseArrestService(device, (__bridge CFStringRef)bundle_id, 0, &houseFd, 0) != 0)
    {
        Log(@"Unable to find bundle with id: %@\n", bundle_id);
        exit(EXIT_FAILURE);
    }
    
    assert(AMDeviceStopSession(device) == 0);
    assert(AMDeviceDisconnect(device) == 0);
    
    return houseFd;
}

static NSString *get_filename_from_path(NSString *path)
{
    return [[NSURL fileURLWithPath:path] lastPathComponent];
}

static const void* read_file_to_memory(NSString *path, size_t* file_size)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    *file_size = [data length];
    return [data bytes];
}

static void list_files(AMDeviceRef device)
{
    service_conn_t houseFd = start_house_arrest_service(device);
    
    afc_connection afc_conn;
    afc_connection* afc_conn_p = &afc_conn;
    AFCConnectionOpen(houseFd, 0, &afc_conn_p);
    
    read_dir(houseFd, afc_conn_p, "/");
}

static bool upload_file(afc_connection* afc_conn_p, const char* source_name, const char* dest_name)
{
    // open source
    FILE* pSource = fopen(source_name, "r");
    if (!pSource) {
        return false;
    }
    
    // open destination
    afc_file_ref file_ref;
    afc_error_t err = AFCFileRefOpen(afc_conn_p, dest_name, 3, &file_ref);
    if (err) {
        fclose(pSource);
        return false;
    }

    size_t bufferSize = 4096;
    uint8_t buffer[bufferSize];
    
    while (!feof(pSource)) {
        size_t n = fread(buffer, 1, bufferSize, pSource);
        err = AFCFileRefWrite(afc_conn_p, file_ref, buffer, (unsigned int)n);
        if (err) {
            fclose(pSource);
            AFCFileRefClose(afc_conn_p, file_ref);
            return false;
        }
    }
    
    fclose(pSource);
    AFCFileRefClose(afc_conn_p, file_ref);
    return true;
}

static void upload(AMDeviceRef device) {
    service_conn_t houseFd = start_house_arrest_service(device);
        
    afc_connection afc_conn;
    afc_connection* afc_conn_p = &afc_conn;
    AFCConnectionOpen(houseFd, 0, &afc_conn_p);
    
    //        read_dir(houseFd, NULL, "/");

    if (target_filename == nil)
    {
        target_filename = get_filename_from_path(doc_file_path);
    }
    NSString *target_path = [NSString pathWithComponents:@[@"/Documents/", target_filename]];

#if 0
    size_t file_size;
    const void* file_content = read_file_to_memory(doc_file_path, &file_size);
    
    if (!file_content)
    {
        Log(@"Could not open file: %@\n", doc_file_path);
        exit(EXIT_FAILURE);
    }
    
    afc_file_ref file_ref;
    assert(AFCFileRefOpen(afc_conn_p, [target_path UTF8String], 3, &file_ref) == 0);
    assert(AFCFileRefWrite(afc_conn_p, file_ref, file_content, (unsigned int)file_size) == 0);
    assert(AFCFileRefClose(afc_conn_p, file_ref) == 0);
#else
    upload_file(afc_conn_p, [doc_file_path UTF8String], [target_path UTF8String]);
#endif

    assert(AFCConnectionClose(afc_conn_p) == 0);
}

static void handle_device(AMDeviceRef device)
{
    if (found_device) return; // handle one device only
    
    NSString *found_device_id = (__bridge_transfer NSString *)AMDeviceCopyDeviceIdentifier(device);
    
    Log(@"found device id=%@\n", found_device_id);
    if (device_id != nil) {
        if ([device_id isEqual:found_device_id]) {
            found_device = YES;
        } else {
            return;
        }
    } else {
        if (operation == OP_LIST_DEVICES) {
            Log(@"%@\n", found_device_id);
            return;
        }
        found_device = YES;
    }
    
    if (operation == OP_UPLOAD_FILE) {
        Log(@"[  0%%] Found device (%@), sending file\n", found_device_id);
        
        upload(device);
        
        Log(@"[100%%] file sent %s\n", doc_file_path);
        
    } else if (operation == OP_LIST_FILES) {
        Log(@"[  0%%] Found device (%@), listing / ...\n", found_device_id);
        
        list_files(device);
        
        Log(@"[100%%] done.\n");
    }
    
    exit(EXIT_SUCCESS);
}

static void device_callback(struct am_device_notification_callback_info *info, void *arg) {
    (void)arg; // no-unused
    switch (info->msg) {
        case ADNCI_MSG_CONNECTED:
			if( info->dev->lockdown_conn ) {
				handle_device(info->dev);
			}
        default:
            break;
    }
}

static void timeout_callback(CFRunLoopTimerRef timer, void *info) {
    (void)timer, (void)info; // no-unused
    if (!found_device) {
        Log(@"Timed out waiting for device.\n");
        exit(EXIT_FAILURE);
    }
}

static void usage(const char* app) {
    Log(@"usage: %s [-q/--quiet] [-t/--timeout timeout(seconds)] [-v/--verbose] <command> [<args>] \n\n", app);
    Log(@"Commands available:\n");
    Log(@"   upload     [--id=device_id] --bundle-id=<bundle id> --file=filename [--target=filename]\n");
    Log(@"    * Uploads a file to the documents directory of the app specified with the bundle \n");
    Log(@"      identifier (eg com.foo.MyApp) to the specified device, or all attached devices if\n");
    Log(@"      none are specified. \n\n");
    Log(@"   list-files [--id=device_id] --bundle-id=<bundle id> \n");
    Log(@"    * Lists the the files in the app-specific sandbox  specified with the bundle \n");
    Log(@"      identifier (eg com.foo.MyApp) on the specified device, or all attached devices if\n");
    Log(@"      none are specified. \n\n");
    Log(@"   list-devices  \n");
    Log(@"    * List all attached devices. \n\n");
}

static bool args_are_valid() {
    return
        (operation == OP_UPLOAD_FILE && bundle_id && doc_file_path) ||
        (operation == OP_LIST_FILES && bundle_id) ||
        (operation == OP_LIST_DEVICES);
}

int main(int argc, char *argv[]) {
    static struct option global_longopts[]= {
        { "quiet", no_argument, NULL, 'q' },
        { "verbose", no_argument, NULL, 'v' },
        { "timeout", required_argument, NULL, 't' },
        
        { "id", required_argument, NULL, 'i' },
        { "bundle", required_argument, NULL, 'b' },
        { "file", required_argument, NULL, 'f' },
        { "target", required_argument, NULL, 1 },
        { "bundle-id", required_argument, NULL, 0 },
        
        { "debug", no_argument, NULL, 'd' },
        { "args", required_argument, NULL, 'a' },
        
        { NULL, 0, NULL, 0 },
    };

    char ch;
    while ((ch = getopt_long(argc, argv, "qvi:b:f:da:t:", global_longopts, NULL)) != -1)
    {
        switch (ch) {
            case 0:
                bundle_id = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 'q':
                quiet = 1;
                break;
            case 'v':
                verbose = 1;
                break;
            case 'd':
                debug = 1;
                break;
            case 't':
                timeout = atoi(optarg);
                break;
            case 'b':
                app_path = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 'f':
                doc_file_path = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 1:
                target_filename = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 'a':
                args = [[NSString alloc] initWithUTF8String:optarg];
                break;
            case 'i':
                device_id = [[NSString alloc] initWithUTF8String:optarg];
                break;
                
            default:
                usage(argv[0]);
                return 1;
        }
    }
    
    if (optind >= argc) {
        usage(argv [0]);
        exit(EXIT_SUCCESS);
    }
    
    operation = OP_NONE;
    if (strcmp (argv [optind], "list-devices") == 0) {
        operation = OP_LIST_DEVICES;
    } else if (strcmp (argv [optind], "upload") == 0) {
        operation = OP_UPLOAD_FILE;
    } else if (strcmp (argv [optind], "list-files") == 0) {
        operation = OP_LIST_FILES;
    } else {
        usage (argv [0]);
        exit (0);
    }
    
    if (!args_are_valid()) {
        usage(argv[0]);
        exit(0);
    }
    
    AMDAddLogFileDescriptor(fileno(stderr));
    
    AMDSetLogLevel(1+4+2+8+16+32+64+128); // otherwise syslog gets flooded with crap
    if (timeout > 0)
    {
        CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + timeout, 0, 0, 0, timeout_callback, NULL);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
        Log(@"[....] Waiting up to %d seconds for iOS device to be connected\n", timeout);
    }
    else
    {
        Log(@"[....] Waiting for iOS device to be connected\n");
    }
    
    struct am_device_notification *notify;
    AMDeviceNotificationSubscribe(&device_callback, 0, 0, NULL, &notify);
    
    CFRunLoopRun();
}
