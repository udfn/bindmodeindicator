# bindmodeindicator
Shows the current sway bind mode as an overlay layer surface in the top left corner on all outputs. Simple as that.

## Build
### Dependencies
- wayland-client
- zig (master branch!)
- cairo

It's Zig! `zig build run` gets it running immediately in debug mode. Additional dependencies (nwl and zig-wayland) are fetched automagically using the package manager.