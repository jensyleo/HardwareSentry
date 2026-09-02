#include "include/CNVMeSMART.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOBSD.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

/// Tries to read SMART data from one registry object.
///
/// Returns false when the object does not offer the interface, which is the ordinary case
/// for every level except the controller.
static bool read_from_service(io_service_t service, CNVMeHealth *out) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t status = IOCreatePlugInInterfaceForService(
        service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (status != kIOReturnSuccess || !plugin) return false;

    IONVMeSMARTInterface **smart = NULL;
    HRESULT queried = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    IODestroyPlugInInterface(plugin);
    if (queried != S_OK || !smart) return false;

    bool succeeded = false;
    NVMeSMARTData log;
    memset(&log, 0, sizeof(log));
    if ((*smart)->SMARTReadData(smart, &log) == kIOReturnSuccess) {
        out->available = true;
        out->percentage_used = log.PERCENTAGE_USED;
        out->critical_warning = log.CRITICAL_WARNING != 0;
        succeeded = true;
    }
    (*smart)->Release(smart);
    return succeeded;
}

CNVMeHealth CNVMeReadHealth(const char *bsd_name) {
    CNVMeHealth result;
    memset(&result, 0, sizeof(result));
    if (!bsd_name) return result;

    CFMutableDictionaryRef matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsd_name);
    if (!matching) return result;

    io_service_t current = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (current == IO_OBJECT_NULL) return result;

    // The interface is tried at every level on the way up rather than at a named class.
    // On an Intel Mac the controller is IONVMeController; on Apple Silicon it is
    // AppleANS3CGv2Controller or whatever the next generation is called. Asking "does this
    // object answer the SMART interface" is the question that actually matters, and it
    // does not need updating when Apple renames the hardware.
    //
    // Six levels is deeper than real storage nests and keeps the walk bounded on a
    // malformed registry.
    for (int depth = 0; depth < 6; depth++) {
        if (read_from_service(current, &result)) break;

        io_registry_entry_t parent = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) != KERN_SUCCESS) break;
        IOObjectRelease(current);
        current = parent;
    }
    IOObjectRelease(current);
    return result;
}
