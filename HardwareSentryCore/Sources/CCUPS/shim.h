// The genuine "needs a C bridge" case, unlike every constant-typing issue found while
// porting the other monitors: CUPS is a real C library (libcups), not an Apple framework
// with a typed Swift overlay, so there is no way to reach cupsGetDests()/cupsGetJobs()/the
// IPP API from Swift without a system-library target that imports its headers and links it.
#include <cups/cups.h>
