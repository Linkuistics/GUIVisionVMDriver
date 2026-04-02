This project provides a Swift library that mediates access to a machine, virtual
or otherwise, that is accessible via VNC and SSH. It is designed to allow the
manipulation of a machine for the purposes of testing, automation, production of
screenshots, videos, etc.

It supports the injection of mouse and keyboard events, and the capturing of the
framebuffer contents in both a static (screenshot) and streaming (movie capture)
fashion, either full-frame or cropped. It allows recording of streaming encoded
capture to whilst simultaneously manipulating the keyboard and mouse.

It provides acccess to the cursor shape and position information provided by the
VNC protocol.

It handles the translation of keycodes in a VNC context, providing apis that
allow single key up/down actions, mouse button up/down actions and mouse
movement. On top of this it provides utility apis that combine such primitives
into e.g. key presses with modifiers, bulk text entry, mouse clicks, and mouse
drags with interpolation.

It provides a simple shell command execution facility over SSH, supporting
multiple persistent connections and transparently handling authentication. It
also supports read/write access to the remote filesystem using SSH/SCP
facilities, allowing for e.g. the installation of software.

It does not handle VM provisioning or lifecycle management, but connects to an
already running VM with SSH.

It includes a CLI command that exposes all of it's functionality, but can be
used as a library by other projects.
