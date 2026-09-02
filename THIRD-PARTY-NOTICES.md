# Third-party notices

HardwareSentry is distributed under the GNU General Public License v3 (see `LICENSE`).
It incorporates material from the projects below, whose licences are reproduced in full
as those licences require.

---

## The Growl Project — HardwareGrowler

HardwareSentry is an independent Swift rewrite whose observable behaviour, notification
wording and bundled artwork derive from HardwareGrowler, part of The Growl Project.
HardwareGrowler is distributed under the BSD 3-Clause licence, which permits that reuse and
requires this notice be retained.

The BSD 3-Clause licence is compatible with the GPLv3, which is what allows the combined
work to be distributed under the GPLv3 as a whole. The notice below applies to the
Growl-derived material specifically; it does not extend to the rest of HardwareSentry.

```
Copyright (c) The Growl Project, 2004-2011
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are
permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.
3. Neither the name of Growl nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

### What is derived, precisely

Being specific matters more than being vague, both for the licence and for anyone reading
the code later.

- **Notification wording.** Titles and message lines are deliberately the same strings, so
  that somebody moving from HardwareGrowler reads the same sentences.
- **Which hardware facts are worth reporting**, and which of them are worth reporting by
  default. That set is the product of years of use, and re-deciding it from scratch would
  have made a worse application, not a more original one.
- **Bundled artwork.** The icons in each module's `Resources` directory are Growl's, used
  as placeholders while a replacement set is designed.
- **Two documented workarounds** that exist because the underlying Apple API misbehaves,
  and where the original's solution is the correct one: deferring work out of a CoreMediaIO
  listener callback rather than acting inside it, and debouncing a camera's "stopped being
  used" signal because activating a camera briefly cycles that state during stream setup.

### What is not derived

- All source code. HardwareSentry is written from scratch in Swift, with a different
  architecture: one actor per monitor behind a declared protocol, a middleware pipeline for
  dispatch, and per-event preferences declared by each monitor rather than read ad hoc at
  each call site.
- The notification drawing, stacking and appearance system.
- Per-event icon overrides, profile export and import, multi-display placement, and the
  in-application help.
- The name HardwareSentry, and its icon once the placeholder artwork is replaced.

### On clause 3

Clause 3 forbids using the Growl name or its contributors' names to endorse or promote
HardwareSentry. This notice is a statement of provenance, which is what the licence
requires; it is not an endorsement, and none is claimed or implied. Accordingly the Growl
name appears nowhere in the application itself, its interface, or its marketing — only
here, and in the attribution section of the README.
