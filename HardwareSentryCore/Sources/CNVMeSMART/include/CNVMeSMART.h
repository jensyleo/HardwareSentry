// A bridge to Apple's NVMe SMART interface.
//
// `NVMeSMARTLibExternal.h` ships in the SDK but is not in IOKit's module map, so Swift
// cannot see it at all. That alone would justify a shim. The interface is also an
// IOCFPlugIn — a table of C function pointers reached through QueryInterface — which is
// exactly the shape Swift handles worst, so the plugin dance happens here too and Swift
// receives one number.
#ifndef CNVMESMART_H
#define CNVMESMART_H

#include <stdbool.h>
#include <stdint.h>

/// How worn an NVMe drive reports itself to be, from the NVMe-spec SMART/Health log page.
typedef struct {
    /// True when the drive answered at all. Everything else is meaningless without it.
    bool available;
    /// The spec's PERCENTAGE_USED, 0-100 and occasionally beyond on a drive past its
    /// rated endurance. Health is the complement of this.
    uint8_t percentage_used;
    /// The drive's own critical-warning byte being non-zero: it is complaining, whatever
    /// the percentage says.
    bool critical_warning;
} CNVMeHealth;

/// Reads the SMART health of the NVMe controller behind a BSD disk name ("disk0").
///
/// Returns `available = false` for anything that is not an NVMe drive — an external USB
/// enclosure, a disk image, a network share — which is the honest answer rather than a
/// fabricated percentage.
CNVMeHealth CNVMeReadHealth(const char *bsd_name);

#endif
