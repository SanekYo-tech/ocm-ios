# Third-party notices

## ios_system / a-Shell command frameworks

This app embeds prebuilt XCFrameworks from
[ios_system](https://github.com/holzschu/ios_system) v3.0.6:

- ios_system.xcframework
- files.xcframework
- shell.xcframework
- text.xcframework
- awk.xcframework
- tar.xcframework

Copyright © Nicolas Holzschuch and contributors.
Licensed under the BSD 3-Clause License.

The frameworks are used unmodified. The command dictionary files
(`commandDictionary.plist`, `extraCommandsDictionary.plist`) are also from
ios_system.

BSD 3-Clause License text:

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software
   without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## OpenCode Mobile UI

Files under `Resources/ui` are adapted from
[OpenCode Mobile](https://github.com/lovereplit-bit/OCM), MIT License,
© 2025 opencode, © 2026 OpenCode Mobile contributors.

## JavaScript libraries (vendored)

- marked — MIT
- DOMPurify — Apache-2.0 / MPL-2.0
- highlight.js — BSD-3-Clause
- xterm.js — MIT

## libgit2

The app links the prebuilt `lg2.xcframework` from
[holzschu/libgit2](https://github.com/holzschu/libgit2), built from
[libgit2](https://libgit2.org/).

libgit2 is licensed under GPL-2.0 with a linking exception. The exception
allows linking libgit2 with independent modules and distributing the result
under terms of your choice. Source: https://github.com/libgit2/libgit2/blob/main/COPYING

## CPython

The app embeds the prebuilt Python 3.13 iOS runtime and standard library
from [Python-Apple-support](https://github.com/beeware/Python-Apple-support)
(BeeWare), release `3.13-b18`.

Python is licensed under the Python Software Foundation License Version 2.
Source: https://docs.python.org/3/license.html

## OpenSSL / libssh2

Prebuilt XCFrameworks from
[holzschu/openssl-apple](https://github.com/holzschu/openssl-apple) and
[holzschu/libssh2-apple](https://github.com/holzschu/libssh2-apple).

- OpenSSL — Apache License 2.0 (OpenSSL 3) / OpenSSL License (1.1).
- libssh2 — BSD 3-Clause.
