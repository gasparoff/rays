# Third-party notices

RAYS's own source code is MIT-licensed (see `LICENSE`). It builds on these projects,
which are **not** committed to this repository and keep their own licenses:

| Component | Used for | License | How it gets here |
|---|---|---|---|
| [Ableton Link](https://github.com/Ableton/link) | Tempo/phase sync with DJ software and apps | GPLv2+ (commercial license available from Ableton) | git submodule `Vendor/link` |
| [ASIO standalone](https://think-async.com/Asio/) | Networking inside Link | Boost Software License 1.0 | Link's own submodule |
| [Beat Link](https://github.com/Deep-Symmetry/beat-link) / [Beat Link Trigger](https://github.com/Deep-Symmetry/beat-link-trigger) | Pro DJ Link discovery and beats from CDJ/XDJ consoles, run as a separate helper process | EPL-2.0 (plus their bundled dependencies' licenses) | downloaded by `Scripts/bootstrap.sh` |
| Java runtime bundled with Beat Link Trigger | Runs the helper | GPLv2 with Classpath Exception | inside the Beat Link Trigger download |
| [Open Fixture Library](https://github.com/OpenLightingProject/open-fixture-library) | Channel maps of the fixture profiles in `Profiles/ofl/` (converted by `Scripts/import-ofl.py`) | MIT, Copyright (c) 2017 Florian & Felix Edelmann and contributors | converted data committed in `Profiles/ofl/`; each profile names its OFL fixture and commit |

### Open Fixture Library licence

The profiles in `Profiles/ofl/` are derived from the Open Fixture Library and are distributed
under its MIT licence:

> MIT License — Copyright (c) 2017 Florian & Felix Edelmann.
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software
> and associated documentation files (the "Software"), to deal in the Software without
> restriction, including without limitation the rights to use, copy, modify, merge, publish,
> distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
> Software is furnished to do so, subject to the following conditions: The above copyright notice
> and this permission notice shall be included in all copies or substantial portions of the
> Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
> INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE
> AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
> DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## What this means for you

- **Using, studying, modifying the source:** MIT, no strings attached.
- **Distributing a built `RAYS.app`:** because the app statically includes Ableton Link,
  the distributed binary as a whole is under **GPLv2+**. That is compatible with MIT: you
  must ship the license texts (the build script copies them into `Contents/Resources/Licenses`)
  and offer the corresponding source, which this public repository already does.
- **Closed-source forks** that ship binaries need a commercial Link license from Ableton,
  or must build without Link.

Product names (ENTTEC, Varytec, Allen & Heath Xone, Pioneer DJ, Ableton, and the fixture brands
in `Profiles/ofl/`) are trademarks of
their owners and are used only to describe compatibility. RAYS is not affiliated with them.
Manufacturer manuals are linked, never redistributed.
