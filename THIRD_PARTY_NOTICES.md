# Third-party notices

RAYS's own source code is MIT-licensed (see `LICENSE`). It builds on these projects,
which are **not** committed to this repository and keep their own licenses:

| Component | Used for | License | How it gets here |
|---|---|---|---|
| [Ableton Link](https://github.com/Ableton/link) | Tempo/phase sync with DJ software and apps | GPLv2+ (commercial license available from Ableton) | git submodule `Vendor/link` |
| [ASIO standalone](https://think-async.com/Asio/) | Networking inside Link | Boost Software License 1.0 | Link's own submodule |
| [Beat Link](https://github.com/Deep-Symmetry/beat-link) / [Beat Link Trigger](https://github.com/Deep-Symmetry/beat-link-trigger) | Pro DJ Link discovery and beats from CDJ/XDJ consoles, run as a separate helper process | EPL-2.0 (plus their bundled dependencies' licenses) | downloaded by `Scripts/bootstrap.sh` |
| Java runtime bundled with Beat Link Trigger | Runs the helper | GPLv2 with Classpath Exception | inside the Beat Link Trigger download |

## What this means for you

- **Using, studying, modifying the source:** MIT, no strings attached.
- **Distributing a built `RAYS.app`:** because the app statically includes Ableton Link,
  the distributed binary as a whole is under **GPLv2+**. That is compatible with MIT: you
  must ship the license texts (the build script copies them into `Contents/Resources/Licenses`)
  and offer the corresponding source, which this public repository already does.
- **Closed-source forks** that ship binaries need a commercial Link license from Ableton,
  or must build without Link.

Product names (ENTTEC, Varytec, Allen & Heath Xone, Pioneer DJ, Ableton) are trademarks of
their owners and are used only to describe compatibility. RAYS is not affiliated with them.
Manufacturer manuals are linked, never redistributed.
